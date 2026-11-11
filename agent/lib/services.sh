#!/usr/bin/env bash
# Agent VPS services for agent/setup.sh (run as root): secrets, Gitea + Caddy (root Docker
# Compose project "adk"), Gitea runner as user ci (rootless Docker, lib/ci-runner.sh), backup
# timer. Requires host.sh, versions.sh and ci-runner.sh sourced. Every step reports ok/changed (ADK_CHANGES).

ADK_SECRETS_DIR=/opt/adk/secrets
ADK_SERVICES_DIR=/opt/adk/services
ADK_COMPOSE_FILE="$ADK_SERVICES_DIR/compose.yaml"
ADK_DATA_DIR=/var/lib/adk
ADK_RUNNER_CONFIG=/etc/adk/runner.yaml
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

# adk_caddy_env MODE: env file with the DNS API token for Caddy (dns01 only). The value is
# single-quoted (compose interpolates $ in unquoted and double-quoted values); a token with a
# single quote is refused. Sets ADK_CADDY_ENV_CHANGED (true: Caddy must be recreated, a
# restart keeps the old environment).
ADK_CADDY_ENV_CHANGED=false
adk_caddy_env() {
  local mode="$1" token_file="$ADK_SECRETS_DIR/dns-api-token" token
  ADK_CADDY_ENV_CHANGED=false
  if [[ "$mode" != dns01 ]]; then
    if [[ -e "$ADK_SECRETS_DIR/caddy.env" ]]; then
      rm -f "$ADK_SECRETS_DIR/caddy.env"
      adk_changed "$ADK_SECRETS_DIR/caddy.env removed (ACME_MODE=$mode)"
      ADK_CADDY_ENV_CHANGED=true
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
  if [[ "$token" == *"'"* ]]; then
    token=""
    adk_die "$token_file contains a single quote; store the token again with set-secret.sh"
  fi
  if adk_put_file "$ADK_SECRETS_DIR/caddy.env" 0600 root:root <<< "DNS_API_TOKEN='$token'"; then
    ADK_CADDY_ENV_CHANGED=true
  fi
  token=""
}

# adk_gitea_user: system user adk-gitea (no login, no home) that owns Gitea's data on the
# host; the container runs Gitea with its uid/gid (USER_UID/USER_GID). Prints nothing.
adk_gitea_user() {
  if ! id adk-gitea > /dev/null 2>&1; then
    useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin adk-gitea
    adk_changed "system user adk-gitea (owner of Gitea's data)"
  else
    adk_ok "system user adk-gitea ($(id -u adk-gitea))"
  fi
}

# adk_render_services CONFIG: render into /opt/adk/services and /etc/adk/runner.yaml.
# Sets ADK_COMPOSE_CHANGED / ADK_CADDYFILE_CHANGED / ADK_RUNNER_CONFIG_CHANGED.
adk_render_services() {
  local config="$1" tmp
  tmp="$(mktemp -d)"
  "$_ADK_HOST_LIB/../render-services.sh" --config "$config" --out "$tmp" --gitea-uid "$(id -u adk-gitea)" --gitea-gid "$(id -g adk-gitea)" || { rm -rf "$tmp"; adk_die "render-services.sh failed"; }
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

# adk_services_action RUNNING COMPOSE_CHANGED CADDYFILE_CHANGED CADDY_ENV_CHANGED: what to do
# with the running services: up | recreate-caddy | restart-caddy | none
adk_services_action() {
  local running="$1" compose="$2" caddyfile="$3" env="$4"
  if [[ "$compose" == true || "$running" != "caddy gitea " ]]; then echo up
  elif [[ "$env" == true ]]; then echo recreate-caddy
  elif [[ "$caddyfile" == true ]]; then echo restart-caddy
  else echo none
  fi
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
    image="$(adk_compose config --format json | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["services"]["caddy"]["image"])')"
    if docker image inspect "$image" >/dev/null 2>&1; then
      adk_ok "caddy image $image"
    else
      adk_compose build --pull caddy
      adk_changed "caddy image $image built"
      ADK_COMPOSE_CHANGED=true
    fi
  fi
  running="$(adk_compose ps --status running --services 2>/dev/null | sort | tr '\n' ' ')"
  case "$(adk_services_action "$running" "$ADK_COMPOSE_CHANGED" "$ADK_CADDYFILE_CHANGED" "$ADK_CADDY_ENV_CHANGED")" in
    up)
      adk_compose up -d --remove-orphans
      adk_changed "services up (gitea, caddy)"
      ;;
    recreate-caddy)
      # env_file is read when the container is created: a restart would keep the old token
      adk_compose up -d --force-recreate caddy
      adk_changed "caddy recreated (DNS API token changed)"
      ;;
    restart-caddy)
      # admin off: no live reload, a restart applies the new Caddyfile
      adk_compose restart caddy
      adk_changed "caddy restarted (Caddyfile changed)"
      ;;
    *) adk_ok "services running (gitea, caddy)" ;;
  esac
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
# (system store; rootless dockerds of USER... and the CI runner, whose prepare step starts a
# fresh dockerd for ci, restarted so registry pushes trust it).
adk_lab_ca() {
  local tmp i u changed=false
  if [[ "${ADK_TLS_INTERNAL:-}" != 1 ]]; then
    if [[ -e "$ADK_LAB_CA" ]]; then
      rm -f "$ADK_LAB_CA"
      update-ca-certificates --fresh > /dev/null 2>&1
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
    update-ca-certificates > /dev/null 2>&1 || adk_die "update-ca-certificates failed"
    for u in "$@"; do
      if id "$u" > /dev/null 2>&1; then adk_user_env "$u" systemctl --user restart docker.service; fi
    done
    if [[ -f "$ADK_RUNNER_UNIT" ]]; then systemctl try-restart adk-act-runner.service; fi
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

# adk_runner_service DOMAIN: systemd unit of the runner (lib/ci-runner.sh: one job per run,
# root wipes and prepares user ci around every job, ephemeral registration), enabled and
# running. (Re)starting it runs the prepare step, so errors show up here.
adk_runner_service() {
  local domain="$1" unit_changed=false
  if getent ahosts "$domain" >/dev/null; then
    adk_ok "$domain resolves ($(getent ahosts "$domain" | awk 'NR == 1 {print $1}'))"
  else
    adk_die "$domain does not resolve on this host; create the DNS record first (the runner talks to https://$domain)"
  fi
  if adk_put_file "$ADK_RUNNER_UNIT" 0644 root:root < <(adk_runner_unit "$(id -u "$ADK_CI_USER")"); then
    systemctl daemon-reload
    unit_changed=true
  fi
  if [[ "$(systemctl is-enabled adk-act-runner.service 2>/dev/null)" != enabled ]]; then
    systemctl enable adk-act-runner.service
    adk_changed "adk-act-runner.service enabled"
  fi
  if [[ "$unit_changed" == true || "$ADK_RUNNER_CONFIG_CHANGED" == true ]] || ! systemctl is-active --quiet adk-act-runner.service; then
    if ! systemctl restart adk-act-runner.service; then
      journalctl -u adk-act-runner.service --no-pager -n 30 -o cat >&2 || true
      adk_die "adk-act-runner.service did not start (prepare step failed, see above)"
    fi
    adk_changed "adk-act-runner.service (re)started: fresh environment, ephemeral registration"
  else
    adk_ok "adk-act-runner.service running (one job per run)"
  fi
}

# adk_hostkey_matching FINGERPRINT < ssh-keyscan output: the scanned host key lines whose
# SHA256 fingerprint is FINGERPRINT (comments and other keys dropped)
adk_hostkey_matching() {
  local want="$1" line fp
  while IFS= read -r line; do
    [[ -n "$line" && "$line" != \#* ]] || continue
    fp="$(ssh-keygen -l -E sha256 -f - <<< "$line" 2>/dev/null | awk '{print $2}')" || continue
    [[ "$fp" == "$want" ]] && printf '%s\n' "$line"
  done
  return 0
}

# adk_backup_target_parts TARGET: "user@host port path" of sftp://user@host[:port]/path
adk_backup_target_parts() {
  local rest="${1#sftp://}" userhost path port=22
  userhost="${rest%%/*}"
  path="/${rest#*/}"
  [[ "$rest" == */* ]] || path="."
  if [[ "$userhost" == *:* ]]; then port="${userhost##*:}"; userhost="${userhost%:*}"; fi
  printf '%s %s %s\n' "$userhost" "$port" "$path"
}

# adk_pub_from_private KEY: KEY.pub derived from the private KEY again (ssh-keygen -y), so a
# missing or replaced .pub never disagrees with the key that actually signs (the allowed
# signers file is built from it)
adk_pub_from_private() {
  local key="$1" pub
  [[ -f "$key" && ! -L "$key" ]] || adk_die "$key is missing or a symlink"
  pub="$(ssh-keygen -y -f "$key" 2> /dev/null)" || adk_die "cannot derive the public key of $key"
  [[ -n "$pub" ]] || adk_die "cannot derive the public key of $key"
  adk_put_file "$key.pub" 0644 "$(id -un):$(id -gn)" <<< "$pub" || true
}

# adk_backup_setup TARGET CUSTOMER [ACCEPT_FINGERPRINT]: local backup directory, daily timer
# (03:30, before the 04:30 unattended reboot), the MANIFEST signing key (always: restore.sh
# verifies every backup), and for an off-site TARGET a dedicated SSH key (public part shown)
# and the target's host key, pinned only when the admin confirms its fingerprint
# (setup.sh --accept-backup-hostkey SHA256:...; compare with the provider's published value).
adk_backup_setup() {
  local target="$1" customer="$2" accept="${3:-}" here unit_changed=false sign=/root/.ssh/adk-backup-sign \
    signers=/etc/adk/backup-allowed-signers kh=/root/.ssh/adk-backup.known_hosts userhost port path host scanned pinned
  here="$_ADK_HOST_LIB/.."
  if [[ "$(stat -c '%a %U:%G' /var/backups/adk 2>/dev/null)" != "700 root:root" ]]; then
    install -d -m 0700 -o root -g root /var/backups/adk
    adk_changed "/var/backups/adk (root 0700)"
  fi
  adk_put_file /etc/systemd/system/adk-backup.service 0644 root:root < "$here/systemd/adk-backup.service" && unit_changed=true
  adk_put_file /etc/systemd/system/adk-backup.timer 0644 root:root < "$here/systemd/adk-backup.timer" && unit_changed=true
  adk_put_file /etc/systemd/system/adk-backup-recover.service 0644 root:root < "$here/systemd/adk-backup-recover.service" && unit_changed=true
  [[ "$unit_changed" == false ]] || systemctl daemon-reload
  # at boot: Gitea runs again even after a crash or power loss in the middle of a dump
  if [[ "$(systemctl is-enabled adk-backup-recover.service 2>/dev/null)" != enabled ]]; then
    systemctl enable adk-backup-recover.service > /dev/null 2>&1
    adk_changed "adk-backup-recover.service enabled (starts Gitea at boot if a backup had stopped it)"
  fi
  if [[ "$(systemctl is-enabled adk-backup.timer 2>/dev/null)" != enabled ]] || ! systemctl is-active --quiet adk-backup.timer; then
    systemctl enable --now adk-backup.timer
    adk_changed "adk-backup.timer enabled (daily 03:30)"
  elif [[ "$unit_changed" == true ]]; then
    systemctl restart adk-backup.timer
  else
    adk_ok "adk-backup.timer (daily 03:30)"
  fi
  install -d -m 0700 -o root -g root /root/.ssh
  # signing key for MANIFEST (root only); its public key goes offline with the age key
  if [[ -f "$sign" && ! -L "$sign" ]]; then
    adk_pub_from_private "$sign"
    adk_ok "backup signing key $sign"
  else
    [[ ! -L "$sign" ]] || adk_die "$sign is a symlink"
    rm -f "$sign" "$sign.pub"
    ssh-keygen -q -t ed25519 -N '' -C "adk-backup-sign@$customer" -f "$sign"
    adk_changed "backup signing key $sign created"
    echo "Backup signing public key (keep a copy offline with the age key; restore.sh --signer needs it on a new server):"
    cat "$sign.pub"
  fi
  adk_put_file "$signers" 0644 root:root <<< "adk-backup $(cut -d' ' -f1,2 "$sign.pub")" || true
  [[ -n "$target" ]] || { [[ -z "$accept" ]] || adk_die "--accept-backup-hostkey needs BACKUP_TARGET in kit.env"; return 0; }
  if [[ -f /root/.ssh/adk-backup && ! -L /root/.ssh/adk-backup ]]; then
    adk_pub_from_private /root/.ssh/adk-backup
    adk_ok "backup key /root/.ssh/adk-backup (public: /root/.ssh/adk-backup.pub)"
  else
    [[ ! -L /root/.ssh/adk-backup ]] || adk_die "/root/.ssh/adk-backup is a symlink"
    rm -f /root/.ssh/adk-backup /root/.ssh/adk-backup.pub
    ssh-keygen -q -t ed25519 -N '' -C "adk-backup@$customer" -f /root/.ssh/adk-backup
    adk_changed "backup key /root/.ssh/adk-backup created"
    echo "Off-site backup: add this PUBLIC key to the authorized keys of ${target#sftp://} (private key stays on this server):"
    cat /root/.ssh/adk-backup.pub
  fi
  read -r userhost port path <<< "$(adk_backup_target_parts "$target")"
  host="${userhost#*@}"
  [[ ! -L "$kh" ]] || adk_die "$kh is a symlink"
  if [[ -n "$accept" ]]; then
    [[ "$accept" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] || adk_die "--accept-backup-hostkey expects a SHA256 fingerprint (SHA256:...)"
    scanned="$(ssh-keyscan -T 10 -p "$port" "$host" 2>/dev/null || true)"
    pinned="$(adk_hostkey_matching "$accept" <<< "$scanned")"
    [[ -n "$pinned" ]] || adk_die "no host key of $host:$port has the fingerprint $accept (scanned: $(ssh-keygen -l -E sha256 -f - <<< "$scanned" 2>/dev/null | awk '{print $2, $NF}' | tr '\n' ' '))"
    adk_put_file "$kh" 0600 root:root <<< "$pinned" || true
  fi
  if [[ -s "$kh" ]]; then
    adk_ok "backup target host key pinned ($(ssh-keygen -l -E sha256 -f "$kh" | awk '{print $2}' | tr '\n' ' '))"
  else
    echo "WARNING: the host key of the backup target $host:$port is not pinned yet; off-site copies fail until it is."
    echo "  Scanned fingerprints (compare with the value the provider publishes, never trust the scan alone):"
    ssh-keyscan -T 10 -p "$port" "$host" 2>/dev/null | ssh-keygen -l -E sha256 -f - 2>/dev/null | sed 's/^/    /' || true
    echo "  Then: sudo /opt/adk/agent/setup.sh --accept-backup-hostkey SHA256:<fingerprint>"
  fi
}
