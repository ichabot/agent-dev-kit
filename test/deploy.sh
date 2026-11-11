#!/usr/bin/env bash
# Root step of a TEST deployment. Called only through the deploy gate:
#   deploy (ssh, forced command) -> test/deploy-gate.sh -> sudo -n /opt/adk/test/deploy.sh P REF
# (one sudoers rule, /etc/sudoers.d/adk-deploy). Runs as root on the TEST VM.
#
# Usage: deploy.sh <project> <ref>
#   project  ^[a-z][a-z0-9-]{1,38}$ = repository CUSTOMER_NAME/<project> in Gitea
#   ref      40-hex commit SHA or tag v<major>.<minor>.<patch>[-<prerelease>]
#
# Steps (one deployment at a time, root lock /run/adk/test-deploy.lock):
#  1. validate both arguments again (sudo passes them as given), kit and kit.env
#  2. fetch the repository archive at <ref> from https://GITEA_DOMAIN with the read-only token
#     of the Gitea bot test-pull (/opt/adk/secrets/gitea-pull-token, root 0600; passed to curl
#     on stdin) and extract ONLY its deploy/ directory (regular files and directories; links,
#     devices, "..", oversize archives refused - test/lib/deploy.py)
#  3. deploy/adk.json = {"http_port": <port>}: the app's port on 127.0.0.1 (1024-65535, not
#     used by another project)
#  4. /srv/test/<project>/deploy is replaced by the new files (root-owned, read-only for the
#     app); .env is created once from deploy/.env.example and never touched again
#  5. deploy/update.sh --non-interactive --additive-only --version <ref> runs in
#     /srv/test/<project> as the system user adk-app (member of group docker: the project's
#     docker compose runs on the root Docker daemon - TEST is the blast radius, test data
#     only). It never runs as root. Registry credentials (test-pull) in a temporary
#     DOCKER_CONFIG. On failure the previous deploy/ files are put back.
#  6. wait for http://127.0.0.1:<port>/healthz
#  7. Caddy site <project>.TEST_DOMAIN -> 127.0.0.1:<port>: written, validated (caddy
#     validate), then reloaded; on any failure the previous site file is restored.
#
# Exit codes: 0 = deployed, 1 = deployment failed, 2 = usage / refused arguments.
# Tests (non-root only): ADK_TEST_ROOT prefixes every path, the app user switch is skipped.
set -euo pipefail
export LC_ALL=C
umask 022
APP_PATH="$PATH"   # tests only (non-root); as root both are fixed
if [[ "$(id -u)" -eq 0 ]]; then
  export PATH=/usr/sbin:/usr/bin:/sbin:/bin
  APP_PATH=/usr/local/bin:/usr/bin:/bin
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

PROJECT_RE='^[a-z][a-z0-9-]{1,38}$'
REF_RE='^([0-9a-f]{40}|v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?)$'
if (($# != 2)) || [[ ! "$1" =~ $PROJECT_RE ]] || [[ ! "$2" =~ $REF_RE ]]; then
  echo "usage: $0 <project> <commit-sha|vX.Y.Z>" >&2
  exit 2
fi
PROJECT="$1" REF="$2"

T=""
if [[ "$(id -u)" -ne 0 ]]; then
  [[ -n "${ADK_TEST_ROOT:-}" ]] || { echo "ERROR: run as root (through the deploy gate)" >&2; exit 2; }
  T="$ADK_TEST_ROOT"
else
  # deploy.sh runs from the installed kit only
  [[ "$ROOT" == /opt/adk ]] || { echo "ERROR: deploy.sh runs from /opt/adk only" >&2; exit 2; }
fi
KIT="$T/opt/adk"
CONFIG="$KIT/kit.env"
TOKEN_FILE="$KIT/secrets/gitea-pull-token"
SERVICES="$KIT/test-services"
SITES="$SERVICES/sites"
SRV="$T/srv/test"
LOCK_DIR="$T/run/adk"
APP_USER=adk-app
PULL_USER=test-pull
UPDATE_TIMEOUT=30m HEALTH_WAIT=60
if [[ -n "$T" ]]; then UPDATE_TIMEOUT="${ADK_UPDATE_TIMEOUT:-60}" HEALTH_WAIT="${ADK_HEALTH_WAIT:-3}"; fi

# shellcheck source-path=SCRIPTDIR source=../agent/lib/host.sh
source "$ROOT/agent/lib/host.sh"
# shellcheck source-path=SCRIPTDIR source=../scripts/lib/config.sh
source "$ROOT/scripts/lib/config.sh"

say() { echo "deploy $PROJECT $REF: $*"; }
fail() { echo "ERROR: deploy $PROJECT $REF: $*" >&2; exit 1; }
py() { python3 -I "$HERE/lib/deploy.py" "$@"; }
caddy() {
  docker compose -f "$SERVICES/compose.yaml" --project-directory "$SERVICES" exec -T caddy caddy "$@" \
    --config /etc/caddy/Caddyfile --adapter caddyfile < /dev/null
}

# --- 1. kit and configuration --------------------------------------------------------
if [[ -z "$T" ]]; then
  adk_check_kit_tree "$KIT" root > /dev/null || fail "/opt/adk is not root-owned (see above); re-run bootstrap"
fi
"$ROOT/scripts/check-config.sh" "$CONFIG" > /dev/null || fail "kit.env is invalid (scripts/check-config.sh)"
load_config "$CONFIG"
ORG="${CFG[CUSTOMER_NAME]}" GITEA="${CFG[GITEA_DOMAIN]}" DOMAIN="${CFG[TEST_DOMAIN]}" MODE="${CFG[ACME_MODE]}"

# --- lock: one deployment at a time ------------------------------------------------------
[[ ! -L "$LOCK_DIR" ]] || fail "$LOCK_DIR is a symlink"
[[ -d "$LOCK_DIR" ]] || (umask 077 && mkdir -p -- "$LOCK_DIR")
[[ "$(stat -c '%u %a' -- "$LOCK_DIR")" == "$(id -u) 700" ]] || fail "$LOCK_DIR must be 0700 and ours"
LOCK="$LOCK_DIR/test-deploy.lock"
[[ ! -L "$LOCK" && ( ! -e "$LOCK" || -f "$LOCK" ) ]] || fail "$LOCK must be a regular file"
exec {lock_fd}>> "$LOCK"
flock -w 900 "$lock_fd" || fail "another deployment is still running"

WORK="$(mktemp -d "$LOCK_DIR/deploy.XXXXXX")"
# registry credentials for the app user: outside the root-only lock directory
[[ -z "$T" ]] || install -d -m 0755 "$T/run"
docker_config="$(mktemp -d "$T/run/adk-deploy-docker.XXXXXX")"
cleanup() { rm -rf "$WORK" "$docker_config"; }
trap cleanup EXIT

# --- 2. fetch deploy/ at the ref -------------------------------------------------------
[[ -f "$TOKEN_FILE" && ! -L "$TOKEN_FILE" ]] \
  || fail "no Gitea pull token: on the agent VPS run agent/test-pull-token.sh | ssh <test> sudo /opt/adk/agent/set-secret.sh gitea-pull-token"
token="$(head -c 200 "$TOKEN_FILE" | tr -d '\r\n')"
[[ "$token" =~ ^[0-9a-f]{40}$ ]] || fail "$TOKEN_FILE does not hold a Gitea token"
say "fetching $ORG/$PROJECT at $REF from https://$GITEA"
url="https://$GITEA/api/v1/repos/$ORG/$PROJECT/archive/$REF.tar.gz"
if ! printf 'Authorization: token %s\n' "$token" \
    | curl -q -fsS --proto '=https' --max-time 300 --max-filesize 209715200 -H @- -o "$WORK/src.tar.gz" "$url"; then
  fail "cannot fetch $ORG/$PROJECT at $REF (repository protected and readable for test-pull? ref pushed?)"
fi
py extract "$WORK/src.tar.gz" "$WORK/deploy" || fail "deploy/ at $REF is not usable (see above)"
port="$(py http-port "$WORK/deploy/adk.json")" || fail "deploy/adk.json is not usable (see above)"

# --- 3. port not used by another project -----------------------------------------------
for f in "$SRV"/*/http_port; do
  [[ -f "$f" ]] || continue
  other="$(basename "$(dirname "$f")")"
  [[ "$other" != "$PROJECT" ]] || continue
  [[ "$(cat "$f")" != "$port" ]] || fail "http_port $port is already used by project $other"
done

# --- 4. install the files --------------------------------------------------------------
dir="$SRV/$PROJECT"
install -d -m 0755 "$SRV" "$dir"
[[ ! -L "$dir/deploy" && ! -L "$dir/deploy.prev" ]] || fail "$dir contains symlinks"
rm -rf "$dir/deploy.prev"
[[ ! -e "$dir/deploy" ]] || mv "$dir/deploy" "$dir/deploy.prev"
mv "$WORK/deploy" "$dir/deploy"
restore_files() {
  rm -rf "$dir/deploy"
  [[ ! -e "$dir/deploy.prev" ]] || mv "$dir/deploy.prev" "$dir/deploy"
}
app_owner="$(id -un):$(id -gn)"
[[ -n "$T" ]] || app_owner="$APP_USER:$APP_USER"
if [[ ! -d "$dir/state" || -L "$dir/state" ]]; then
  rm -f "$dir/state"
  install -d -m 0750 -o "${app_owner%%:*}" -g "${app_owner#*:}" "$dir/state"
fi
if [[ ! -e "$dir/.env" && -f "$dir/deploy/.env.example" ]]; then
  install -m 0640 -o "$(id -un)" -g "${app_owner#*:}" "$dir/deploy/.env.example" "$dir/.env"
  say ".env created from deploy/.env.example (never changed by later deployments)"
fi

# --- 5. update.sh as the app user ------------------------------------------------------
py docker-auth "$GITEA" "$PULL_USER" <<< "$token" > "$docker_config/config.json"
token=""
chmod 0600 "$docker_config/config.json"
[[ -n "$T" ]] || chown -R "$APP_USER:$APP_USER" "$docker_config"
say "running deploy/update.sh --non-interactive --additive-only --version $REF (as $APP_USER)"
run_env=(env -i PATH="$APP_PATH" HOME="$dir/state" LC_ALL=C.UTF-8
  DOCKER_CONFIG="$docker_config" COMPOSE_PROJECT_NAME="$PROJECT" ADK_PROJECT="$PROJECT"
  ADK_STATE_DIR="$dir/state" ADK_ENV="test")
as_app=(runuser -u "$APP_USER" --)
[[ -z "$T" ]] || as_app=()
rc=0
(cd "$dir" && exec {lock_fd}>&- && exec "${as_app[@]}" "${run_env[@]}" \
  timeout "$UPDATE_TIMEOUT" deploy/update.sh --non-interactive --additive-only --version "$REF" < /dev/null) || rc=$?
rm -rf "$docker_config"
if ((rc != 0)); then
  restore_files
  fail "deploy/update.sh failed (exit $rc); previous deploy/ files restored, Caddy unchanged"
fi
printf '%s\n' "$port" > "$dir/http_port"
printf '%s\n' "$REF" > "$dir/VERSION"

# --- 6. health -----------------------------------------------------------------------------
healthy=false
for ((i = 0; i < HEALTH_WAIT; i++)); do
  if curl -q -fsS -o /dev/null --max-time 5 "http://127.0.0.1:$port/healthz" 2>/dev/null; then
    healthy=true
    break
  fi
  sleep 1
done
[[ "$healthy" == true ]] || fail "no answer on http://127.0.0.1:$port/healthz within ${HEALTH_WAIT}s; Caddy unchanged"
say "healthy on 127.0.0.1:$port"

# --- 7. Caddy site -------------------------------------------------------------------------
site="$SITES/$PROJECT.caddy"
new="$WORK/site"
host="$PROJECT.$DOMAIN"
if [[ "$MODE" == dns01 ]]; then
  # imported inside the *.TEST_DOMAIN block (one wildcard certificate)
  printf '# deploy.sh: %s at %s\n@adk-%s host %s\nhandle @adk-%s {\n\treverse_proxy 127.0.0.1:%s\n}\n' \
    "$PROJECT" "$REF" "$PROJECT" "$host" "$PROJECT" "$port" > "$new"
else
  printf '# deploy.sh: %s at %s\n%s {\n\timport adk_site\n\treverse_proxy 127.0.0.1:%s\n}\n' \
    "$PROJECT" "$REF" "$host" "$port" > "$new"
fi
[[ ! -L "$site" ]] || fail "$site is a symlink"
if [[ -f "$site" ]] && cmp -s <(tail -n +2 "$site") <(tail -n +2 "$new"); then
  say "Caddy site https://$host/ unchanged"
else
  backup="$WORK/site.old"
  [[ ! -f "$site" ]] || cp -p "$site" "$backup"
  restore_site() {
    if [[ -f "$backup" ]]; then cp -p "$backup" "$site"; else rm -f "$site"; fi
  }
  install -m 0644 "$new" "$site"
  if ! caddy validate > "$WORK/caddy.log" 2>&1; then
    tail -n 5 "$WORK/caddy.log" >&2
    restore_site
    fail "Caddy rejects the new site; previous Caddy configuration kept"
  fi
  if ! caddy reload --address unix//run/caddy/admin.sock > "$WORK/caddy.log" 2>&1; then
    tail -n 5 "$WORK/caddy.log" >&2
    restore_site
    caddy reload --address unix//run/caddy/admin.sock > /dev/null 2>&1 || true
    fail "Caddy reload failed; previous site restored"
  fi
  say "Caddy site https://$host/ -> 127.0.0.1:$port"
fi
say "done: https://$host/"
