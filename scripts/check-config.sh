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
OPTIONAL=(DNS_PROVIDER BACKUP_TARGET BACKUP_AGE_RECIPIENT)
# Firewall source rules (public only, minimum prefix) live in lib/cidr.py.

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
WARNINGS=()
err() { ERRORS+=("$1: $2"); }
warn() { WARNINGS+=("$1"); }

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

# Gitea user and organization names share one namespace; these are taken by Gitea itself or
# by the kit's own accounts (agent/gitea-init.sh).
GITEA_RESERVED=(admin root agent-bot prod-pull ghost gitea-actions api assets explore org repo user
  users v2 login new notifications issues pulls milestones raw search avatars attachments
  avatar captcha commits debug error metrics repo-avatars ssh_info help install)
is_reserved() {
  local r
  for r in "${GITEA_RESERVED[@]}"; do [[ "$r" == "$1" ]] && return 0; done
  # Gitea also reserves these suffixes (routes for keys, feeds, avatars)
  [[ "$1" =~ \.(keys|gpg|rss|atom|png)$ ]]
}
if [[ -n "$v" ]] && is_reserved "$v"; then
  err CUSTOMER_NAME "'$v' is reserved in Gitea or by the kit (it becomes the Gitea organization)"
fi

v="$(val GITEA_ADMIN_USER)"
if [[ -n "$v" ]]; then
  if [[ ! "$v" =~ ^[a-z0-9]([a-z0-9._-]{0,37}[a-z0-9])?$ || ${#v} -lt 2 || "$v" =~ [._-]{2} ]]; then
    err GITEA_ADMIN_USER "use 2-39 chars: a-z, 0-9, '.', '_', '-' (letter or digit first and last, no two symbols in a row)"
  elif is_reserved "$v"; then
    err GITEA_ADMIN_USER "'$v' is reserved in Gitea or by the kit"
  elif [[ "$v" == "$(val CUSTOMER_NAME)" ]]; then
    err GITEA_ADMIN_USER "must differ from CUSTOMER_NAME (that name is the Gitea organization)"
  fi
fi

v="$(val CUSTOMER_IPS)"
if [[ -n "$v" ]]; then
  # Shared rules (scripts/lib/cidr.py), isolated interpreter (-I: no cwd or script dir on
  # sys.path, no user site, no PYTHON* env). One "network: reason" line per rejected entry.
  if ! ip_errors="$(python3 -I "$HERE/lib/cidr.py" check "$v")"; then
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

for k in ACME_EMAIL GITEA_ADMIN_EMAIL; do
  v="$(val "$k")"
  if [[ -n "$v" && ! "$v" =~ ^[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+\.)+[A-Za-z]{2,63}$ ]]; then
    err "$k" "not a valid e-mail address"
  fi
done

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
if [[ "$v" == hetzner && "$(val ACME_MODE)" == dns01 ]]; then
  warn "DNS_PROVIDER=hetzner: the token is a Hetzner Cloud API token with read/write on its whole project. Keep the DNS zone in a separate Hetzner project that contains nothing else (or delegate _acme-challenge via CNAME to a dedicated zone); never use the token of the agent VPS project (docs/agent-vps.md)."
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
v="$(val BACKUP_AGE_RECIPIENT)"
if [[ -n "$v" && ! "$v" =~ ^age1[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{58}$ ]]; then
  err BACKUP_AGE_RECIPIENT "must be an age public key (age1 followed by 58 lowercase bech32 characters; created with age-keygen)"
fi
if [[ -n "$(val BACKUP_TARGET)" && -z "$v" ]]; then
  err BACKUP_AGE_RECIPIENT "required with BACKUP_TARGET: off-site copies are encrypted to this age public key"
fi

# --- result --------------------------------------------------------------
if ((${#WARNINGS[@]})); then
  printf 'WARNING: %s\n' "${WARNINGS[@]}"
fi
if ((${#ERRORS[@]})); then
  printf 'ERROR: %s\n' "${ERRORS[@]}"
  echo "${#ERRORS[@]} problem(s) in $FILE"
  exit 1
fi
echo "OK: $FILE"
