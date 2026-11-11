#!/usr/bin/env bash
# Create the Gitea organization, teams and accounts of the agent VPS. Idempotent; runs as
# root on the VPS (setup.sh calls it after Gitea is healthy). Prints only what it created or
# checked, never a password or token.
#
# Usage: sudo /opt/adk/agent/gitea-init.sh [--config FILE]     (default: /opt/adk/kit.env)
#
# Result:
#   GITEA_ADMIN_USER  site admin (the customer's employee); random initial password ONLY in
#                     /root/adk-gitea-initial-password (0600), must be changed at first login
#   agent-bot         bot account (no password, cannot log in to the web UI), member of team
#                     "developers" of the organization: write on all repositories, no admin,
#                     cannot create repositories (Gitea makes a repository's creator its admin,
#                     which would let agent-bot change branch protection)
#   prod-pull         bot account in team "readers" (read code, releases, packages); its
#                     token is created per PROD server later
#   CUSTOMER_NAME     private organization, owned by GITEA_ADMIN_USER
#   hermes            ~/.config/gitea/token (agent-bot token, 0600) and a git credential
#                     helper for https://GITEA_DOMAIN, written AS hermes (lib/user-file.sh)
#
# API calls run inside the Gitea container against 127.0.0.1:3000 with a temporary token of
# the admin user, passed on stdin (never in argv) and deleted again at the end.
# Tests: as non-root with ADK_AS_USER_HOOK set, ADK_TEST_HERMES_HOME and
# ADK_TEST_PASSWORD_FILE replace the real paths (ignored as root).
# Exit codes: 0 = done, 1 = failure, 2 = usage, 3 = refused file operation in hermes's home.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib/host.sh
source "$HERE/lib/host.sh"
# shellcheck source-path=SCRIPTDIR source=../scripts/lib/config.sh
source "$ROOT/scripts/lib/config.sh"

AGENT_USER=hermes
BOT=agent-bot
PULL=prod-pull
BOT_SCOPES="write:repository,write:issue,read:user,write:package,read:organization"
COMPOSE_FILE=/opt/adk/services/compose.yaml
PASSWORD_FILE=/root/adk-gitea-initial-password

usage() { echo "usage: $0 [--config FILE]" >&2; exit 2; }

CONFIG="$ROOT/kit.env"
while (($#)); do
  case "$1" in
    --config) (($# >= 2)) || usage; CONFIG="$2"; shift 2 ;;
    *) usage ;;
  esac
done

if [[ "$(id -u)" -ne 0 ]]; then
  [[ -n "${ADK_AS_USER_HOOK:-}" && -n "${ADK_TEST_HERMES_HOME:-}" && -n "${ADK_TEST_PASSWORD_FILE:-}" ]] \
    || { echo "ERROR: run as root (sudo $0)" >&2; exit 2; }
  PASSWORD_FILE="$ADK_TEST_PASSWORD_FILE"
  AGENT_HOME="$ADK_TEST_HERMES_HOME"
else
  AGENT_HOME="$(adk_user_home "$AGENT_USER")"
  [[ -n "$AGENT_HOME" ]] || adk_die "user $AGENT_USER does not exist (run setup.sh first)"
fi

[[ -f "$CONFIG" ]] || { echo "ERROR: config file not found: $CONFIG" >&2; exit 2; }
if ! check_out="$("$ROOT/scripts/check-config.sh" "$CONFIG")"; then
  printf '%s\n' "$check_out" >&2
  exit 1
fi
load_config "$CONFIG"
ORG="${CFG[CUSTOMER_NAME]}"
ADMIN="${CFG[GITEA_ADMIN_USER]}"
ADMIN_EMAIL="${CFG[GITEA_ADMIN_EMAIL]}"
DOMAIN="${CFG[GITEA_DOMAIN]}"

# --- Gitea access (inside the container, as its user git) -------------------------------
gx() { docker compose -f "$COMPOSE_FILE" exec -T -u git gitea "$@"; }
gitea_cli() { gx gitea "$@"; }
# Names in SQL are checked against ^[a-z0-9._-]+$ by check-config.sh / constants above.
sql() { gx sqlite3 /data/gitea/gitea.db "$1" < /dev/null; }

TOKEN=""        # temporary admin token (memory only)
API_BODY="" API_CODE=""
# api [--token T] METHOD PATH [JSON]: sets API_BODY and API_CODE; the token goes via stdin
api() {
  local token="$TOKEN" out
  if [[ "$1" == --token ]]; then token="$2"; shift 2; fi
  local method="$1" path="$2" data=()
  (($# >= 3)) && data=(-H 'Content-Type: application/json' --data-binary "$3")
  out="$(printf 'Authorization: token %s\n' "$token" \
    | gx curl -q -sS -X "$method" -H @- "${data[@]}" -w '\n%{http_code}' "http://127.0.0.1:3000/api/v1$path")" \
    || adk_die "API call $method $path failed"
  API_CODE="${out##*$'\n'}"
  API_BODY="${out%$'\n'*}"
}
# json EXPR: evaluate a Python expression over API_BODY (variable d)
json() { python3 -I -c 'import json, sys; d = json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$API_BODY" "$1"; }

# user_row NAME: "<is_admin> <type>" from `gitea admin user list`, empty if missing
user_row() {
  gitea_cli admin user list < /dev/null | awk -v u="$1" 'NR > 1 && tolower($2) == tolower(u) {print $5, $7}'
}

# --- accounts ---------------------------------------------------------------------------
echo "== gitea accounts"
SET_MUST_CHANGE=false
row="$(user_row "$ADMIN")"
if [[ -z "$row" ]]; then
  # Gitea prints the random password once; it goes only into the root-owned file.
  out="$(gitea_cli admin user create --username "$ADMIN" --email "$ADMIN_EMAIL" --admin \
    --random-password --random-password-length 24 --must-change-password=false < /dev/null)" \
    || adk_die "cannot create Gitea user $ADMIN"
  pw="$(sed -n "s/^generated random password is '\(.*\)'\$/\1/p" <<< "$out")"
  out=""
  [[ -n "$pw" ]] || adk_die "no initial password in Gitea's output; reset it with: gitea admin user change-password"
  [[ ! -L "$PASSWORD_FILE" ]] || adk_die "$PASSWORD_FILE is a symlink"
  (
    umask 077
    printf 'Gitea: https://%s/\nUser: %s\nInitial password (change it at the first login): %s\n' \
      "$DOMAIN" "$ADMIN" "$pw" > "$PASSWORD_FILE.tmp"
    mv -f "$PASSWORD_FILE.tmp" "$PASSWORD_FILE"
  )
  pw=""
  SET_MUST_CHANGE=true
  adk_changed "gitea user $ADMIN (site admin), initial password in $PASSWORD_FILE"
else
  [[ "${row%% *}" == true ]] || adk_die "Gitea user $ADMIN exists but is not a site admin"
  adk_ok "gitea user $ADMIN (site admin)"
fi

for bot in "$BOT" "$PULL"; do
  row="$(user_row "$bot")"
  if [[ -z "$row" ]]; then
    gitea_cli admin user create --username "$bot" --email "$bot@noreply.$DOMAIN" --user-type bot \
      < /dev/null > /dev/null || adk_die "cannot create Gitea user $bot"
    adk_changed "gitea bot $bot (no password, no web login)"
  else
    [[ "${row%% *}" == false ]] || adk_die "Gitea user $bot is a site admin; remove that right in the admin UI first"
    adk_ok "gitea user $bot (not admin, type ${row#* })"
  fi
done

# --- temporary admin token -------------------------------------------------------------
# The API refuses users that must change their password: lift the flag for this run and put
# it back at the end (the password stays unknown to everybody but the employee / root).
TMP_TOKEN_NAME="adk-init-$(date -u +%Y%m%d%H%M%S)-$$"
mc="$(sql "SELECT must_change_password FROM \"user\" WHERE lower_name = '${ADMIN,,}';")"
[[ "$mc" == 1 ]] && SET_MUST_CHANGE=true

cleanup() {
  local rc=$?
  trap - EXIT
  if [[ -n "$TOKEN" ]]; then
    sql "DELETE FROM access_token WHERE name = '$TMP_TOKEN_NAME';" || echo "ERROR: could not delete the temporary token $TMP_TOKEN_NAME" >&2
    api GET /user
    if [[ "$API_CODE" != 401 ]]; then
      echo "ERROR: temporary admin token $TMP_TOKEN_NAME still works (HTTP $API_CODE); delete it in the Gitea UI" >&2
      rc=1
    fi
    TOKEN=""
  fi
  if [[ "$SET_MUST_CHANGE" == true ]]; then
    gitea_cli admin user must-change-password "$ADMIN" < /dev/null > /dev/null \
      || { echo "ERROR: could not set must-change-password for $ADMIN" >&2; rc=1; }
  fi
  exit "$rc"
}
trap cleanup EXIT
if [[ "$SET_MUST_CHANGE" == true ]]; then
  gitea_cli admin user must-change-password --unset "$ADMIN" < /dev/null > /dev/null
fi
TOKEN="$(gitea_cli admin user generate-access-token --username "$ADMIN" --token-name "$TMP_TOKEN_NAME" \
  --scopes "write:organization,read:user" --raw < /dev/null | tail -n 1)"
[[ "$TOKEN" =~ ^[0-9a-f]{40}$ ]] || { TOKEN=""; adk_die "could not create a temporary admin token"; }

# --- organization and teams -------------------------------------------------------------
echo "== gitea organization $ORG"
api GET "/orgs/$ORG"
case "$API_CODE" in
  200) adk_ok "organization $ORG ($(json 'd["visibility"]'))" ;;
  404)
    api POST /orgs "{\"username\":\"$ORG\",\"full_name\":\"$ORG\",\"visibility\":\"private\",\"repo_admin_change_team_access\":false}"
    [[ "$API_CODE" == 201 ]] || adk_die "cannot create organization $ORG (HTTP $API_CODE): $API_BODY"
    adk_changed "organization $ORG (private, owner $ADMIN)"
    ;;
  *) adk_die "GET /orgs/$ORG: HTTP $API_CODE" ;;
esac

DEV_UNITS='{"repo.code":"write","repo.issues":"write","repo.pulls":"write","repo.releases":"write","repo.wiki":"write","repo.projects":"write","repo.packages":"write","repo.actions":"write","repo.ext_issues":"read","repo.ext_wiki":"read"}'
READ_UNITS='{"repo.code":"read","repo.releases":"read","repo.packages":"read"}'

# ensure_team NAME PERMISSION UNITS_JSON DESCRIPTION: prints the team id
declare -A TEAM_ID=()
ensure_team() {
  local name="$1" permission="$2" units="$3" desc="$4" body id
  body="{\"name\":\"$name\",\"description\":\"$desc\",\"permission\":\"$permission\",\"includes_all_repositories\":true,\"can_create_org_repo\":false,\"units_map\":$units}"
  api GET "/orgs/$ORG/teams?limit=50"
  [[ "$API_CODE" == 200 ]] || adk_die "GET /orgs/$ORG/teams: HTTP $API_CODE"
  id="$(json "next((t['id'] for t in d if t['name'] == '$name'), '')")"
  if [[ -z "$id" ]]; then
    api POST "/orgs/$ORG/teams" "$body"
    [[ "$API_CODE" == 201 ]] || adk_die "cannot create team $name (HTTP $API_CODE): $API_BODY"
    id="$(json 'd["id"]')"
    adk_changed "team $name ($permission on all repositories, no repository creation)"
  else
    local current
    current="$(json "next(t for t in d if t['name'] == '$name')")"
    if ! python3 -I -c '
import ast, json, sys
t = ast.literal_eval(sys.argv[1]); want = json.loads(sys.argv[2])
ok = t.get("includes_all_repositories") is True and t.get("can_create_org_repo") is False \
  and {k: v for k, v in (t.get("units_map") or {}).items() if v != "none"} == want
sys.exit(0 if ok else 1)' "$current" "$units"; then
      api PATCH "/teams/$id" "$body"
      [[ "$API_CODE" == 200 ]] || adk_die "cannot update team $name (HTTP $API_CODE): $API_BODY"
      adk_changed "team $name reset to $permission on all repositories"
    else
      adk_ok "team $name"
    fi
  fi
  TEAM_ID[$name]="$id"
}

# ensure_member TEAM USER
ensure_member() {
  local team="$1" user="$2"
  api GET "/teams/${TEAM_ID[$team]}/members/$user"
  if [[ "$API_CODE" == 200 ]]; then
    adk_ok "$user in team $team"
    return 0
  fi
  api PUT "/teams/${TEAM_ID[$team]}/members/$user"
  [[ "$API_CODE" == 204 ]] || adk_die "cannot add $user to team $team (HTTP $API_CODE): $API_BODY"
  adk_changed "$user added to team $team"
}

ensure_team developers write "$DEV_UNITS" "agent-bot: write on all repositories, no admin"
ensure_team readers read "$READ_UNITS" "prod-pull: read code, releases and packages"
ensure_member developers "$BOT"
ensure_member readers "$PULL"

# Neither bot may own the organization (owners can change branch protection and settings).
api GET "/orgs/$ORG/teams?limit=50"
owners="$(json "next((t['id'] for t in d if t['name'] == 'Owners'), '')")"
[[ -n "$owners" ]] || adk_die "organization $ORG has no Owners team"
for bot in "$BOT" "$PULL"; do
  api GET "/teams/$owners/members/$bot"
  [[ "$API_CODE" == 404 ]] || adk_die "$bot is an owner of $ORG; remove it from the Owners team"
done
adk_ok "$BOT and $PULL are not owners of $ORG"

# --- agent-bot token for hermes ----------------------------------------------------------
echo "== agent-bot token for $AGENT_USER"
token_file="$AGENT_HOME/.config/gitea/token"
have_valid=false
if adk_user_test "$AGENT_USER" "$AGENT_HOME" -f "$token_file"; then
  current="$(adk_as_user "$AGENT_USER" cat "$token_file" 2>/dev/null | head -c 200 | tr -d '\r\n')" || current=""
  if [[ "$current" =~ ^[0-9a-f]{40}$ ]]; then
    api --token "$current" GET /user
    [[ "$API_CODE" == 200 && "$(json 'd["login"]')" == "$BOT" ]] && have_valid=true
  fi
  current=""
fi
if [[ "$have_valid" == true ]]; then
  adk_ok "$token_file (valid $BOT token)"
else
  name="hermes-$(date -u +%Y%m%dT%H%M%SZ)"
  new="$(gitea_cli admin user generate-access-token --username "$BOT" --token-name "$name" \
    --scopes "$BOT_SCOPES" --raw < /dev/null | tail -n 1)"
  [[ "$new" =~ ^[0-9a-f]{40}$ ]] || adk_die "could not create a token for $BOT"
  adk_user_mkdir "$AGENT_USER" "$AGENT_HOME" "$AGENT_HOME/.config" 0700 || true
  adk_user_mkdir "$AGENT_USER" "$AGENT_HOME" "$AGENT_HOME/.config/gitea" 0700 || true
  adk_user_put_file "$AGENT_USER" "$AGENT_HOME" "$token_file" 0600 <<< "$new" > /dev/null || true
  new=""
  # Older tokens of earlier runs stop working: the file is the only place a token lives.
  bot_id="$(sql "SELECT id FROM \"user\" WHERE lower_name = '$BOT';")"
  [[ "$bot_id" =~ ^[0-9]+$ ]] || adk_die "no id for $BOT"
  sql "DELETE FROM access_token WHERE uid = $bot_id AND name LIKE 'hermes-%' AND name <> '$name';"
  adk_changed "$token_file ($BOT token $name, scopes $BOT_SCOPES; older hermes-* tokens revoked)"
fi

helper="$AGENT_HOME/.config/gitea/git-credential"
adk_user_mkdir "$AGENT_USER" "$AGENT_HOME" "$AGENT_HOME/.config/gitea" 0700 || true
adk_user_put_file "$AGENT_USER" "$AGENT_HOME" "$helper" 0700 <<EOF || true
#!/bin/sh
# git credential helper (agent-dev-kit): agent-bot token for https://$DOMAIN
[ "\$1" = get ] || exit 0
printf 'username=$BOT\npassword=%s\n' "\$(cat "\$HOME/.config/gitea/token")"
EOF
adk_user_put_block "$AGENT_USER" "$AGENT_HOME" "$AGENT_HOME/.gitconfig" "adk gitea" bottom <<EOF
[credential "https://$DOMAIN"]
	helper =
	helper = $helper
	username = $BOT
EOF

echo
echo "gitea-init done: organization $ORG, teams developers/readers, users $ADMIN, $BOT, $PULL"
if [[ -f "$PASSWORD_FILE" ]]; then
  echo "Initial password of $ADMIN: $PASSWORD_FILE (root only); hand it over, then delete the file"
fi
