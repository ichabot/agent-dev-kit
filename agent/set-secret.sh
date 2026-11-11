#!/usr/bin/env bash
# Store a secret for the agent VPS services in /opt/adk/secrets/<name> (root, 0600).
#
# Usage: ssh adk-admin@vps sudo /opt/adk/agent/set-secret.sh <name> < token-file
#        sudo /opt/adk/agent/set-secret.sh <name>        (prompts, input not shown)
#
# Names (whitelist):
#   dns-api-token   API token of the DNS provider for ACME DNS-01 (Caddy, ACME_MODE=dns01)
#
# The value is read from stdin only (never from argv, which every user can see in ps),
# must be one line without whitespace or single quotes, and is never printed. Run setup.sh
# afterwards: it recreates Caddy so the new token is used. ADK_SECRETS_DIR overrides the directory for tests (non-root only).
# Exit codes: 0 = stored / unchanged, 1 = invalid value, 2 = usage / permissions.
set -euo pipefail
export LC_ALL=C
umask 077

ALLOWED=(dns-api-token)
MAX_LEN=4096

usage() {
  echo "usage: $0 <${ALLOWED[*]}> < file   (the value is read from stdin only)" >&2
  exit 2
}
die() { echo "ERROR: $*" >&2; exit "${2:-1}"; }

(($# == 1)) || usage
name="$1"
ok=false
for a in "${ALLOWED[@]}"; do [[ "$name" == "$a" ]] && ok=true; done
[[ "$ok" == true ]] || { echo "ERROR: unknown secret name (allowed: ${ALLOWED[*]})" >&2; usage; }

dir=/opt/adk/secrets
if [[ "$(id -u)" -ne 0 ]]; then
  [[ -n "${ADK_SECRETS_DIR:-}" ]] || die "run as root (sudo $0 $name)" 2
  dir="$ADK_SECRETS_DIR"
fi

# --- read the value -------------------------------------------------------------------
if [[ -t 0 ]]; then
  printf 'Value for %s (not shown): ' "$name" >&2
  IFS= read -rs value || true
  echo >&2
  rest=""
else
  IFS= read -r value || true
  rest="$(cat)"
fi
value="${value%$'\r'}"
[[ -z "${rest//[$'\r\n']/}" ]] || die "the value must be a single line"
[[ -n "$value" ]] || die "empty value"
((${#value} <= MAX_LEN)) || die "value longer than $MAX_LEN characters"
[[ "$value" =~ ^[[:graph:]]+$ ]] || die "the value must not contain whitespace or control characters"
[[ "$value" != *"'"* ]] || die "the value must not contain a single quote (it is written single-quoted for Caddy)"

# --- store it -------------------------------------------------------------------------
[[ ! -L "$dir" ]] || die "$dir is a symlink; not following it" 2
if [[ ! -d "$dir" ]]; then
  mkdir -m 0700 "$dir" || die "cannot create $dir" 2
fi
if [[ "$(stat -c %a "$dir")" != 700 ]]; then
  chmod 0700 "$dir"
fi
target="$dir/$name"
[[ ! -L "$target" ]] || die "$target is a symlink; not following it" 2
[[ ! -e "$target" || -f "$target" ]] || die "$target is not a regular file" 2

if [[ -f "$target" ]] && [[ "$(cat "$target")" == "$value" ]]; then
  [[ "$(stat -c %a "$target")" == 600 ]] || chmod 0600 "$target"
  echo "ok: secret $name unchanged"
  exit 0
fi
tmp="$(mktemp "$dir/.set-secret.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
printf '%s' "$value" > "$tmp"
chmod 0600 "$tmp"
mv -f "$tmp" "$target"
trap - EXIT
echo "changed: secret $name stored in $target (mode 0600); run setup.sh to apply it (recreates caddy)"
