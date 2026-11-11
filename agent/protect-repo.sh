#!/usr/bin/env bash
# Protect a repository of the customer organization so that only the employee
# (GITEA_ADMIN_USER) can bring code into the default branch and create tags. Idempotent; runs
# as root on the agent VPS. Prints what it set or checked, never a token.
#
# Usage: sudo /opt/adk/agent/protect-repo.sh [--config FILE] [--status-check CONTEXT]... ORG/REPO
#
#   --status-check CONTEXT  also require this CI status (exact context, e.g.
#                           "ci / test (pull_request)"); repeat for several. Without it no
#                           status check is required (repositories without CI).
#
# Default branch: no direct push for anybody (pull requests only), no force push, merge only
# by GITEA_ADMIN_USER, 1 approval that counts only from GITEA_ADMIN_USER, stale approvals
# dismissed, rejected reviews and open official review requests block the merge, no bypass
# list. Tags: rule "*" - only GITEA_ADMIN_USER may create or delete tags (agent-bot and CI
# jobs cannot push a release tag). Settings that differ are reset; other tag rules that let
# more users tag are reported (remove them in the repository settings).
#
# Uses a temporary admin token of GITEA_ADMIN_USER (lib/gitea-admin.sh: stdin only, deleted
# at the end). Exit codes: 0 = protected, 1 = failure, 2 = usage.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib/host.sh
source "$HERE/lib/host.sh"
# shellcheck source-path=SCRIPTDIR source=lib/gitea-admin.sh
source "$HERE/lib/gitea-admin.sh"
# shellcheck source-path=SCRIPTDIR source=../scripts/lib/config.sh
source "$ROOT/scripts/lib/config.sh"

ADMIN_SCOPES="write:repository,read:organization,read:user"

usage() { echo "usage: $0 [--config FILE] [--status-check CONTEXT]... ORG/REPO" >&2; exit 2; }

CONFIG="$ROOT/kit.env" REPO="" CHECKS=()
while (($#)); do
  case "$1" in
    --config) (($# >= 2)) || usage; CONFIG="$2"; shift 2 ;;
    --status-check)
      (($# >= 2)) || usage
      [[ -n "$2" && "$2" != *[$'\n\r\t"\\']* ]] || { echo "ERROR: bad status check context" >&2; exit 2; }
      CHECKS+=("$2"); shift 2 ;;
    -*) usage ;;
    *) [[ -z "$REPO" ]] || usage; REPO="$1"; shift ;;
  esac
done
[[ "$REPO" =~ ^[a-z0-9-]+/[A-Za-z0-9._-]+$ && "$REPO" != */. && "$REPO" != */.. ]] || usage

if [[ "$(id -u)" -ne 0 ]]; then
  [[ -n "${ADK_TEST_PASSWORD_FILE:-}" ]] || { echo "ERROR: run as root (sudo $0)" >&2; exit 2; }
  ADK_GITEA_PASSWORD_FILE="$ADK_TEST_PASSWORD_FILE"
fi
[[ -f "$CONFIG" ]] || { echo "ERROR: config file not found: $CONFIG" >&2; exit 2; }
if ! check_out="$("$ROOT/scripts/check-config.sh" "$CONFIG")"; then
  printf '%s\n' "$check_out" >&2
  exit 1
fi
load_config "$CONFIG"
ORG="${CFG[CUSTOMER_NAME]}"
ADMIN="${CFG[GITEA_ADMIN_USER]}"
[[ "${REPO%%/*}" == "$ORG" ]] || { echo "ERROR: only repositories of the organization $ORG are managed here" >&2; exit 2; }

trap 'adk_gitea_admin_end || exit 1' EXIT
adk_gitea_admin_begin "$ADMIN" "$ADMIN_SCOPES"

api GET "/repos/$REPO"
case "$API_CODE" in
  200) ;;
  404) adk_die "repository $REPO not found (the employee creates it first)" ;;
  *) adk_die "GET /repos/$REPO: HTTP $API_CODE" ;;
esac
BRANCH="$(json 'd["default_branch"]')"
[[ "$BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] || adk_die "unexpected default branch name: $BRANCH"

# --- default branch -------------------------------------------------------------------------
echo "== $REPO: branch $BRANCH"
checks_json="$(python3 -I -c 'import json, sys; print(json.dumps(sys.argv[1:]))' "${CHECKS[@]}")"
want="$(python3 -I -c '
import json, sys
admin, checks = sys.argv[1], json.loads(sys.argv[2])
print(json.dumps({
    "enable_push": False, "enable_push_whitelist": False, "push_whitelist_usernames": [],
    "push_whitelist_teams": [], "push_whitelist_deploy_keys": False,
    "enable_force_push": False, "enable_force_push_allowlist": False,
    "force_push_allowlist_usernames": [], "force_push_allowlist_teams": [],
    "force_push_allowlist_deploy_keys": False,
    "enable_merge_whitelist": True, "merge_whitelist_usernames": [admin], "merge_whitelist_teams": [],
    "enable_bypass_allowlist": False, "bypass_allowlist_usernames": [], "bypass_allowlist_teams": [],
    "enable_status_check": bool(checks), "status_check_contexts": checks,
    "required_approvals": 1, "enable_approvals_whitelist": True,
    "approvals_whitelist_username": [admin], "approvals_whitelist_teams": [],
    "block_on_rejected_reviews": True, "block_on_official_review_requests": True,
    "dismiss_stale_approvals": True, "ignore_stale_approvals": False,
}, sort_keys=True))' "$ADMIN" "$checks_json")"

api GET "/repos/$REPO/branch_protections/$BRANCH"
case "$API_CODE" in
  404)
    body="$(python3 -I -c 'import json, sys; w = json.loads(sys.argv[1]); w["rule_name"] = sys.argv[2]; print(json.dumps(w))' "$want" "$BRANCH")"
    api POST "/repos/$REPO/branch_protections" "$body"
    [[ "$API_CODE" == 201 ]] || adk_die "cannot protect $BRANCH (HTTP $API_CODE): $API_BODY"
    adk_changed "$REPO $BRANCH protected (pull requests only, merge and approval only by $ADMIN)"
    ;;
  200)
    diff="$(python3 -I -c '
import json, sys
cur, want = json.loads(sys.argv[1]), json.loads(sys.argv[2])
bad = [k for k, v in want.items() if (sorted(cur.get(k) or []) if isinstance(v, list) else cur.get(k)) != (sorted(v) if isinstance(v, list) else v)]
print(" ".join(bad))' "$API_BODY" "$want")"
    if [[ -n "$diff" ]]; then
      api PATCH "/repos/$REPO/branch_protections/$BRANCH" "$want"
      [[ "$API_CODE" == 200 ]] || adk_die "cannot update the protection of $BRANCH (HTTP $API_CODE): $API_BODY"
      adk_changed "$REPO $BRANCH protection reset ($diff)"
    else
      adk_ok "$REPO $BRANCH protected (pull requests only, merge and approval only by $ADMIN)"
    fi
    ;;
  *) adk_die "GET branch protection of $BRANCH: HTTP $API_CODE" ;;
esac

# --- tags ---------------------------------------------------------------------------------------
echo "== $REPO: tags"
api GET "/repos/$REPO/tags/protections"
[[ "$API_CODE" == 200 ]] || adk_die "GET tag protections: HTTP $API_CODE"
rule="$(python3 -I -c '
import json, sys
d, admin = json.loads(sys.argv[1]), sys.argv[2]
r = next((r for r in d if r.get("name_pattern") == "*"), None)
if r is not None:
    ok = sorted(r.get("whitelist_usernames") or []) == [admin] and not r.get("whitelist_teams")
    print(r["id"], "ok" if ok else "differs")' "$API_BODY" "$ADMIN")"
others="$(python3 -I -c '
import json, sys
d, admin = json.loads(sys.argv[1]), sys.argv[2]
for r in d:
    if r.get("name_pattern") != "*" and ((r.get("whitelist_usernames") or []) not in ([], [admin]) or r.get("whitelist_teams")):
        print(r.get("name_pattern"))' "$API_BODY" "$ADMIN")"
tag_body="{\"name_pattern\":\"*\",\"whitelist_usernames\":[\"$ADMIN\"],\"whitelist_teams\":[]}"
if [[ -z "$rule" ]]; then
  api POST "/repos/$REPO/tags/protections" "$tag_body"
  [[ "$API_CODE" == 201 ]] || adk_die "cannot protect tags (HTTP $API_CODE): $API_BODY"
  adk_changed "$REPO tags protected (only $ADMIN creates or deletes tags)"
elif [[ "${rule#* }" != ok ]]; then
  api PATCH "/repos/$REPO/tags/protections/${rule%% *}" "$tag_body"
  [[ "$API_CODE" == 200 ]] || adk_die "cannot update the tag protection (HTTP $API_CODE): $API_BODY"
  adk_changed "$REPO tag protection reset (only $ADMIN)"
else
  adk_ok "$REPO tags protected (only $ADMIN creates or deletes tags)"
fi
if [[ -n "$others" ]]; then
  echo "WARNING: other tag rules of $REPO let more users than $ADMIN tag; remove them in the repository settings: ${others//$'\n'/, }"
fi

problems="$(adk_protection_problems "$REPO" "$ADMIN")"
[[ -z "$problems" ]] || { printf '%s\n' "$problems" >&2; adk_die "$REPO is still not protected as required (see above)"; }
echo "protect-repo done: $REPO"
