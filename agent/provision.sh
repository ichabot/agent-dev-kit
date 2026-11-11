#!/usr/bin/env bash
# Create (or bring in line) the agent VPS in the customer's Hetzner Cloud project.
#
# Usage: agent/provision.sh --pubkey FILE [--admin-source CIDR]... [--config FILE] [--dry-run]
#
#   --pubkey FILE        installer's SSH public key (uploaded as adk-<customer>-installer,
#                        installed for adk-admin by cloud-init)
#   --admin-source CIDR  extra SSH source for the installer during setup (repeatable).
#                        Re-run without it at handover: the firewall rules are replaced.
#   --config FILE        kit.env (default: kit.env in the repository root)
#   --dry-run            print the planned API requests, send nothing, need no token
#
# Idempotent by name: ssh key adk-<customer>-installer, firewall and server
# adk-<customer>-agent. Objects with these names that lack the label
# managed-by=agent-dev-kit are never modified. The firewall is attached at create time,
# so the server is never reachable unfiltered.
#
# Token: HCLOUD_TOKEN_FILE (default ~/.config/hcloud-token), mode 0600, read here and handed
# to curl through a header file (-H @file) - never on the command line, never printed.
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
POLL_MAX=200

usage() { echo "usage: $0 --pubkey FILE [--admin-source CIDR]... [--config FILE] [--dry-run]" >&2; exit 2; }
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
[[ -n "$PUBKEY" ]] || usage
[[ -f "$CONFIG" ]] || { echo "ERROR: config file not found: $CONFIG" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
hc() { python3 -I "$HERE/lib/hcloud.py" "$@"; }

# --- local inputs (validated before anything is sent) ---------------------
rc=0
key="$(adk_read_pubkey "$PUBKEY")" || rc=$?
((rc == 0)) || exit "$rc"
md5="$(ssh-keygen -l -E md5 -f - <<< "$key" | cut -d' ' -f2)"
md5="${md5#MD5:}"

"$HERE/firewall-rules.sh" --config "$CONFIG" "${ADMIN_ARGS[@]}" > "$WORK/rules.json"
"$HERE/render-cloud-init.sh" --pubkey "$PUBKEY" > "$WORK/user-data"
load_config "$CONFIG"
customer="${CFG[CUSTOMER_NAME]}"
KEY_NAME="adk-$customer-installer"
FW_NAME="adk-$customer-agent"
SRV_NAME="adk-$customer-agent"

hc sshkey "$KEY_NAME" "$key" "$customer" > "$WORK/sshkey.json"
hc firewall "$FW_NAME" "$customer" "$WORK/rules.json" > "$WORK/firewall.json"
hc set-rules "$WORK/rules.json" > "$WORK/set-rules.json"

if [[ "$DRY_RUN" == true ]]; then
  hc server "$SRV_NAME" "${CFG[AGENT_TYPE]}" "${CFG[HCLOUD_LOCATION]}" "$customer" \
    "<id of ssh key $KEY_NAME>" "<id of firewall $FW_NAME>" "$WORK/user-data" > "$WORK/server.json"
  echo "# DRY RUN: nothing is sent to $API"
  echo "# 1. look up (objects without label managed-by=agent-dev-kit abort the run)"
  echo "GET /ssh_keys?name=$KEY_NAME"
  echo "GET /ssh_keys?fingerprint=$md5"
  echo "GET /firewalls?name=$FW_NAME"
  echo "GET /servers?name=$SRV_NAME"
  echo "# 2. ssh key: uploaded unless found by name (same key) or fingerprint"
  echo "POST /ssh_keys $(cat "$WORK/sshkey.json")"
  echo "# 3. firewall: created, or an existing one gets these rules (set_rules)"
  echo "POST /firewalls $(cat "$WORK/firewall.json")"
  echo "# 4. server: created with the firewall attached (an existing one only gets the firewall applied)"
  echo "POST /servers $(hc truncate "$WORK/server.json")"
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
mode="$(stat -c %a "$TOKEN_FILE")"
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
  local args=(-sS --proto "=https" --max-time 60 -o "$WORK/resp" -w '%{http_code}' -X "$1" -H "@$WORK/auth")
  if (($# >= 3)); then args+=(-H "Content-Type: application/json" --data-binary "@$3"); fi
  HTTP="$(curl "${args[@]}" "$API$2")" || die "$1 $2: network error"
}
api_ok() {
  api "$@"
  if [[ "$HTTP" != 2* ]]; then
    die "$1 $2: HTTP $HTTP: $(hc get "$WORK/resp" error.message)"
  fi
}
field() { hc get "$WORK/resp" "$1"; }

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

require_managed() {   # KIND NAME LABEL_VALUE
  [[ "$3" == "agent-dev-kit" ]] || die "$1 $2 exists but has no label managed-by=agent-dev-kit; not touching it"
}

# Phase 1: look everything up and check ownership before changing anything.
api_ok GET "/ssh_keys?name=$KEY_NAME"
key_id="$(field ssh_keys.0.id)" key_note=""
if [[ -n "$key_id" ]]; then
  [[ "$(field ssh_keys.0.fingerprint)" == "$md5" ]] \
    || die "ssh key $KEY_NAME exists with a different key; delete it in the Hetzner console or pass the matching --pubkey"
  key_note="exists"
else
  api_ok GET "/ssh_keys?fingerprint=$md5"
  key_id="$(field ssh_keys.0.id)"
  [[ -n "$key_id" ]] && key_note="same key already uploaded as '$(field ssh_keys.0.name)', reused"
fi

api_ok GET "/firewalls?name=$FW_NAME"
fw_id="$(field firewalls.0.id)"
[[ -z "$fw_id" ]] || require_managed firewall "$FW_NAME" "$(field 'firewalls.0.labels.managed-by')"

api_ok GET "/servers?name=$SRV_NAME"
srv_id="$(field servers.0.id)" srv_firewalls=""
if [[ -n "$srv_id" ]]; then
  require_managed server "$SRV_NAME" "$(field 'servers.0.labels.managed-by')"
  srv_firewalls="$(field servers.0.public_net.firewalls)"
fi

# Phase 2: create what is missing, bring the rest in line.
if [[ -n "$key_id" ]]; then
  echo "ssh key $KEY_NAME: $key_note (id $key_id)"
else
  api_ok POST /ssh_keys "$WORK/sshkey.json"
  key_id="$(field ssh_key.id)"
  echo "ssh key $KEY_NAME: created (id $key_id)"
fi

if [[ -n "$fw_id" ]]; then
  api_ok POST "/firewalls/$fw_id/actions/set_rules" "$WORK/set-rules.json"
  for id in $(python3 -I -c 'import json, sys; print(" ".join(str(a["id"]) for a in json.loads(sys.argv[1] or "[]")))' "$(field actions)"); do
    wait_action "$id"
  done
  echo "firewall $FW_NAME: rules replaced (id $fw_id)"
else
  api_ok POST /firewalls "$WORK/firewall.json"
  fw_id="$(field firewall.id)"
  echo "firewall $FW_NAME: created (id $fw_id)"
fi

if [[ -n "$srv_id" ]]; then
  if ! python3 -I -c 'import json, sys; sys.exit(0 if any(str(f["id"]) == sys.argv[2] for f in json.loads(sys.argv[1] or "[]")) else 1)' \
      "$srv_firewalls" "$fw_id"; then
    hc apply-to "$srv_id" > "$WORK/apply.json"
    api_ok POST "/firewalls/$fw_id/actions/apply_to_resources" "$WORK/apply.json"
    for id in $(python3 -I -c 'import json, sys; print(" ".join(str(a["id"]) for a in json.loads(sys.argv[1] or "[]")))' "$(field actions)"); do
      wait_action "$id"
    done
    echo "server $SRV_NAME: firewall applied"
  fi
  echo "server $SRV_NAME: exists (id $srv_id)"
else
  hc server "$SRV_NAME" "${CFG[AGENT_TYPE]}" "${CFG[HCLOUD_LOCATION]}" "$customer" \
    "$key_id" "$fw_id" "$WORK/user-data" > "$WORK/server.json"
  api_ok POST /servers "$WORK/server.json"
  srv_id="$(field server.id)"
  wait_action "$(field action.id)"
  echo "server $SRV_NAME: created (id $srv_id)"
fi

# backups
api_ok GET "/servers/$srv_id"
if [[ -z "$(field server.backup_window)" ]]; then
  api_ok POST "/servers/$srv_id/actions/enable_backup"
  wait_action "$(field action.id)"
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
echo "Next: agent/bootstrap.sh ${ipv4:-$ipv6} --identity <private key of $PUBKEY>"
