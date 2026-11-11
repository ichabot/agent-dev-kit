#!/usr/bin/env bash
# CI deploy key for the TEST VM. Runs as root on the agent VPS; the key pair is made HERE and
# the private key never leaves this server except into Gitea's Actions secret store:
#
#   ssh adk-admin@<test> cat /etc/ssh/ssh_host_ed25519_key.pub \
#     | ssh adk-admin@<agent> sudo /opt/adk/agent/test-deploy-key.sh --host <test address> \
#     | ssh adk-admin@<test> sudo /opt/adk/agent/add-key.sh --forced-command deploy
#
# Usage: sudo /opt/adk/agent/test-deploy-key.sh --host HOST [--config FILE] < host-keys.pub
#
#   --host HOST  address the CI job connects to (IP address or DNS name of the TEST VM)
#   stdin        the TEST VM's SSH host public key(s), one "type base64 [comment]" per line
#                (pinned for the job: no trust on first use)
#
# Result:
#   /opt/adk/secrets/test-deploy-key(.pub)  ed25519 key pair (root 0600), created once
#   Gitea organization CUSTOMER_NAME (temporary admin token, lib/gitea-admin.sh):
#     Actions secret   TEST_DEPLOY_KEY          the private key; sent to the API on stdin (curl
#                                               config), never in an argv or on stdout
#     Actions variable TEST_DEPLOY_HOST         HOST
#     Actions variable TEST_DEPLOY_KNOWN_HOSTS  "HOST type base64" per host key
#   stdout: the PUBLIC key only (for add-key.sh --forced-command deploy on the TEST VM)
# Every workflow of every branch of the organization can read the secret: the key may only start
# "deploy <project> <ref>" on TEST (docs/test-vm.md, known limit). Rotation: delete
# /opt/adk/secrets/test-deploy-key*, re-run, remove the old key on TEST (remove-key.sh deploy).
# Exit codes: 0 = done, 1 = failure, 2 = usage.
# Tests (non-root): ADK_TEST_PASSWORD_FILE, ADK_GITEA_LOCK_DIR, ADK_TEST_SECRETS_DIR.
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

ADMIN_SCOPES="write:organization,read:user"
SECRET=TEST_DEPLOY_KEY

usage() { echo "usage: $0 --host HOST [--config FILE] < test-host-keys.pub" >&2; exit 2; }

CONFIG="$ROOT/kit.env" HOST=""
while (($#)); do
  case "$1" in
    --host) (($# >= 2)) || usage; HOST="$2"; shift 2 ;;
    --config) (($# >= 2)) || usage; CONFIG="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$HOST" ]] || usage
if ! python3 -I -c 'import ipaddress, sys; ipaddress.ip_address(sys.argv[1])' "$HOST" 2> /dev/null \
    && [[ ! "$HOST" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; then
  echo "ERROR: --host must be an IP address or a lowercase DNS name" >&2
  exit 2
fi
SECRETS_DIR=/opt/adk/secrets
if [[ "$(id -u)" -ne 0 ]]; then
  [[ -n "${ADK_TEST_PASSWORD_FILE:-}" && -n "${ADK_TEST_SECRETS_DIR:-}" ]] || { echo "ERROR: run as root (sudo $0)" >&2; exit 2; }
  ADK_GITEA_PASSWORD_FILE="$ADK_TEST_PASSWORD_FILE"
  SECRETS_DIR="$ADK_TEST_SECRETS_DIR"
fi
[[ -f "$CONFIG" ]] || { echo "ERROR: config file not found: $CONFIG" >&2; exit 2; }
if ! check_out="$("$ROOT/scripts/check-config.sh" "$CONFIG")"; then
  printf '%s\n' "$check_out" >&2
  exit 1
fi
load_config "$CONFIG"
ORG="${CFG[CUSTOMER_NAME]}"
ADMIN="${CFG[GITEA_ADMIN_USER]}"

# --- host keys of the TEST VM (stdin) -----------------------------------------------------
[[ ! -t 0 ]] || { echo "ERROR: pipe the TEST VM's host public key(s) into stdin" >&2; usage; }
known=""
n=0
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%$'\r'}"
  [[ -n "$line" && "$line" != \#* ]] || continue
  if [[ ! "$line" =~ ^(ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|ssh-rsa)\ (AAAA[A-Za-z0-9+/]+={0,3})(\ [[:print:]]*)?$ ]] \
      || ! ssh-keygen -l -f - <<< "$line" > /dev/null 2>&1; then
    adk_die "stdin line $((n + 1)) is not an SSH host public key"
  fi
  known+="$HOST ${BASH_REMATCH[1]} ${BASH_REMATCH[3]}"$'\n'
  n=$((n + 1))
  ((n <= 5)) || adk_die "more than 5 host keys on stdin"
done < <(head -c 65536)
((n > 0)) || adk_die "no host key on stdin (ssh adk-admin@<test> cat /etc/ssh/ssh_host_ed25519_key.pub | ...)"
known="${known%$'\n'}"

# --- key pair (created once, root only) ---------------------------------------------------
key="$SECRETS_DIR/test-deploy-key"
[[ ! -L "$SECRETS_DIR" && -d "$SECRETS_DIR" ]] || adk_die "$SECRETS_DIR is missing or a symlink (run setup.sh first)"
[[ ! -L "$key" && ! -L "$key.pub" ]] || adk_die "$key is a symlink"
if [[ -f "$key" ]]; then
  pub="$(ssh-keygen -y -f "$key" 2> /dev/null)" || adk_die "cannot read $key"
  echo "ok: deploy key $key" >&2
else
  rm -f "$key.pub"
  (umask 077 && ssh-keygen -q -t ed25519 -N '' -C "adk-ci-deploy@$ORG" -f "$key" < /dev/null)
  pub="$(ssh-keygen -y -f "$key")"
  echo "changed: deploy key $key created" >&2
fi
chmod 0600 "$key"
printf '%s adk-ci-deploy@%s\n' "$pub" "$ORG" > "$key.pub"
chmod 0644 "$key.pub"

# --- Gitea: organization secret and variables ------------------------------------------
trap 'adk_gitea_admin_end || exit 1' EXIT
adk_gitea_admin_begin "$ADMIN" "$ADMIN_SCOPES"

marker="$key.uploaded"
want="$(cat "$key" <(printf '%s' "$ORG") | sha256sum | cut -d' ' -f1)"
api GET "/orgs/$ORG/actions/secrets?limit=50"
[[ "$API_CODE" == 200 ]] || adk_die "GET /orgs/$ORG/actions/secrets: HTTP $API_CODE"
present="$(json "any(s.get('name') == '$SECRET' for s in d)")"
if [[ "$present" == True && -f "$marker" && "$(cat "$marker")" == "$want" ]]; then
  echo "ok: Actions secret $SECRET of $ORG" >&2
else
  # curl config on stdin: data = "<JSON with \ and " escaped>" (python reads the key file;
  # process substitution, not a pipe: api_conf must set API_CODE in this shell)
  api_conf PUT "/orgs/$ORG/actions/secrets/$SECRET" < <(python3 -I -c '
import json, sys
body = json.dumps({"data": open(sys.argv[1]).read()})
print("data = \"" + body.replace("\\", "\\\\").replace("\"", "\\\"") + "\"")' "$key")
  [[ "$API_CODE" == 201 || "$API_CODE" == 204 ]] || adk_die "cannot store the Actions secret $SECRET (HTTP $API_CODE): $API_BODY"
  (umask 077 && printf '%s' "$want" > "$marker")
  echo "changed: Actions secret $SECRET of $ORG (private key, readable by every workflow of $ORG)" >&2
fi

# set_variable NAME VALUE: organization Actions variable (not secret)
set_variable() {
  local name="$1" value="$2" body
  body="$(python3 -I -c 'import json, sys; print(json.dumps({"name": sys.argv[1], "value": sys.argv[2]}))' "$name" "$value")"
  api GET "/orgs/$ORG/actions/variables/$name"
  case "$API_CODE" in
    200)
      if [[ "$(json 'd.get("data")')" == "$value" ]]; then
        echo "ok: Actions variable $name of $ORG" >&2
        return 0
      fi
      api PUT "/orgs/$ORG/actions/variables/$name" "$body"
      [[ "$API_CODE" == 201 || "$API_CODE" == 204 ]] || adk_die "cannot update the Actions variable $name (HTTP $API_CODE): $API_BODY"
      ;;
    404)
      api POST "/orgs/$ORG/actions/variables/$name" "$body"
      [[ "$API_CODE" == 201 || "$API_CODE" == 204 ]] || adk_die "cannot create the Actions variable $name (HTTP $API_CODE): $API_BODY"
      ;;
    *) adk_die "GET Actions variable $name: HTTP $API_CODE" ;;
  esac
  echo "changed: Actions variable $name of $ORG" >&2
}
set_variable TEST_DEPLOY_HOST "$HOST"
set_variable TEST_DEPLOY_KNOWN_HOSTS "$known"

echo "Public key (add on the TEST VM: add-key.sh --forced-command deploy):" >&2
cat "$key.pub"
