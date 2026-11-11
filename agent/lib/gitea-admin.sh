#!/usr/bin/env bash
# Gitea access for root scripts on the agent VPS (gitea-init.sh, protect-repo.sh): CLI and
# sqlite3 inside the Gitea container (as its user git), REST API against 127.0.0.1:3000 with a
# temporary admin token of GITEA_ADMIN_USER that is passed on stdin (never in argv) and
# deleted again by adk_gitea_admin_end (call it from an EXIT trap).
# Requires host.sh sourced. Names used in SQL are validated by check-config.sh / the callers.
#
# Test overrides (non-root only, see tests/gitea-init.bats): ADK_TEST_PASSWORD_FILE,
# ADK_GITEA_LOCK, ADK_GITEA_LOCK_WAIT.

ADK_GITEA_COMPOSE_FILE=/opt/adk/services/compose.yaml
ADK_GITEA_PASSWORD_FILE=/root/adk-gitea-initial-password
# One kit script with admin access at a time (gitea-init.sh, protect-repo.sh): a second run
# waits. /run is root-only writable (never /run/lock or /tmp: others could plant a symlink).
ADK_GITEA_LOCK="${ADK_GITEA_LOCK:-/run/adk-gitea-admin.lock}"
ADK_GITEA_LOCK_WAIT="${ADK_GITEA_LOCK_WAIT:-600}"
[[ "$(id -u)" -ne 0 ]] || ADK_GITEA_LOCK=/run/adk-gitea-admin.lock

gx() { docker compose -f "$ADK_GITEA_COMPOSE_FILE" exec -T -u git gitea "$@"; }
gitea_cli() { gx gitea "$@"; }
# (busy timeout: Gitea writes to the same database; without it a busy moment fails the call)
sql() { gx sqlite3 -cmd '.timeout 15000' /data/gitea/gitea.db "$1" < /dev/null; }

TOKEN=""        # temporary admin token (memory only)
API_BODY="" API_CODE=""

# api_try [--token T] METHOD PATH [JSON]: sets API_BODY and API_CODE; the token goes via
# stdin. Returns 1 (without exiting) when the call itself fails, e.g. Gitea is down.
api_try() {
  local token="$TOKEN" out
  if [[ "$1" == --token ]]; then token="$2"; shift 2; fi
  local method="$1" path="$2" data=()
  (($# >= 3)) && data=(-H 'Content-Type: application/json' --data-binary "$3")
  API_CODE="" API_BODY=""
  out="$(printf 'Authorization: token %s\n' "$token" \
    | gx curl -q -sS -X "$method" -H @- "${data[@]}" -w '\n%{http_code}' "http://127.0.0.1:3000/api/v1$path")" \
    || return 1
  API_CODE="${out##*$'\n'}"
  API_BODY="${out%$'\n'*}"
}
# api [--token T] METHOD PATH [JSON]: like api_try, a failed call ends the script
api() {
  api_try "$@" || adk_die "API call ${*: -2:1} failed"
}
# json EXPR: evaluate a Python expression over API_BODY (variable d)
json() { python3 -I -c 'import json, sys; d = json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$API_BODY" "$1"; }

# --- temporary admin token ---------------------------------------------------------------
# The API refuses users that must change their password. adk_gitea_admin_begin lifts the flag
# for the run and adk_gitea_admin_end sets it again FIRST (before anything that can fail).
# A marker file next to the password file survives a crash or SIGKILL in between: the next
# run sees it and sets the flag again. An existing password file (not handed over yet) also
# means "must change". Runs are serialized by a lock (ADK_GITEA_LOCK), so leftover adk-init-*
# tokens of killed runs can be deleted at the start; at the end a run deletes its own token
# (name unique per run).
_ADK_GITEA_ADMIN="" _ADK_SET_MUST_CHANGE=false _ADK_TMP_TOKEN_NAME="" _ADK_GITEA_LOCK_FD=""

# _adk_gitea_lock: take the admin lock for the rest of the process (waits ADK_GITEA_LOCK_WAIT s)
_adk_gitea_lock() {
  [[ -z "$_ADK_GITEA_LOCK_FD" ]] || return 0
  [[ ! -L "$ADK_GITEA_LOCK" ]] || adk_die "$ADK_GITEA_LOCK is a symlink"
  exec {_ADK_GITEA_LOCK_FD}>> "$ADK_GITEA_LOCK"
  flock -w "$ADK_GITEA_LOCK_WAIT" "$_ADK_GITEA_LOCK_FD" \
    || adk_die "another kit script is using the Gitea admin access ($ADK_GITEA_LOCK); try again later"
}

adk_gitea_must_change_marker() { printf '%s/.adk-gitea-must-change-pending' "$(dirname "$ADK_GITEA_PASSWORD_FILE")"; }

# adk_gitea_admin_begin ADMIN SCOPES: TOKEN = temporary token of ADMIN with SCOPES
adk_gitea_admin_begin() {
  local admin="$1" scopes="$2" mc marker
  marker="$(adk_gitea_must_change_marker)"
  _ADK_GITEA_ADMIN="$admin"
  _adk_gitea_lock
  _ADK_TMP_TOKEN_NAME="adk-init-$(date -u +%Y%m%d%H%M%S)-$$-$RANDOM"
  # (under the lock: no other run is active, every adk-init-* token is a leftover)
  sql "DELETE FROM access_token WHERE name LIKE 'adk-init-%';" \
    || adk_die "cannot clean up old temporary tokens (is Gitea running?)"
  mc="$(sql "SELECT must_change_password FROM \"user\" WHERE lower_name = '${admin,,}';")"
  if [[ "$mc" == 1 || -e "$marker" || -e "$ADK_GITEA_PASSWORD_FILE" ]]; then
    _ADK_SET_MUST_CHANGE=true
    [[ ! -L "$marker" ]] || adk_die "$marker is a symlink"
    (umask 077; : > "$marker")
    gitea_cli admin user must-change-password --unset "$admin" < /dev/null > /dev/null \
      || adk_die "cannot lift must-change-password of $admin for this run"
  fi
  TOKEN="$(gitea_cli admin user generate-access-token --username "$admin" --token-name "$_ADK_TMP_TOKEN_NAME" \
    --scopes "$scopes" --raw < /dev/null | tail -n 1)"
  [[ "$TOKEN" =~ ^[0-9a-f]{40}$ ]] || { TOKEN=""; adk_die "could not create a temporary admin token"; }
}

# adk_gitea_admin_end: never exits; returns 1 if a step failed (reason on stderr)
adk_gitea_admin_end() {
  local rc=0 marker
  marker="$(adk_gitea_must_change_marker)"
  if [[ "$_ADK_SET_MUST_CHANGE" == true ]]; then
    if gitea_cli admin user must-change-password "$_ADK_GITEA_ADMIN" < /dev/null > /dev/null 2>&1; then
      rm -f "$marker"
    else
      echo "ERROR: could not set must-change-password for $_ADK_GITEA_ADMIN again; the next run of gitea-init.sh does it ($marker)" >&2
      rc=1
    fi
  fi
  if [[ -n "$TOKEN" ]]; then
    sql "DELETE FROM access_token WHERE name = '$_ADK_TMP_TOKEN_NAME';" > /dev/null 2>&1 \
      || echo "ERROR: could not delete the temporary token $_ADK_TMP_TOKEN_NAME (the next run does it)" >&2
    if ! api_try GET /user || [[ "$API_CODE" != 401 ]]; then
      echo "ERROR: temporary admin token $_ADK_TMP_TOKEN_NAME may still work (HTTP ${API_CODE:-none}); delete it in the Gitea UI" >&2
      rc=1
    fi
    TOKEN=""
  fi
  return "$rc"
}

# --- repository protection ---------------------------------------------------------------
# Teams of the organization that get access to a repository, only once it is protected
# (protect-repo.sh): developers (agent-bot) and readers (prod-pull). They are not
# "all repositories" teams, so a new repository is not writable for agent-bot before.
# shellcheck disable=SC2034  # used by gitea-init.sh and protect-repo.sh
ADK_REPO_TEAMS=(developers readers)

# adk_repo_teams ORG/REPO: names of the teams with access to the repository (one per line)
adk_repo_teams() {
  api GET "/repos/$1/teams"
  [[ "$API_CODE" == 200 ]] || adk_die "GET /repos/$1/teams: HTTP $API_CODE"
  json '"\n".join(t["name"] for t in d)'
}

# adk_protection_problems ORG/REPO ADMIN: print one line per missing protection setting of
# the repository's default branch and tags (empty = protected as protect-repo.sh sets it).
# Needs TOKEN with read access to the repository.
adk_protection_problems() {
  local repo="$1" admin="$2" branch
  api GET "/repos/$repo"
  [[ "$API_CODE" == 200 ]] || { echo "repository not readable (HTTP $API_CODE)"; return 0; }
  branch="$(json 'd["default_branch"]')"
  api GET "/repos/$repo/branch_protections"
  [[ "$API_CODE" == 200 ]] || { echo "branch protections not readable (HTTP $API_CODE)"; return 0; }
  python3 -I -c '
import json, sys
rules, branch, admin = json.loads(sys.argv[1]), sys.argv[2], sys.argv[3]
r = next((r for r in rules if r.get("rule_name") == branch), None)
if r is None:
    print(f"default branch {branch}: no protection rule"); sys.exit(0)
want = {"enable_push": False, "enable_force_push": False, "enable_merge_whitelist": True,
        "enable_bypass_allowlist": False, "dismiss_stale_approvals": True,
        "block_on_rejected_reviews": True, "enable_approvals_whitelist": True}
for k, v in want.items():
    if bool(r.get(k)) != v:
        print(f"default branch {branch}: {k} is not {str(v).lower()}")
if (r.get("required_approvals") or 0) < 1:
    print(f"default branch {branch}: required_approvals < 1")
for k in ("merge_whitelist_usernames", "approvals_whitelist_username"):
    if sorted(r.get(k) or []) != [admin]:
        print(f"default branch {branch}: {k} is not only {admin}")
for k in ("merge_whitelist_teams", "approvals_whitelist_teams"):
    if r.get(k):
        print(f"default branch {branch}: {k} is not empty")
' "$API_BODY" "$branch" "$admin"
  api GET "/repos/$repo/tag_protections"
  [[ "$API_CODE" == 200 ]] || { echo "tag protections not readable (HTTP $API_CODE)"; return 0; }
  python3 -I -c '
import json, sys
rules, admin = json.loads(sys.argv[1]), sys.argv[2]
r = next((r for r in rules if r.get("name_pattern") == "*"), None)
if r is None:
    print("tags: no protection rule for *")
elif sorted(r.get("whitelist_usernames") or []) != [admin] or r.get("whitelist_teams"):
    print(f"tags: rule * does not allow only {admin}")
for o in rules:
    pattern = o.get("name_pattern")
    if o is not r and ((o.get("whitelist_usernames") or []) not in ([], [admin]) or o.get("whitelist_teams")):
        print(f"tags: rule {pattern} allows others than {admin}")
' "$API_BODY" "$admin"
}
