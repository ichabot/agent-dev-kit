#!/usr/bin/env bash
# Print the Hetzner Cloud firewall rules (JSON array for the API "rules" field) of the
# agent VPS or the TEST VM. Pure function of kit.env and the options: no network, no state.
#
# Usage: agent/firewall-rules.sh [--config FILE] [--role agent|test] [--admin-source CIDR]...
#                                [--extra-https-source CIDR]... [--extra-ssh-source CIDR]...
#
#   --config FILE              kit.env to read (default: kit.env in the repository root)
#   --role agent|test          which server (default: agent)
#   --admin-source CIDR        extra SSH source for the installer during setup (repeatable);
#                              same rules as CUSTOMER_IPS. Re-run provision.sh without it at
#                              handover to remove the rule.
#   --extra-https-source CIDR  agent only: HTTPS (Gitea, registry) from the TEST VM, so it can
#                              fetch deploy files and pull images (repeatable)
#   --extra-ssh-source CIDR    test only: SSH from the agent VPS (CI deploy job, repeatable)
#
# Inbound only; outbound stays open (LLM API, packages, ACME). Everything is limited to
# CUSTOMER_IPS (or the extra sources above) except tcp/80 with ACME_MODE=http01. Every extra
# source passes the CUSTOMER_IPS rules (public, minimum prefix).
#   agent: tcp 22, tcp 443, VPN, ICMP from CUSTOMER_IPS
#   test:  tcp 22, tcp 443, ICMP from CUSTOMER_IPS (no VPN on the TEST VM)
# Exit codes: 0 = rules printed, 1 = invalid configuration, 2 = usage.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=../scripts/lib/config.sh
source "$ROOT/scripts/lib/config.sh"

usage() {
  echo "usage: $0 [--config FILE] [--role agent|test] [--admin-source CIDR]... [--extra-https-source CIDR]... [--extra-ssh-source CIDR]..." >&2
  exit 2
}

CONFIG="$ROOT/kit.env" ROLE=agent
ADMIN_SOURCES=() HTTPS_SOURCES=() SSH_SOURCES=()
while (($#)); do
  case "$1" in
    --config) (($# >= 2)) || usage; CONFIG="$2"; shift 2 ;;
    --role) (($# >= 2)) || usage; ROLE="$2"; shift 2 ;;
    --admin-source) (($# >= 2)) || usage; ADMIN_SOURCES+=("$2"); shift 2 ;;
    --extra-https-source) (($# >= 2)) || usage; HTTPS_SOURCES+=("$2"); shift 2 ;;
    --extra-ssh-source) (($# >= 2)) || usage; SSH_SOURCES+=("$2"); shift 2 ;;
    *) usage ;;
  esac
done
case "$ROLE" in
  agent) ((${#SSH_SOURCES[@]} == 0)) || { echo "ERROR: --extra-ssh-source is for --role test" >&2; usage; } ;;
  test) ((${#HTTPS_SOURCES[@]} == 0)) || { echo "ERROR: --extra-https-source is for --role agent" >&2; usage; } ;;
  *) usage ;;
esac

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

if [[ "$ROLE" == agent && "${CFG[VPN_PROTO]}" == "tcp" ]]; then
  case "$((10#${CFG[VPN_PORT]}))" in
    22|80|443) echo "ERROR: VPN_PORT: tcp/${CFG[VPN_PORT]} collides with SSH/HTTP/HTTPS" >&2; exit 1 ;;
  esac
fi

CIDR="$ROOT/scripts/lib/cidr.py"
if ! customer="$(python3 -I "$CIDR" normalize "${CFG[CUSTOMER_IPS]}")"; then
  echo "ERROR: CUSTOMER_IPS is invalid" >&2
  exit 1
fi

# sources OPTION CIDR...: the normalized networks of an option (one per line); invalid
# entries end the script with exit code 1 (same rules as CUSTOMER_IPS)
sources() {
  local option="$1" joined out
  shift
  (($#)) || return 0
  joined="$(IFS=,; printf '%s' "$*")"
  if ! out="$(python3 -I "$CIDR" normalize "$joined" 2>&1)"; then
    printf 'ERROR: %s %s\n' "$option" "${out//$'\n'/; }" >&2
    return 1
  fi
  printf '%s' "$out"
}
admin="$(sources --admin-source "${ADMIN_SOURCES[@]}")" || exit 1
https="$(sources --extra-https-source "${HTTPS_SOURCES[@]}")" || exit 1
ssh="$(sources --extra-ssh-source "${SSH_SOURCES[@]}")" || exit 1

python3 -I - "$ROLE" "$customer" "$admin" "$https" "$ssh" "${CFG[VPN_PROTO]}" "$((10#${CFG[VPN_PORT]}))" "${CFG[ACME_MODE]}" <<'PY'
import json, sys

role, customer, admin, https, ssh, vpn_proto, vpn_port, acme_mode = sys.argv[1:9]
customer, admin, https, ssh = customer.split(), admin.split(), https.split(), ssh.split()

def rule(proto, port, sources, description):
    r = {"direction": "in", "protocol": proto}
    if port is not None:
        r["port"] = str(port)
    r["source_ips"] = sources
    r["description"] = description
    return r

if role == "agent":
    rules = [
        rule("tcp", 22, customer, "SSH (admin, Hermes Desktop) from customer networks"),
        rule("tcp", 443, customer, "Gitea HTTPS from customer networks"),
        rule(vpn_proto, vpn_port, customer, "VPN from customer networks"),
        rule("icmp", None, customer, "ICMP (ping, path MTU) from customer networks"),
    ]
    if https:
        rules.append(rule("tcp", 443, https,
                          "Gitea HTTPS from the TEST VM (deploy files, registry pulls)"))
else:
    rules = [
        rule("tcp", 22, customer, "SSH (admin) from customer networks"),
        rule("tcp", 443, customer, "TEST apps HTTPS from customer networks"),
        rule("icmp", None, customer, "ICMP (ping, path MTU) from customer networks"),
    ]
    if ssh:
        rules.append(rule("tcp", 22, ssh,
                          "SSH from the agent VPS: CI deploy key, forced command deploy-gate.sh only"))
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
