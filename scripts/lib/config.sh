#!/usr/bin/env bash
# Shared loader for agent-dev-kit configuration files.
# Every script reads kit.env through load_config; the file is never sourced.
#
# After load_config FILE:
#   CFG[KEY]      value (trimmed, inline comment removed)
#   CFG_LINE[KEY] line number of the key
#   CFG_ERRORS    array of "WHAT: message" parse errors
# shellcheck disable=SC2034  # variables are consumed by the caller

ADK_KEYS=(
  CUSTOMER_NAME CUSTOMER_IPS
  VPN_PORT VPN_PROTO
  GITEA_DOMAIN TEST_DOMAIN ACME_EMAIL ACME_MODE DNS_PROVIDER
  HCLOUD_LOCATION AGENT_TYPE TEST_TYPE
  BACKUP_TARGET
)

adk_is_key() {
  local k
  for k in "${ADK_KEYS[@]}"; do [[ "$k" == "$1" ]] && return 0; done
  return 1
}

adk_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

load_config() {
  local file="$1" line stripped key value lineno=0
  declare -gA CFG=() CFG_LINE=()
  CFG_ERRORS=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    line="${line%$'\r'}"                       # tolerate CRLF (edited on Windows)
    stripped="$(adk_trim "$line")"
    [[ -z "$stripped" || "$stripped" == \#* ]] && continue
    if [[ "$stripped" =~ ^export[[:space:]] ]]; then
      CFG_ERRORS+=("line $lineno: drop 'export', plain KEY=VALUE only")
      continue
    fi
    if [[ ! "$stripped" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
      CFG_ERRORS+=("line $lineno: not a KEY=VALUE line")
      continue
    fi
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    # Inline comments start at whitespace followed by '#'.
    value="$(printf '%s' "$value" | sed -E 's/[[:space:]]+#.*$//')"
    value="$(adk_trim "$value")"
    if ! adk_is_key "$key"; then
      CFG_ERRORS+=("$key: unknown key (typo?)")
      continue
    fi
    if [[ -n "${CFG_LINE[$key]+set}" ]]; then
      CFG_ERRORS+=("$key: duplicate (lines ${CFG_LINE[$key]} and $lineno)")
      continue
    fi
    if [[ "$value" == *[\"\'\`\$\\]* ]]; then
      CFG_ERRORS+=("$key: quotes, \$, \` and \\ are not supported")
    fi
    CFG[$key]="$value"
    CFG_LINE[$key]="$lineno"
  done < "$file"
}
