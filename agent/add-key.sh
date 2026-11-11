#!/usr/bin/env bash
# Add an SSH public key to a user's root-owned key file on the agent VPS.
#
# Usage: sudo /opt/adk/agent/add-key.sh <adk-admin|hermes> <pubkey-file>
#
# Keys live in /etc/ssh/authorized_keys/<user> (root:root 0644, see sshd-adk.conf), so the
# agent cannot add keys of its own. A key that is already present (same type + key
# material, comment ignored) is not added twice.
# ADK_AUTH_KEYS_DIR overrides the directory for tests only.
# Exit codes: 0 = present now, 1 = invalid key, 2 = usage / permissions.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib/keyfile.sh
source "$HERE/lib/keyfile.sh"

(($# == 2)) || { echo "usage: $0 <adk-admin|hermes> <pubkey-file>" >&2; exit 2; }
user="$1"
adk_check_key_user "$user" || exit 2
adk_check_keys_dir || exit 2

rc=0
key="$(adk_read_pubkey "$2")" || rc=$?
((rc == 0)) || exit "$rc"
fp="$(adk_pubkey_fingerprint "$key")"
material="$(adk_pubkey_material "$key")"

file="$(adk_keys_file "$user")"
if [[ -f "$file" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$(adk_pubkey_material "$line")" == "$material" ]]; then
      echo "already present for $user: $fp"
      exit 0
    fi
  done < "$file"
fi

{ [[ -f "$file" ]] && cat "$file"; printf '%s\n' "$key"; } | adk_write_keys_file "$file"
echo "added for $user: $fp"
