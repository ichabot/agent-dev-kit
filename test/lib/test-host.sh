#!/usr/bin/env bash
# TEST VM setup steps for test/setup.sh (run as root). Requires agent/lib/host.sh,
# agent/lib/rootless-user.sh (ADK_PRIVILEGED_GROUPS), agent/lib/services.sh (secrets, caddy.env)
# sourced. Every step reports ok/changed (ADK_CHANGES).

ADK_DEPLOY_USER=deploy
ADK_DEPLOY_HOME=/var/lib/adk-deploy
ADK_APP_USER=adk-app
ADK_DEPLOY_SUDOERS=/etc/sudoers.d/adk-deploy
ADK_TEST_SERVICES=/opt/adk/test-services
ADK_TEST_SRV=/srv/test

adk_test_compose() { docker compose -f "$ADK_TEST_SERVICES/compose.yaml" --project-directory "$ADK_TEST_SERVICES" "$@"; }

# adk_deploy_sudoers: the only sudo rule of user deploy (stdout). sudo >= 1.9.10 matches the
# arguments against the anchored regular expression (joined by single spaces); deploy.sh checks
# them again as root (an argument with a space inside would match here, but not there).
adk_deploy_sudoers() {
  cat <<'EOF'
# agent-dev-kit (test/setup.sh): the deploy gate may start exactly one root command.
# The arguments must be "<project> <ref>"; test/deploy.sh validates them again.
Defaults:deploy !requiretty, env_reset, !setenv, !mail_badpass, umask=0022
deploy ALL=(root) NOPASSWD: /opt/adk/test/deploy.sh ^[a-z][a-z0-9-]{1\,38} ([0-9a-f]{40}|v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?)$
EOF
}

# _adk_not_privileged USER: remove USER from every group in ADK_PRIVILEGED_GROUPS except the
# ones named after it (adk-app keeps docker: it starts the projects' compose stacks)
_adk_not_privileged() {
  local user="$1" g keep
  shift
  for g in "${ADK_PRIVILEGED_GROUPS[@]}"; do
    for keep in "$@"; do [[ "$g" != "$keep" ]] || continue 2; done
    if id -nG "$user" | tr ' ' '\n' | grep -qx "$g"; then
      gpasswd -d "$user" "$g" > /dev/null
      adk_changed "user $user removed from group $g"
    fi
  done
}

# adk_test_users: system users deploy (forced-command SSH login, no sudo except the deploy rule,
# not in docker; root-owned home without dot files) and adk-app (no login; runs update.sh;
# member of docker, i.e. root-equivalent on TEST by design)
adk_test_users() {
  if ! id "$ADK_DEPLOY_USER" > /dev/null 2>&1; then
    useradd --system --user-group --home-dir "$ADK_DEPLOY_HOME" --no-create-home --shell /bin/bash "$ADK_DEPLOY_USER"
    adk_changed "user $ADK_DEPLOY_USER created"
  else
    adk_ok "user $ADK_DEPLOY_USER exists"
  fi
  [[ "$(getent passwd "$ADK_DEPLOY_USER" | cut -d: -f6)" == "$ADK_DEPLOY_HOME" ]] \
    || adk_die "home of $ADK_DEPLOY_USER is not $ADK_DEPLOY_HOME"
  [[ "$(getent passwd "$ADK_DEPLOY_USER" | cut -d: -f7)" == /bin/bash ]] || {
    usermod --shell /bin/bash "$ADK_DEPLOY_USER"; adk_changed "user $ADK_DEPLOY_USER: shell /bin/bash (runs the forced command)"; }
  # root-owned, not writable for deploy: no ~/.ssh, ~/.bashrc or rc files of its own
  [[ ! -L "$ADK_DEPLOY_HOME" ]] || adk_die "$ADK_DEPLOY_HOME is a symlink"
  if [[ "$(stat -c '%a %U:%G' "$ADK_DEPLOY_HOME" 2>/dev/null)" != "755 root:root" ]]; then
    install -d -m 0755 -o root -g root "$ADK_DEPLOY_HOME"
    adk_changed "$ADK_DEPLOY_HOME (root 0755)"
  fi
  # key login only: a locked password ("!") makes sshd refuse even keys (UsePAM), "*" does not
  if [[ "$(getent shadow "$ADK_DEPLOY_USER" | cut -d: -f2)" != '*' ]]; then
    usermod -p '*' "$ADK_DEPLOY_USER"
    adk_changed "user $ADK_DEPLOY_USER: no password (key only)"
  fi
  _adk_not_privileged "$ADK_DEPLOY_USER"
  if ! id "$ADK_APP_USER" > /dev/null 2>&1; then
    useradd --system --user-group --home-dir /nonexistent --no-create-home --shell /usr/sbin/nologin "$ADK_APP_USER"
    adk_changed "user $ADK_APP_USER created"
  else
    adk_ok "user $ADK_APP_USER exists"
  fi
  if ! id -nG "$ADK_APP_USER" | tr ' ' '\n' | grep -qx docker; then
    usermod -aG docker "$ADK_APP_USER"
    adk_changed "user $ADK_APP_USER in group docker (starts the projects' compose stacks)"
  fi
  _adk_not_privileged "$ADK_APP_USER" docker
}

# adk_test_sudoers: /etc/sudoers.d/adk-deploy (0440, checked with visudo first); no other
# sudoers file may mention deploy
adk_test_sudoers() {
  local tmp other
  other="$(grep -rlsE "^[^#]*\b$ADK_DEPLOY_USER\b" /etc/sudoers /etc/sudoers.d | grep -vx "$ADK_DEPLOY_SUDOERS" || true)"
  [[ -z "$other" ]] || adk_die "sudoers file(s) $other mention $ADK_DEPLOY_USER; remove those entries (only $ADK_DEPLOY_SUDOERS may)"
  tmp="$(mktemp)"
  adk_deploy_sudoers > "$tmp"
  if ! visudo -cqf "$tmp"; then
    rm -f "$tmp"
    adk_die "the deploy sudoers rule does not parse (sudo too old for argument regexes?)"
  fi
  adk_put_file "$ADK_DEPLOY_SUDOERS" 0440 root:root < "$tmp" || true
  rm -f "$tmp"
  visudo -cq > /dev/null || adk_die "sudoers configuration invalid after writing $ADK_DEPLOY_SUDOERS"
}

# adk_test_services CONFIG: render (test/render-services.sh) into /opt/adk/test-services, build
# the dns01 image if missing, start Caddy or apply changes (Caddyfile: reload over the admin
# socket, compose/env: recreate). /srv/test and the sites directory exist (root 0755).
adk_test_services() {
  local config="$1" tmp compose_changed=false caddyfile_changed=false image running
  tmp="$(mktemp -d)"
  "$_ADK_HOST_LIB/../../test/render-services.sh" --config "$config" --out "$tmp" || { rm -rf "$tmp"; adk_die "test/render-services.sh failed"; }
  install -d -m 0755 -o root -g root "$ADK_TEST_SERVICES" "$ADK_TEST_SERVICES/sites" "$ADK_TEST_SRV"
  adk_put_file "$ADK_TEST_SERVICES/compose.yaml" 0644 root:root < "$tmp/compose.yaml" && compose_changed=true
  adk_put_file "$ADK_TEST_SERVICES/Caddyfile" 0644 root:root < "$tmp/Caddyfile" && caddyfile_changed=true
  if [[ -f "$tmp/caddy/Dockerfile" ]]; then
    install -d -m 0755 -o root -g root "$ADK_TEST_SERVICES/caddy"
    adk_put_file "$ADK_TEST_SERVICES/caddy/Dockerfile" 0644 root:root < "$tmp/caddy/Dockerfile" && compose_changed=true
  elif [[ -e "$ADK_TEST_SERVICES/caddy" ]]; then
    rm -rf "$ADK_TEST_SERVICES/caddy"
    adk_changed "$ADK_TEST_SERVICES/caddy removed"
  fi
  rm -rf "$tmp"
  if [[ -f "$ADK_TEST_SERVICES/caddy/Dockerfile" ]]; then
    image="$(adk_test_compose config --format json | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["services"]["caddy"]["image"])')"
    if docker image inspect "$image" > /dev/null 2>&1; then
      adk_ok "caddy image $image"
    else
      adk_test_compose build --pull caddy
      adk_changed "caddy image $image built"
      compose_changed=true
    fi
  fi
  running="$(adk_test_compose ps --status running --services 2> /dev/null | tr -d '\n')"
  if [[ "$compose_changed" == true || "$ADK_CADDY_ENV_CHANGED" == true || "$running" != caddy ]]; then
    adk_test_compose up -d --force-recreate --remove-orphans
    adk_changed "caddy (re)created"
  elif [[ "$caddyfile_changed" == true ]]; then
    adk_test_compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile \
      --address unix//run/caddy/admin.sock < /dev/null || adk_die "caddy reload failed"
    adk_changed "caddy reloaded (Caddyfile changed)"
  else
    adk_ok "caddy running"
  fi
}
