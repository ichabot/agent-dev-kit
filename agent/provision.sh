#!/usr/bin/env bash
# Create (or bring in line) the agent VPS in the customer's Hetzner Cloud project.
#
# Usage: agent/provision.sh [--pubkey FILE] [--admin-source CIDR]... [--config FILE] [--dry-run]
#
#   --pubkey FILE        installer's SSH public key (uploaded as adk-<customer>-installer,
#                        installed for adk-admin by cloud-init). Needed only to create the
#                        server; with an existing server no ssh key is looked up or uploaded
#                        (handover: re-run without it after deleting the key object).
#   --admin-source CIDR  extra SSH source for the installer during setup (repeatable).
#                        Re-run without it at handover: the firewall rules are replaced.
#   --config FILE        kit.env (default: kit.env in the repository root)
#   --dry-run            print the planned API requests, send nothing, need no token
#
# Idempotent by name: ssh key adk-<customer>-installer, firewall and server
# adk-<customer>-agent. Objects with these names that lack the labels
# managed-by=agent-dev-kit and customer=<customer> are never modified. The firewall is
# attached at create time, so the server is never reachable unfiltered; a server with any
# other firewall attached is refused (Hetzner adds up the allow rules of all firewalls).
#
# Token: HCLOUD_TOKEN_FILE (default ~/.config/hcloud-token), owned by you, mode 0600, read
# here and handed to curl through a header file (-H @file) - never on the command line,
# never printed. curl runs with -q first, so a ~/.curlrc cannot add -v/--trace.
# Exit codes: 0 = done, 1 = invalid input / API error, 2 = usage / token file.
set -euo pipefail
export LC_ALL=C
umask 077

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=../scripts/lib/config.sh
source "$ROOT/scripts/lib/config.sh"
# shellcheck source-path=SCRIPTDIR source=../scripts/lib/pubkey.sh
source "$ROOT/scripts/lib/pubkey.sh"

API="https://api.hetzner.cloud/v1"
POLL_INTERVAL="${ADK_POLL_INTERVAL:-3}"
POLL_MAX="${ADK_POLL_MAX:-200}"

usage() { echo "usage: $0 [--pubkey FILE] [--admin-source CIDR]... [--config FILE] [--dry-run]" >&2; exit 2; }
die() { echo "ERROR: $*" >&2; exit 1; }

CONFIG="$ROOT/kit.env" PUBKEY="" DRY_RUN=false
ADMIN_ARGS=()
while (($#)); do
  case "$1" in
    --pubkey) (($# >= 2)) || usage; PUBKEY="$2"; shift 2 ;;
    --admin-source) (($# >= 2)) || usage; ADMIN_ARGS+=(--admin-source "$2"); shift 2 ;;
    --config) (($# >= 2)) || usage; CONFIG="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) usage ;;
  esac
done
[[ "$POLL_MAX" =~ ^[1-9][0-9]*$ ]] || usage
[[ -f "$CONFIG" ]] || { echo "ERROR: config file not found: $CONFIG" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
hc() { python3 -I "$HERE/lib/hcloud.py" "$@"; }

# --- local inputs (validated before anything is sent) ---------------------
"$HERE/firewall-rules.sh" --config "$CONFIG" "${ADMIN_ARGS[@]}" > "$WORK/rules.json"
load_config "$CONFIG"
customer="${CFG[CUSTOMER_NAME]}"
KEY_NAME="adk-$customer-installer"
FW_NAME="adk-$customer-agent"
SRV_NAME="adk-$customer-agent"

if [[ -n "$PUBKEY" ]]; then
  rc=0
  key="$(adk_read_pubkey "$PUBKEY")" || rc=$?
  ((rc == 0)) || exit "$rc"
  md5="$(ssh-keygen -l -E md5 -f - <<< "$key" | cut -d' ' -f2)"
  md5="${md5#MD5:}"
  "$HERE/render-cloud-init.sh" --pubkey "$PUBKEY" > "$WORK/user-data"
  hc sshkey "$KEY_NAME" "$key" "$customer" > "$WORK/sshkey.json"
fi
hc firewall "$FW_NAME" "$customer" "$WORK/rules.json" > "$WORK/firewall.json"
hc set-rules "$WORK/rules.json" > "$WORK/set-rules.json"

if [[ "$DRY_RUN" == true ]]; then
  echo "# DRY RUN: nothing is sent to $API"
  echo "# 1. look up (objects without labels managed-by=agent-dev-kit, customer=$customer abort"
  echo "#    the run, so does any other firewall attached to the server)"
  echo "GET /servers?name=$SRV_NAME"
  echo "GET /firewalls?name=$FW_NAME"
  if [[ -n "$PUBKEY" ]]; then
    echo "# 2. only if the server does not exist: ssh key, uploaded unless found by name"
    echo "#    (same key) or fingerprint"
    echo "GET /ssh_keys?name=$KEY_NAME"
    echo "GET /ssh_keys?fingerprint=$md5"
    echo "POST /ssh_keys $(cat "$WORK/sshkey.json")"
  else
    echo "# 2. no --pubkey: the server must exist; no ssh key is looked up or uploaded"
  fi
  echo "# 3. firewall: created, or an existing one gets these rules (set_rules)"
  echo "POST /firewalls $(cat "$WORK/firewall.json")"
  if [[ -n "$PUBKEY" ]]; then
    hc server "$SRV_NAME" "${CFG[AGENT_TYPE]}" "${CFG[HCLOUD_LOCATION]}" "$customer" \
      "<id of ssh key $KEY_NAME>" "<id of firewall $FW_NAME>" "$WORK/user-data" > "$WORK/server.json"
    echo "# 4. server: created with the firewall attached (an existing one only gets the firewall applied)"
    echo "POST /servers $(hc truncate "$WORK/server.json")"
  else
    echo "# 4. server: must exist; gets the firewall applied if it is missing"
  fi
  echo "# 5. backups: enabled unless already enabled"
  echo "POST /servers/<id>/actions/enable_backup"
  exit 0
fi

# --- token ----------------------------------------------------------------
TOKEN_FILE="${HCLOUD_TOKEN_FILE:-$HOME/.config/hcloud-token}"
if [[ ! -f "$TOKEN_FILE" ]]; then
  echo "ERROR: Hetzner Cloud token file not found: $TOKEN_FILE (set HCLOUD_TOKEN_FILE)" >&2
  exit 2
fi
if [[ "$(stat -L -c %u "$TOKEN_FILE")" != "$(id -u)" ]]; then
  echo "ERROR: $TOKEN_FILE is not owned by you; use your own token file (mode 0600)" >&2
  exit 2
fi
mode="$(stat -L -c %a "$TOKEN_FILE")"
if (( (8#$mode & 8#077) != 0 )); then
  echo "ERROR: $TOKEN_FILE has mode $mode; chmod 0600 it (token must be private)" >&2
  exit 2
fi
token="$(tr -d '[:space:]' < "$TOKEN_FILE")"
if [[ ! "$token" =~ ^[A-Za-z0-9]{32,128}$ ]]; then
  echo "ERROR: $TOKEN_FILE does not contain a plain API token" >&2
  exit 2
fi
printf 'Authorization: Bearer %s\n' "$token" > "$WORK/auth"   # printf is a builtin: no argv
unset token

# --- API ------------------------------------------------------------------
# api METHOD PATH [BODY_FILE]: response body in $WORK/resp, status in $HTTP
api() {
  # -q must come first: no ~/.curlrc (e.g. -v, --trace) may print the Authorization header.
  local args=(-q -sS --proto "=https" --max-time 60 -o "$WORK/resp" -w '%{http_code}' -X "$1" -H "@$WORK/auth")
  if (($# >= 3)); then args+=(-H "Content-Type: application/json" --data-binary "@$3"); fi
  HTTP="$(curl "${args[@]}" "$API$2")" || die "$1 $2: network error"
  hc check "$WORK/resp" || die "$1 $2: HTTP $HTTP: response is not JSON (proxy or API outage?)"
}
api_ok() {
  api "$@"
  if [[ "$HTTP" != 2* ]]; then
    die "$1 $2: HTTP $HTTP: $(hc get "$WORK/resp" error.message)"
  fi
}
field() { hc get "$WORK/resp" "$1"; }
# field_id PATH: a numeric id ("" if missing) - nothing else ever goes into a URL path
field_id() { hc id "$WORK/resp" "$1" || die "unexpected id in the API response ($1)"; }
action_ids() { hc ids "$WORK/resp" "$1" || die "unexpected action ids in the API response"; }

wait_action() {
  local id="$1" i status
  for ((i = 0; i < POLL_MAX; i++)); do
    api_ok GET "/actions/$id"
    status="$(field action.status)"
    case "$status" in
      success) return 0 ;;
      error) die "action $id failed: $(field action.error.message)" ;;
    esac
    sleep "$POLL_INTERVAL"
  done
  die "action $id did not finish"
}

require_managed() {   # KIND NAME OBJECT_PATH (in the last response)
  [[ "$(field "$3.labels.managed-by")" == "agent-dev-kit" ]] \
    || die "$1 $2 exists but has no label managed-by=agent-dev-kit; not touching it"
  [[ "$(field "$3.labels.customer")" == "$customer" ]] \
    || die "$1 $2 exists but is labelled for another customer (customer=$(field "$3.labels.customer")); not touching it"
}

# Phase 1: look everything up and check ownership before changing anything.
api_ok GET "/servers?name=$SRV_NAME"
srv_id="$(field_id servers.0.id)" srv_fw_ids=""
if [[ -n "$srv_id" ]]; then
  require_managed server "$SRV_NAME" servers.0
  srv_fw_ids="$(hc ids "$WORK/resp" servers.0.public_net.firewalls)" || die "unexpected firewall ids in the API response"
fi

api_ok GET "/firewalls?name=$FW_NAME"
fw_id="$(field_id firewalls.0.id)"
[[ -z "$fw_id" ]] || require_managed firewall "$FW_NAME" firewalls.0

foreign_fw=()
for id in $srv_fw_ids; do
  [[ "$id" == "$fw_id" ]] || foreign_fw+=("$id")
done
if ((${#foreign_fw[@]})); then
  die "server $SRV_NAME has other firewalls attached (id ${foreign_fw[*]}); Hetzner adds up the allow rules of all firewalls - detach them first"
fi

key_id="" key_note=""
if [[ -z "$srv_id" ]]; then
  [[ -n "$PUBKEY" ]] || die "server $SRV_NAME does not exist yet: --pubkey is required to create it"
  api_ok GET "/ssh_keys?name=$KEY_NAME"
  key_id="$(field_id ssh_keys.0.id)"
  if [[ -n "$key_id" ]]; then
    [[ "$(field ssh_keys.0.fingerprint)" == "$md5" ]] \
      || die "ssh key $KEY_NAME exists with a different key; delete it in the Hetzner console or pass the matching --pubkey"
    key_note="exists"
  else
    api_ok GET "/ssh_keys?fingerprint=$md5"
    key_id="$(field_id ssh_keys.0.id)"
    [[ -n "$key_id" ]] && key_note="same key already uploaded as '$(field ssh_keys.0.name)', reused"
  fi
fi

# Phase 2: create what is missing, bring the rest in line.
if [[ -n "$srv_id" ]]; then
  echo "ssh key: not needed (server exists)"
elif [[ -n "$key_id" ]]; then
  echo "ssh key $KEY_NAME: $key_note (id $key_id)"
else
  api_ok POST /ssh_keys "$WORK/sshkey.json"
  key_id="$(field_id ssh_key.id)"
  echo "ssh key $KEY_NAME: created (id $key_id)"
fi

if [[ -n "$fw_id" ]]; then
  api_ok POST "/firewalls/$fw_id/actions/set_rules" "$WORK/set-rules.json"
  for id in $(action_ids actions); do
    wait_action "$id"
  done
  echo "firewall $FW_NAME: rules replaced (id $fw_id)"
else
  api_ok POST /firewalls "$WORK/firewall.json"
  fw_id="$(field_id firewall.id)"
  echo "firewall $FW_NAME: created (id $fw_id)"
fi

if [[ -n "$srv_id" ]]; then
  if [[ " $srv_fw_ids " != *" $fw_id "* ]]; then
    hc apply-to "$srv_id" > "$WORK/apply.json"
    api_ok POST "/firewalls/$fw_id/actions/apply_to_resources" "$WORK/apply.json"
    for id in $(action_ids actions); do
      wait_action "$id"
    done
    echo "server $SRV_NAME: firewall applied"
  fi
  echo "server $SRV_NAME: exists (id $srv_id)"
else
  hc server "$SRV_NAME" "${CFG[AGENT_TYPE]}" "${CFG[HCLOUD_LOCATION]}" "$customer" \
    "$key_id" "$fw_id" "$WORK/user-data" > "$WORK/server.json"
  api_ok POST /servers "$WORK/server.json"
  srv_id="$(field_id server.id)"
  action_id="$(field_id action.id)"
  wait_action "$action_id"
  echo "server $SRV_NAME: created (id $srv_id)"
fi

# backups
api_ok GET "/servers/$srv_id"
if [[ -z "$(field server.backup_window)" ]]; then
  api_ok POST "/servers/$srv_id/actions/enable_backup"
  action_id="$(field_id action.id)"
  wait_action "$action_id"
  echo "backups: enabled"
  api_ok GET "/servers/$srv_id"
else
  echo "backups: already enabled"
fi

ipv4="$(field server.public_net.ipv4.ip)"
ipv6_net="$(field server.public_net.ipv6.ip)"
ipv6=""
[[ -n "$ipv6_net" ]] && ipv6="$(hc ipv6-host "$ipv6_net")"
echo
echo "IPv4: ${ipv4:-none}"
echo "IPv6: ${ipv6:-none}${ipv6_net:+ (network $ipv6_net)}"
echo
echo "Next: agent/bootstrap.sh --identity <private key${PUBKEY:+ of $PUBKEY}> ${ipv4:-$ipv6}"
