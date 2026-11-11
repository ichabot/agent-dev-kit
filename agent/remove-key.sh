#!/usr/bin/env bash
# Remove an SSH public key (by fingerprint) from a user's root-owned key file.
#
# Usage: sudo /opt/adk/agent/remove-key.sh [--force] <adk-admin|hermes> <SHA256:fingerprint>
#
# The fingerprint is the second field of `ssh-keygen -l -f key.pub`. Removing the last
# adk-admin key would lock every administrator out and needs --force.
# ADK_AUTH_KEYS_DIR overrides the directory for tests only.
# Exit codes: 0 = removed, 1 = not found / refused, 2 = usage / permissions.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib/keyfile.sh
source "$HERE/lib/keyfile.sh"

usage() { echo "usage: $0 [--force] <adk-admin|hermes> <SHA256:fingerprint>" >&2; exit 2; }

force=false
if [[ "${1:-}" == "--force" ]]; then force=true; shift; fi
(($# == 2)) || usage
user="$1" fp="$2"
adk_check_key_user "$user" || exit 2
[[ "$fp" =~ $ADK_FINGERPRINT_RE ]] || { echo "ERROR: not a SHA256 fingerprint: $fp" >&2; exit 2; }
adk_check_keys_dir || exit 2

file="$(adk_keys_file "$user")"
[[ -f "$file" ]] || { echo "ERROR: no keys for $user" >&2; exit 1; }

kept=() removed=0
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ -n "$line" && "$line" != \#* ]] && [[ "$(adk_pubkey_fingerprint "$line" || true)" == "$fp" ]]; then
    removed=$((removed + 1))
    continue
  fi
  kept+=("$line")
done < "$file"

if ((removed == 0)); then
  echo "ERROR: $fp not found for $user" >&2
  exit 1
fi

remaining=0
for line in "${kept[@]}"; do
  [[ -n "$line" && "$line" != \#* ]] && remaining=$((remaining + 1))
done
if [[ "$user" == "adk-admin" ]] && ((remaining == 0)) && [[ "$force" != true ]]; then
  echo "ERROR: $fp is the last adk-admin key; removing it locks out all admins (use --force)" >&2
  exit 1
fi

if ((${#kept[@]})); then printf '%s\n' "${kept[@]}"; fi | adk_write_keys_file "$file"
echo "removed from $user: $fp"
