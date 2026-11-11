#!/usr/bin/env bash
# Agent VPS services for agent/setup.sh (run as root): secrets, Gitea + Caddy (root Docker
# Compose project "adk"), Gitea runner as user ci (rootless Docker), backup timer.
# Requires host.sh and versions.sh sourced. Every step reports ok/changed (ADK_CHANGES).

ADK_SECRETS_DIR=/opt/adk/secrets
ADK_SERVICES_DIR=/opt/adk/services
ADK_COMPOSE_FILE="$ADK_SERVICES_DIR/compose.yaml"
ADK_DATA_DIR=/var/lib/adk
ADK_RUNNER_CONFIG=/etc/adk/runner.yaml
ADK_RUNNER_STATE=/var/lib/adk-runner
ADK_RUNNER_BIN=/usr/local/bin/gitea-runner
ADK_RUNNER_UNIT=/etc/systemd/system/adk-act-runner.service
ADK_LAB_CA=/usr/local/share/ca-certificates/adk-lab-caddy-root.crt

adk_compose() { docker compose -f "$ADK_COMPOSE_FILE" --project-directory "$ADK_SERVICES_DIR" "$@"; }

# adk_random_secret KIND: alnum (64 chars) or jwt (32 random bytes, base64url without '=',
# the format Gitea expects for JWT secrets). Printed to stdout: callers pipe it into a file.
adk_random_secret() {
  case "$1" in
    alnum) python3 -I -c 'import secrets, string; a = string.ascii_letters + string.digits; print("".join(secrets.choice(a) for _ in range(64)), end="")' ;;
    jwt) python3 -I -c 'import base64, secrets; print(base64.urlsafe_b64encode(secrets.token_bytes(32)).decode().rstrip("="), end="")' ;;
    *) adk_die "adk_random_secret: unknown kind $1" ;;
  esac
}

# adk_secrets_dir: /opt/adk/secrets exists, root:root 0700, not a symlink
adk_secrets_dir() {
  [[ ! -L "$ADK_SECRETS_DIR" ]] || adk_die "$ADK_SECRETS_DIR is a symlink"
  if [[ "$(stat -c '%a %U:%G' "$ADK_SECRETS_DIR" 2>/dev/null)" != "700 root:root" ]]; then
    install -d -m 0700 -o root -g root "$ADK_SECRETS_DIR"
    adk_changed "$ADK_SECRETS_DIR (root 0700)"
  fi
}

# adk_gitea_secrets: generate Gitea's secrets once (never printed, never rotated by setup:
# SECRET_KEY encrypts data in the database).
adk_gitea_secrets() {
  local name kind f
  for name in gitea-secret-key:alnum gitea-internal-token:alnum gitea-jwt-secret:jwt gitea-lfs-jwt-secret:jwt; do
    kind="${name#*:}"
    f="$ADK_SECRETS_DIR/${name%%:*}"
    [[ ! -L "$f" ]] || adk_die "$f is a symlink"
    if [[ -s "$f" ]]; then
      [[ "$(stat -c '%a %U' "$f")" == "600 root" ]] || { chown root:root "$f"; chmod 0600 "$f"; adk_changed "$f (mode/owner)"; }
      adk_ok "secret ${name%%:*}"
    else
      (umask 077; adk_random_secret "$kind" > "$f.tmp" && mv -f "$f.tmp" "$f")
      adk_changed "secret ${name%%:*} generated"
    fi
  done
}

# adk_caddy_env MODE: env file with the DNS API token for Caddy (dns01 only)
adk_caddy_env() {
  local mode="$1" token_file="$ADK_SECRETS_DIR/dns-api-token" token
  if [[ "$mode" != dns01 ]]; then
    if [[ -e "$ADK_SECRETS_DIR/caddy.env" ]]; then
      rm -f "$ADK_SECRETS_DIR/caddy.env"
      adk_changed "$ADK_SECRETS_DIR/caddy.env removed (ACME_MODE=$mode)"
    fi
    return 0
  fi
  if [[ ! -s "$token_file" || -L "$token_file" ]]; then
    echo "ERROR: ACME_MODE=dns01 needs the DNS provider's API token. Store it (stdin, not shown) and re-run setup:" >&2
    echo "  ssh adk-admin@<vps> sudo /opt/adk/agent/set-secret.sh dns-api-token < token-file" >&2
    echo "  ssh adk-admin@<vps> sudo /opt/adk/agent/setup.sh" >&2
    exit 1
  fi
  token="$(cat "$token_file")"
  adk_put_file "$ADK_SECRETS_DIR/caddy.env" 0600 root:root <<< "DNS_API_TOKEN=$token" || true
  token=""
}

# adk_render_services CONFIG: render into /opt/adk/services and /etc/adk/runner.yaml.
# Sets ADK_COMPOSE_CHANGED / ADK_CADDYFILE_CHANGED / ADK_RUNNER_CONFIG_CHANGED.
adk_render_services() {
  local config="$1" tmp
  tmp="$(mktemp -d)"
  "$_ADK_HOST_LIB/../render-services.sh" --config "$config" --out "$tmp" || { rm -rf "$tmp"; adk_die "render-services.sh failed"; }
  install -d -m 0755 -o root -g root "$ADK_SERVICES_DIR" /etc/adk
  ADK_COMPOSE_CHANGED=false ADK_CADDYFILE_CHANGED=false ADK_RUNNER_CONFIG_CHANGED=false
  adk_put_file "$ADK_COMPOSE_FILE" 0644 root:root < "$tmp/compose.yaml" && ADK_COMPOSE_CHANGED=true
  adk_put_file "$ADK_SERVICES_DIR/Caddyfile" 0644 root:root < "$tmp/Caddyfile" && ADK_CADDYFILE_CHANGED=true
  if [[ -f "$tmp/caddy/Dockerfile" ]]; then
    install -d -m 0755 -o root -g root "$ADK_SERVICES_DIR/caddy"
    adk_put_file "$ADK_SERVICES_DIR/caddy/Dockerfile" 0644 root:root < "$tmp/caddy/Dockerfile" && ADK_COMPOSE_CHANGED=true
  elif [[ -e "$ADK_SERVICES_DIR/caddy" ]]; then
    rm -rf "$ADK_SERVICES_DIR/caddy"
    adk_changed "$ADK_SERVICES_DIR/caddy removed"
  fi
  adk_put_file "$ADK_RUNNER_CONFIG" 0644 root:root < "$tmp/runner.yaml" && ADK_RUNNER_CONFIG_CHANGED=true
  rm -rf "$tmp"
  return 0
}

# adk_services_up: data directory, Caddy image (dns01), compose up when something changed
# or a service is not running, wait until Gitea is healthy.
adk_services_up() {
  local running image i
  if [[ "$(stat -c '%a %U' "$ADK_DATA_DIR" 2>/dev/null)" != "700 root" ]]; then
    install -d -m 0700 -o root -g root "$ADK_DATA_DIR"
    adk_changed "$ADK_DATA_DIR (root 0700)"
  fi
  if [[ ! -d "$ADK_DATA_DIR/gitea" ]]; then
    install -d -m 0755 -o root -g root "$ADK_DATA_DIR/gitea"
    adk_changed "$ADK_DATA_DIR/gitea"
  fi
  if [[ -f "$ADK_SERVICES_DIR/caddy/Dockerfile" ]]; then
    image="$(adk_compose config --images caddy)"
    if docker image inspect "$image" >/dev/null 2>&1; then
      adk_ok "caddy image $image"
    else
      adk_compose build --pull caddy
      adk_changed "caddy image $image built"
      ADK_COMPOSE_CHANGED=true
    fi
  fi
  running="$(adk_compose ps --status running --services 2>/dev/null | sort | tr '\n' ' ')"
  if [[ "$ADK_COMPOSE_CHANGED" == true || "$running" != "caddy gitea " ]]; then
    adk_compose up -d --remove-orphans
    adk_changed "services up (gitea, caddy)"
  elif [[ "$ADK_CADDYFILE_CHANGED" == true ]]; then
    # admin off: no live reload, a restart applies the new Caddyfile
    adk_compose restart caddy
    adk_changed "caddy restarted (Caddyfile changed)"
  else
    adk_ok "services running (gitea, caddy)"
  fi
  for ((i = 0; i < 90; i++)); do
    if adk_compose exec -T gitea curl -fsS -o /dev/null http://127.0.0.1:3000/api/healthz 2>/dev/null; then
      adk_ok "gitea healthy"
      return 0
    fi
    sleep 2
  done
  adk_compose logs --tail 50 gitea >&2 || true
  adk_die "gitea did not become healthy"
}

# adk_wait_https DOMAIN: Gitea answers through Caddy on this host (certificate valid for
# the system trust store; ACME can take a few minutes).
adk_wait_https() {
  local domain="$1" i
  for ((i = 0; i < 60; i++)); do
    if curl -q -fsS -o /dev/null --max-time 10 --resolve "$domain:443:127.0.0.1" "https://$domain/api/healthz" 2>/dev/null; then
      adk_ok "https://$domain reachable through caddy (valid certificate)"
      return 0
    fi
    sleep 5
  done
  curl -q -sS -o /dev/null --max-time 10 --resolve "$domain:443:127.0.0.1" "https://$domain/api/healthz" || true
  adk_compose logs --tail 50 caddy >&2 || true
  adk_die "https://$domain does not answer with a valid certificate (see caddy log above)"
}

# adk_lab_ca USER...: ADK_TLS_INTERNAL=1 only. Trust Caddy's internal root CA on this host
# (system store; rootless dockerds of USER... restarted so registry pushes trust it).
adk_lab_ca() {
  local tmp i u changed=false
  if [[ "${ADK_TLS_INTERNAL:-}" != 1 ]]; then
    if [[ -e "$ADK_LAB_CA" ]]; then
      rm -f "$ADK_LAB_CA"
      update-ca-certificates --fresh >/dev/null
      adk_changed "lab CA removed from the trust store"
    fi
    return 0
  fi
  echo "WARNING: ADK_TLS_INTERNAL=1 - Caddy's internal CA instead of ACME (lab/test only)"
  tmp="$(mktemp)"
  for ((i = 0; i < 30; i++)); do
    adk_compose exec -T caddy cat /data/caddy/pki/authorities/local/root.crt > "$tmp" 2>/dev/null && [[ -s "$tmp" ]] && break
    sleep 2
  done
  [[ -s "$tmp" ]] || { rm -f "$tmp"; adk_die "caddy has no internal root CA"; }
  adk_put_file "$ADK_LAB_CA" 0644 root:root < "$tmp" && changed=true
  rm -f "$tmp"
  if [[ "$changed" == true ]]; then
    update-ca-certificates >/dev/null
    for u in "$@"; do
      id "$u" >/dev/null 2>&1 && adk_user_env "$u" systemctl --user restart docker.service
    done
    systemctl try-restart adk-act-runner.service
  fi
}

# adk_runner_binary: pinned Gitea runner, sha256 verified before install
adk_runner_binary() {
  local arch sum url tmp
  arch="$(dpkg --print-architecture)"
  sum="${ADK_RUNNER_SHA256[$arch]:-}"
  [[ -n "$sum" ]] || adk_die "no pinned Gitea runner for architecture $arch"
  if [[ -f "$ADK_RUNNER_BIN" && ! -L "$ADK_RUNNER_BIN" ]] && [[ "$(sha256sum < "$ADK_RUNNER_BIN" | cut -d' ' -f1)" == "$sum" ]]; then
    adk_ok "gitea-runner $ADK_RUNNER_VERSION ($arch, sha256 verified)"
    return 0
  fi
  url="https://dl.gitea.com/gitea-runner/$ADK_RUNNER_VERSION/gitea-runner-$ADK_RUNNER_VERSION-linux-$arch"
  tmp="$(mktemp)"
  curl -q -fsSL --proto '=https' "$url" -o "$tmp" || { rm -f "$tmp"; adk_die "download failed: $url"; }
  if [[ "$(sha256sum < "$tmp" | cut -d' ' -f1)" != "$sum" ]]; then
    rm -f "$tmp"
    adk_die "gitea-runner download does not match the pinned sha256; not installing it"
  fi
  install -m 0755 -o root -g root "$tmp" "$ADK_RUNNER_BIN"
  rm -f "$tmp"
  adk_changed "gitea-runner $ADK_RUNNER_VERSION installed ($arch, sha256 verified)"
}

# adk_runner_setup DOMAIN CUSTOMER: state dir, registration (token piped, never printed),
# systemd system unit running as ci with ci's rootless Docker.
adk_runner_setup() {
  local domain="$1" customer="$2" uid unit_changed=false
  uid="$(id -u ci)"
  if [[ -L "$ADK_RUNNER_STATE" ]]; then adk_die "$ADK_RUNNER_STATE is a symlink"; fi
  if [[ "$(stat -c '%a %U:%G' "$ADK_RUNNER_STATE" 2>/dev/null)" != "700 ci:ci" ]]; then
    install -d -m 0700 -o ci -g ci "$ADK_RUNNER_STATE"
    adk_changed "$ADK_RUNNER_STATE (ci 0700)"
  fi
  if getent ahosts "$domain" >/dev/null; then
    adk_ok "$domain resolves ($(getent ahosts "$domain" | awk 'NR == 1 {print $1}'))"
  else
    adk_die "$domain does not resolve on this host; create the DNS record first (the runner talks to https://$domain)"
  fi
  # ci's files are checked as ci (root never looks inside a directory ci controls)
  if adk_as_user ci test -f "$ADK_RUNNER_STATE/.runner"; then
    adk_ok "runner registered"
  else
    # The registration token goes from Gitea's CLI straight into the runner's stdin.
    # shellcheck disable=SC2016  # expanded by the inner sh
    if ! adk_compose exec -T -u git gitea gitea actions generate-runner-token < /dev/null 2>/dev/null \
        | tail -n 1 \
        | adk_as_user ci env HOME="$ADK_RUNNER_STATE" sh -c 'cd "$1" && exec "$2" -c "$3" register --no-interactive --instance "$4" --name "$5" --token-file /dev/stdin' \
          sh "$ADK_RUNNER_STATE" "$ADK_RUNNER_BIN" "$ADK_RUNNER_CONFIG" "https://$domain" "adk-$customer"; then
      adk_die "runner registration failed"
    fi
    adk_changed "runner adk-$customer registered at https://$domain"
  fi
  if adk_put_file "$ADK_RUNNER_UNIT" 0644 root:root <<EOF
[Unit]
Description=agent-dev-kit CI runner (Gitea runner as user ci, rootless Docker)
After=network-online.target user@$uid.service
Wants=network-online.target user@$uid.service

[Service]
Type=simple
User=ci
Group=ci
WorkingDirectory=$ADK_RUNNER_STATE
Environment=HOME=$ADK_RUNNER_STATE
Environment=XDG_RUNTIME_DIR=/run/user/$uid
Environment=DOCKER_HOST=unix:///run/user/$uid/docker.sock
ExecStart=$ADK_RUNNER_BIN --config $ADK_RUNNER_CONFIG daemon
Restart=always
RestartSec=10
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes

[Install]
WantedBy=multi-user.target
EOF
  then
    systemctl daemon-reload
    unit_changed=true
  fi
  if [[ "$(systemctl is-enabled adk-act-runner.service 2>/dev/null)" != enabled ]]; then
    systemctl enable adk-act-runner.service
    adk_changed "adk-act-runner.service enabled"
  fi
  if [[ "$unit_changed" == true || "$ADK_RUNNER_CONFIG_CHANGED" == true ]] || ! systemctl is-active --quiet adk-act-runner.service; then
    systemctl restart adk-act-runner.service
    adk_changed "adk-act-runner.service (re)started"
  else
    adk_ok "adk-act-runner.service running"
  fi
}

# adk_backup_setup TARGET CUSTOMER: local backup directory, daily timer (03:30, before the
# 04:30 unattended reboot), and for an off-site TARGET a dedicated SSH key (public part shown).
adk_backup_setup() {
  local target="$1" customer="$2" here unit_changed=false
  here="$_ADK_HOST_LIB/.."
  if [[ "$(stat -c '%a %U:%G' /var/backups/adk 2>/dev/null)" != "700 root:root" ]]; then
    install -d -m 0700 -o root -g root /var/backups/adk
    adk_changed "/var/backups/adk (root 0700)"
  fi
  adk_put_file /etc/systemd/system/adk-backup.service 0644 root:root < "$here/systemd/adk-backup.service" && unit_changed=true
  adk_put_file /etc/systemd/system/adk-backup.timer 0644 root:root < "$here/systemd/adk-backup.timer" && unit_changed=true
  [[ "$unit_changed" == false ]] || systemctl daemon-reload
  if [[ "$(systemctl is-enabled adk-backup.timer 2>/dev/null)" != enabled ]] || ! systemctl is-active --quiet adk-backup.timer; then
    systemctl enable --now adk-backup.timer
    adk_changed "adk-backup.timer enabled (daily 03:30)"
  elif [[ "$unit_changed" == true ]]; then
    systemctl restart adk-backup.timer
  else
    adk_ok "adk-backup.timer (daily 03:30)"
  fi
  [[ -n "$target" ]] || return 0
  install -d -m 0700 -o root -g root /root/.ssh
  if [[ -f /root/.ssh/adk-backup && -f /root/.ssh/adk-backup.pub ]]; then
    adk_ok "backup key /root/.ssh/adk-backup (public: /root/.ssh/adk-backup.pub)"
  else
    [[ ! -L /root/.ssh/adk-backup ]] || adk_die "/root/.ssh/adk-backup is a symlink"
    rm -f /root/.ssh/adk-backup /root/.ssh/adk-backup.pub
    ssh-keygen -q -t ed25519 -N '' -C "adk-backup@$customer" -f /root/.ssh/adk-backup
    adk_changed "backup key /root/.ssh/adk-backup created"
    echo "Off-site backup: add this PUBLIC key to the authorized keys of ${target#sftp://} (private key stays on this server):"
    cat /root/.ssh/adk-backup.pub
  fi
}
