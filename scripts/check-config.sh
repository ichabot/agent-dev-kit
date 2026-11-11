#!/usr/bin/env bash
# Validate an agent-dev-kit configuration file (default: kit.env).
#
# Usage: scripts/check-config.sh [FILE]
#        scripts/check-config.sh --list-keys
#
# Exit codes: 0 = valid, 1 = validation errors (stdout), 2 = usage / file problems (stderr).
# The file is parsed by scripts/lib/config.sh and never sourced, so values cannot execute code.
set -euo pipefail
export LC_ALL=C   # character classes must not match non-ASCII letters

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib/config.sh
source "$HERE/lib/config.sh"

# Keys that may stay empty (further rules below can still require them).
OPTIONAL=(DNS_PROVIDER BACKUP_TARGET)
# Narrowest allowed firewall source prefixes: a typo must not open the VPS to the world.
MIN_PREFIX_V4=24
MIN_PREFIX_V6=48

usage() { echo "usage: $0 [FILE] | --list-keys" >&2; exit 2; }

case "$#" in
  0) FILE="kit.env" ;;
  1)
    case "$1" in
      --list-keys) printf '%s\n' "${ADK_KEYS[@]}"; exit 0 ;;
      -*) usage ;;
      *) FILE="$1" ;;
    esac
    ;;
  *) usage ;;
esac

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required (IP validation)" >&2
  exit 2
fi
if [[ ! -f "$FILE" ]]; then
  echo "ERROR: config file not found: $FILE" >&2
  exit 2
fi
if [[ ! -r "$FILE" ]]; then
  echo "ERROR: cannot read $FILE" >&2
  exit 2
fi

load_config "$FILE"
ERRORS=("${CFG_ERRORS[@]}")
err() { ERRORS+=("$1: $2"); }

is_optional() {
  local k
  for k in "${OPTIONAL[@]}"; do [[ "$k" == "$1" ]] && return 0; done
  return 1
}
val() { printf '%s' "${CFG[$1]:-}"; }

# --- presence ------------------------------------------------------------
for k in "${ADK_KEYS[@]}"; do
  if [[ -z "${CFG[$k]+set}" ]]; then
    err "$k" "missing"
  elif [[ -z "${CFG[$k]}" ]] && ! is_optional "$k"; then
    err "$k" "empty"
  fi
done

# --- format checks (only for non-empty values) ---------------------------
DOMAIN_RE='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+([a-z]{2,63}|xn--[a-z0-9-]{1,59})$'

check_domain() {
  local k="$1" v="$2"
  if [[ "$v" =~ [A-Z] ]]; then
    err "$k" "use lowercase: $v"
  elif (( ${#v} > 253 )) || [[ ! "$v" =~ $DOMAIN_RE ]]; then
    err "$k" "not a valid domain name: $v"
  fi
}

v="$(val CUSTOMER_NAME)"
if [[ -n "$v" && ! "$v" =~ ^[a-z][a-z0-9-]{0,29}[a-z0-9]$ ]]; then
  err CUSTOMER_NAME "use 2-31 chars: a-z, 0-9, '-' (letter first, no '-' at the end)"
fi

v="$(val CUSTOMER_IPS)"
if [[ -n "$v" ]]; then
  # One isolated interpreter call (-I: no cwd on sys.path, no user site, no PYTHON* env).
  # Prints one "network: reason" line per rejected entry, or "EMPTY".
  if ! ip_errors="$(python3 -I - "$v" "$MIN_PREFIX_V4" "$MIN_PREFIX_V6" <<'PY'
import ipaddress, sys

raw, min4, min6 = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
# Documentation ranges are unroutable and used by the tests; everything else must be global.
doc = [ipaddress.ip_network(n) for n in
       ("192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24", "2001:db8::/32")]
entries = [e.strip() for e in raw.split(",") if e.strip()]
if not entries:
    print("EMPTY")
for e in entries:
    try:
        net = ipaddress.ip_network(e, strict=True)
    except ValueError as ex:
        print(f"{e}: {'host bits set (prefix typo?)' if 'host bits' in str(ex) else 'not a network'}")
        continue
    if net.version == 6 and net.network_address.ipv4_mapped is not None:
        print(f"{e}: IPv4-mapped IPv6 is not allowed")
        continue
    if net.prefixlen < (min4 if net.version == 4 else min6):
        print(f"{e}: too broad (minimum /{min4 if net.version == 4 else min6})")
        continue
    if any(net.subnet_of(d) for d in doc if d.version == net.version):
        continue
    if not net.is_global or net.is_multicast:
        print(f"{e}: not a public address")
PY
  )"; then
    err CUSTOMER_IPS "validation failed (python3 error)"
  fi
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$line" == "EMPTY" ]]; then
      err CUSTOMER_IPS "no network given"
    else
      err CUSTOMER_IPS "$line"
    fi
  done <<< "$ip_errors"
fi

v="$(val VPN_PORT)"
if [[ -n "$v" ]] && { [[ ! "$v" =~ ^[0-9]{1,5}$ ]] || (( 10#$v < 1 || 10#$v > 65535 )); }; then
  err VPN_PORT "must be 1-65535"
fi

v="$(val VPN_PROTO)"
if [[ -n "$v" && "$v" != "udp" && "$v" != "tcp" ]]; then
  err VPN_PROTO "must be udp or tcp"
fi

for k in GITEA_DOMAIN TEST_DOMAIN; do
  v="$(val "$k")"
  [[ -n "$v" ]] && check_domain "$k" "$v"
done

v="$(val ACME_EMAIL)"
if [[ -n "$v" && ! "$v" =~ ^[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+\.)+[A-Za-z]{2,63}$ ]]; then
  err ACME_EMAIL "not a valid e-mail address"
fi

case "$(val ACME_MODE)" in
  ""|http01) ;;
  dns01)
    if [[ -z "$(val DNS_PROVIDER)" ]]; then
      err DNS_PROVIDER "required for ACME_MODE=dns01"
    fi
    ;;
  *) err ACME_MODE "must be dns01 or http01" ;;
esac

v="$(val DNS_PROVIDER)"
if [[ -n "$v" && ! "$v" =~ ^[a-z0-9_]+$ ]]; then
  err DNS_PROVIDER "caddy-dns module name, a-z 0-9 _"
fi

for k in HCLOUD_LOCATION AGENT_TYPE TEST_TYPE; do
  v="$(val "$k")"
  if [[ -n "$v" && ! "$v" =~ ^[a-z0-9-]+$ ]]; then
    err "$k" "lowercase a-z 0-9 '-' only"
  fi
done

v="$(val BACKUP_TARGET)"
if [[ -n "$v" && ! "$v" =~ ^sftp://[A-Za-z0-9._-]+@[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._/-]*)?$ ]]; then
  err BACKUP_TARGET "sftp://user@host[:port]/path, no password (key auth only)"
fi

# --- result --------------------------------------------------------------
if ((${#ERRORS[@]})); then
  printf 'ERROR: %s\n' "${ERRORS[@]}"
  echo "${#ERRORS[@]} problem(s) in $FILE"
  exit 1
fi
echo "OK: $FILE"
