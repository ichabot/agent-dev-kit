#!/usr/bin/env bash
# Create a NEW read-only Gitea token of the bot test-pull for the TEST VM and write it to a pipe
# (never to a terminal). Runs as root on the agent VPS:
#
#   ssh adk-admin@<agent> sudo /opt/adk/agent/test-pull-token.sh \
#     | ssh adk-admin@<test> sudo /opt/adk/agent/set-secret.sh gitea-pull-token
#
# Usage: sudo /opt/adk/agent/test-pull-token.sh [--config FILE]
#
# Scopes read:repository,read:package: test/deploy.sh fetches deploy/ of a repository and the
# TEST VM pulls images from the registry - only repositories that protect-repo.sh gave team
# readers. Older test-pull-* tokens are revoked once the new one exists (re-run = rotation).
# Exit codes: 0 = token written, 1 = failure, 2 = usage (also: stdout is a terminal).
# Tests (non-root): ADK_TEST_PASSWORD_FILE as in protect-repo.sh, ADK_GITEA_LOCK_DIR.
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

PULL_USER=test-pull
SCOPES="read:repository,read:package"

usage() { echo "usage: $0 [--config FILE] | ssh adk-admin@<test> sudo /opt/adk/agent/set-secret.sh gitea-pull-token" >&2; exit 2; }

CONFIG="$ROOT/kit.env"
while (($#)); do
  case "$1" in
    --config) (($# >= 2)) || usage; CONFIG="$2"; shift 2 ;;
    *) usage ;;
  esac
done
if [[ "$(id -u)" -ne 0 && -z "${ADK_TEST_PASSWORD_FILE:-}" ]]; then
  echo "ERROR: run as root (sudo $0)" >&2
  exit 2
fi
if [[ -t 1 ]]; then
  echo "ERROR: stdout is a terminal; the token must not be shown. Pipe it into set-secret.sh on the TEST VM:" >&2
  usage
fi
[[ -f "$CONFIG" ]] || { echo "ERROR: config file not found: $CONFIG" >&2; exit 2; }
"$ROOT/scripts/check-config.sh" "$CONFIG" > /dev/null || { "$ROOT/scripts/check-config.sh" "$CONFIG" >&2 || true; exit 1; }

_adk_gitea_lock
row="$(gitea_cli admin user list < /dev/null | awk -v u="$PULL_USER" 'NR > 1 && tolower($2) == u {print $5}')"
[[ -n "$row" ]] || adk_die "Gitea user $PULL_USER does not exist; run setup.sh (gitea-init.sh) first"
[[ "$row" == false ]] || adk_die "Gitea user $PULL_USER is a site admin; remove that right first"

name="$PULL_USER-$(date -u +%Y%m%dT%H%M%SZ)"
new="$(gitea_cli admin user generate-access-token --username "$PULL_USER" --token-name "$name" \
  --scopes "$SCOPES" --raw < /dev/null | tail -n 1)"
[[ "$new" =~ ^[0-9a-f]{40}$ ]] || { new=""; adk_die "could not create a token for $PULL_USER"; }
uid="$(sql "SELECT id FROM \"user\" WHERE lower_name = '$PULL_USER';")"
[[ "$uid" =~ ^[0-9]+$ ]] || adk_die "no id for $PULL_USER"
sql "DELETE FROM access_token WHERE uid = $uid AND name LIKE '$PULL_USER-%' AND name <> '$name';"
printf '%s\n' "$new"
new=""
echo "token $name of $PULL_USER created ($SCOPES), older $PULL_USER tokens revoked" >&2
