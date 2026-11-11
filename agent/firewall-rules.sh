#!/usr/bin/env bash
# Print the Hetzner Cloud firewall rules (JSON array for the API "rules" field) of the
# agent VPS. Pure function of kit.env: no network access, no state.
#
# Usage: agent/firewall-rules.sh [--config FILE] [--admin-source CIDR]...
#
#   --config FILE        kit.env to read (default: kit.env in the repository root)
#   --admin-source CIDR  extra SSH source for the installer during setup (repeatable);
#                        same rules as CUSTOMER_IPS. Re-run provision.sh without it at
#                        handover to remove the rule.
#
# Inbound only; outbound stays open (LLM API, packages, ACME). Everything is limited to
# CUSTOMER_IPS except tcp/80 with ACME_MODE=http01.
# Exit codes: 0 = rules printed, 1 = invalid configuration, 2 = usage.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=../scripts/lib/config.sh
source "$ROOT/scripts/lib/config.sh"

usage() { echo "usage: $0 [--config FILE] [--admin-source CIDR]..." >&2; exit 2; }

CONFIG="$ROOT/kit.env"
ADMIN_SOURCES=()
while (($#)); do
  case "$1" in
    --config) (($# >= 2)) || usage; CONFIG="$2"; shift 2 ;;
    --admin-source) (($# >= 2)) || usage; ADMIN_SOURCES+=("$2"); shift 2 ;;
    *) usage ;;
  esac
done

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: config file not found: $CONFIG" >&2
  exit 2
fi

# Full validation first: the rules must never be built from a half-valid file.
if ! out="$("$ROOT/scripts/check-config.sh" "$CONFIG")"; then
  printf '%s\n' "$out" >&2
  exit 1
fi
load_config "$CONFIG"

if [[ "${CFG[VPN_PROTO]}" == "tcp" ]]; then
  case "$((10#${CFG[VPN_PORT]}))" in
    22|80|443) echo "ERROR: VPN_PORT: tcp/${CFG[VPN_PORT]} collides with SSH/HTTP/HTTPS" >&2; exit 1 ;;
  esac
fi

CIDR="$ROOT/scripts/lib/cidr.py"
if ! customer="$(python3 -I "$CIDR" normalize "${CFG[CUSTOMER_IPS]}")"; then
  echo "ERROR: CUSTOMER_IPS is invalid" >&2
  exit 1
fi
admin=""
if ((${#ADMIN_SOURCES[@]})); then
  joined="$(IFS=,; printf '%s' "${ADMIN_SOURCES[*]}")"
  if ! admin="$(python3 -I "$CIDR" normalize "$joined" 2>&1)"; then
    printf 'ERROR: --admin-source %s\n' "${admin//$'\n'/; }" >&2
    exit 1
  fi
fi

python3 -I - "$customer" "$admin" "${CFG[VPN_PROTO]}" "$((10#${CFG[VPN_PORT]}))" "${CFG[ACME_MODE]}" <<'PY'
import json, sys

customer, admin, vpn_proto, vpn_port, acme_mode = sys.argv[1:6]
customer = customer.split()
admin = admin.split()

def rule(proto, port, sources, description):
    r = {"direction": "in", "protocol": proto}
    if port is not None:
        r["port"] = str(port)
    r["source_ips"] = sources
    r["description"] = description
    return r

rules = [
    rule("tcp", 22, customer, "SSH (admin, Hermes Desktop) from customer networks"),
    rule("tcp", 443, customer, "Gitea HTTPS from customer networks"),
    rule(vpn_proto, vpn_port, customer, "VPN from customer networks"),
    rule("icmp", None, customer, "ICMP (ping, path MTU) from customer networks"),
]
if acme_mode == "http01":
    rules.append(rule("tcp", 80, ["0.0.0.0/0", "::/0"],
                      "ACME HTTP-01 challenge + redirect to HTTPS only; world-open because "
                      "Let's Encrypt validates from unknown addresses (ACME_MODE=http01)"))
if admin:
    rules.append(rule("tcp", 22, admin,
                      "Installer SSH during setup - remove at handover "
                      "(re-run provision.sh without --admin-source)"))
print(json.dumps(rules, indent=2))
PY
