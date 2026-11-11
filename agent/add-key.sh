#!/usr/bin/env bash
# Add an SSH public key to a user's root-owned key file on the agent VPS.
#
# Usage: sudo /opt/adk/agent/add-key.sh <adk-admin|hermes> < key.pub
#        ssh adk-admin@vps sudo /opt/adk/agent/add-key.sh hermes < key.pub
#        sudo /opt/adk/agent/add-key.sh <adk-admin|hermes> FILE
#
# The key comes from stdin. A FILE is accepted only if it is a regular file owned by root
# or the invoking admin ($SUDO_UID), not group/other-writable, in a directory with the same
# properties: a key staged in /tmp could have been planted or swapped by the agent.
# Keys live in /etc/ssh/authorized_keys/<user> (root:root 0644, see sshd-adk.conf), so the
# agent cannot add keys of its own. A key that is already present (same type + key
# material, comment ignored) is not added twice. Runs under a lock on the keys directory.
# ADK_AUTH_KEYS_DIR overrides the directory for tests only.
# Exit codes: 0 = present now, 1 = invalid key, 2 = usage / permissions.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib/keyfile.sh
source "$HERE/lib/keyfile.sh"

usage() {
  echo "usage: $0 <adk-admin|hermes> < key.pub   (or: $0 <user> FILE, see the header)" >&2
  exit 2
}

(($# == 1 || $# == 2)) || usage
user="$1"
adk_check_key_user "$user" || exit 2
adk_check_keys_dir || exit 2

rc=0
if (($# == 2)); then
  src="$2"
  if [[ -L "$src" || ! -f "$src" ]]; then
    echo "ERROR: not a regular file: $src (pipe the key on stdin instead)" >&2
    exit 2
  fi
  # Check the opened file, then read from the same descriptor (no swap in between).
  exec 8< "$src"
  adk_check_key_source "$src" /proc/$$/fd/8 || exit 2
  key="$(adk_read_pubkey - <&8)" || rc=$?
  exec 8<&-
else
  if [[ -t 0 ]]; then usage; fi
  key="$(adk_read_pubkey -)" || rc=$?
fi
((rc == 0)) || exit "$rc"
fp="$(adk_pubkey_fingerprint "$key")"
material="$(adk_pubkey_material "$key")"

adk_lock_keys_dir || exit 2
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

{
  if [[ -s "$file" ]]; then
    cat "$file"
    # A last line without newline would merge with the new key into one broken line.
    [[ -z "$(tail -c1 "$file")" ]] || echo
  fi
  printf '%s\n' "$key"
} | adk_write_keys_file "$file"
echo "added for $user: $fp"
