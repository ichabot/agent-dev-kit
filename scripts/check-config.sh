#!/usr/bin/env bash
# Validate an agent-dev-kit configuration file (default: kit.env).
#
# Usage: scripts/check-config.sh [FILE]
#        scripts/check-config.sh --list-keys
#
# Exit codes: 0 = valid, 1 = validation errors, 2 = usage / file problems.
# The file is parsed line by line and never sourced, so values cannot execute code.
set -euo pipefail

KEYS=(
  CUSTOMER_NAME CUSTOMER_IPS
  VPN_PORT VPN_PROTO
  GITEA_DOMAIN TEST_DOMAIN ACME_EMAIL ACME_MODE DNS_PROVIDER
  HCLOUD_LOCATION AGENT_TYPE TEST_TYPE
  BACKUP_TARGET
)
# Keys that may stay empty (further rules below can still require them).
OPTIONAL=(DNS_PROVIDER BACKUP_TARGET)

if [[ "${1:-}" == "--list-keys" ]]; then
  printf '%s\n' "${KEYS[@]}"
  exit 0
fi

FILE="${1:-kit.env}"
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required (IP validation)" >&2
  exit 2
fi
if [[ ! -f "$FILE" ]]; then
  echo "ERROR: config file not found: $FILE" >&2
  exit 2
fi

declare -A CFG=()
ERRORS=()
err() { ERRORS+=("$1: $2"); }

is_known() {
  local k
  for k in "${KEYS[@]}"; do [[ "$k" == "$1" ]] && return 0; done
  return 1
}
is_optional() {
  local k
  for k in "${OPTIONAL[@]}"; do [[ "$k" == "$1" ]] && return 0; done
  return 1
}
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# --- parse ---------------------------------------------------------------
lineno=0
while IFS= read -r line || [[ -n "$line" ]]; do
  lineno=$((lineno + 1))
  stripped="$(trim "$line")"
  [[ -z "$stripped" || "$stripped" == \#* ]] && continue
  if [[ ! "$stripped" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
    err "line $lineno" "not a KEY=VALUE line"
    continue
  fi
  key="${BASH_REMATCH[1]}"
  value="${BASH_REMATCH[2]}"
  # Inline comments start at whitespace followed by '#'.
  value="$(printf '%s' "$value" | sed -E 's/[[:space:]]+#.*$//')"
  value="$(trim "$value")"
  if ! is_known "$key"; then
    err "$key" "unknown key (typo?)"
    continue
  fi
  CFG[$key]="$value"
done < "$FILE"

# --- presence ------------------------------------------------------------
for k in "${KEYS[@]}"; do
  if [[ -z "${CFG[$k]+set}" ]]; then
    err "$k" "missing"
  elif [[ -z "${CFG[$k]}" ]] && ! is_optional "$k"; then
    err "$k" "empty"
  fi
done

val() { printf '%s' "${CFG[$1]:-}"; }

# --- format checks (only for non-empty values) ---------------------------
DOMAIN_RE='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'

v="$(val CUSTOMER_NAME)"
if [[ -n "$v" && ! "$v" =~ ^[a-z][a-z0-9-]{1,30}$ ]]; then
  err CUSTOMER_NAME "use 2-31 chars: a-z, 0-9, '-' (starting with a letter)"
fi

v="$(val CUSTOMER_IPS)"
if [[ -n "$v" ]]; then
  IFS=',' read -ra nets <<< "$v"
  for n in "${nets[@]}"; do
    n="$(trim "$n")"
    [[ -z "$n" ]] && continue
    if ! python3 - "$n" <<'PY' 2>/dev/null; then
import ipaddress, sys
net = ipaddress.ip_network(sys.argv[1], strict=False)
sys.exit(1 if net.prefixlen == 0 else 0)
PY
      err CUSTOMER_IPS "invalid or any-address network: $n"
    fi
  done
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
  if [[ -n "$v" && ! "$v" =~ $DOMAIN_RE ]]; then
    err "$k" "not a valid domain name: $v"
  fi
done

v="$(val ACME_EMAIL)"
if [[ -n "$v" && ! "$v" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[a-z]{2,63}$ ]]; then
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
    err "$k" "a-z 0-9 '-' only"
  fi
done

v="$(val BACKUP_TARGET)"
if [[ -n "$v" && ! "$v" =~ ^sftp://[^[:space:]]+$ ]]; then
  err BACKUP_TARGET "must start with sftp://"
fi

# --- result --------------------------------------------------------------
if ((${#ERRORS[@]})); then
  printf 'ERROR: %s\n' "${ERRORS[@]}"
  echo "${#ERRORS[@]} problem(s) in $FILE"
  exit 1
fi
echo "OK: $FILE"
