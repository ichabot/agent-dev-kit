#!/usr/bin/env bash
# Helpers for the root-owned SSH key files (/etc/ssh/authorized_keys/<user>).
# Sourced by add-key.sh and remove-key.sh.

_ADK_KEYFILE_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Installed layout and repository layout are the same: <root>/agent/lib, <root>/scripts/lib
# shellcheck source-path=SCRIPTDIR/../.. source=scripts/lib/pubkey.sh
source "$_ADK_KEYFILE_HERE/../../scripts/lib/pubkey.sh"

# Users whose keys this kit manages (must match AllowUsers in sshd-adk.conf).
ADK_KEY_USERS=(adk-admin hermes)

adk_check_key_user() {
  local u
  for u in "${ADK_KEY_USERS[@]}"; do [[ "$u" == "$1" ]] && return 0; done
  echo "ERROR: user must be one of: ${ADK_KEY_USERS[*]} (got '$1')" >&2
  return 1
}

adk_keys_dir() { printf '%s\n' "${ADK_AUTH_KEYS_DIR:-/etc/ssh/authorized_keys}"; }
adk_keys_file() { printf '%s/%s\n' "$(adk_keys_dir)" "$1"; }

# The real directory is root-owned: only root may change it. The override is for tests.
adk_check_keys_dir() {
  if [[ -z "${ADK_AUTH_KEYS_DIR:-}" && "$(id -u)" -ne 0 ]]; then
    echo "ERROR: run as root (sudo)" >&2
    return 1
  fi
  if [[ ! -d "$(adk_keys_dir)" ]]; then
    echo "ERROR: missing directory $(adk_keys_dir)" >&2
    return 1
  fi
}

# adk_write_keys_file FILE: replace FILE atomically with stdin, mode 0644 (root:root as root)
adk_write_keys_file() {
  local file="$1" tmp
  tmp="$(mktemp "$file.XXXXXX")"
  cat > "$tmp"
  chmod 0644 "$tmp"
  if [[ "$(id -u)" -eq 0 ]]; then chown root:root "$tmp"; fi
  mv -f "$tmp" "$file"
}

# adk_lock_keys_dir: exclusive lock on the keys directory (fd 9) for the rest of the script,
# so concurrent add/remove runs cannot lose each other's changes.
adk_lock_keys_dir() {
  exec 9< "$(adk_keys_dir)"
  if ! flock -w 30 9; then
    echo "ERROR: $(adk_keys_dir) is locked by another add-key/remove-key run" >&2
    return 1
  fi
}

# adk_check_key_source PATH OPENED: a key file passed as argument must belong to root, the
# invoking admin ($SUDO_UID) or the caller, must not be group/other-writable, and neither
# may its directory. OPENED is the already opened file (/proc/<pid>/fd/<n>).
adk_check_key_source() {
  local path="$1" opened="$2" dir f_uid f_mode d_uid d_mode
  dir="$(dirname "$path")"
  read -r f_uid f_mode < <(stat -L -c '%u %a' "$opened")
  read -r d_uid d_mode < <(stat -L -c '%u %a' "$dir")
  if ! _adk_trusted_uid "$f_uid" || (((8#$f_mode & 8#022) != 0)); then
    echo "ERROR: $path must be owned by root or you and not group/other-writable; pipe the key on stdin instead" >&2
    return 1
  fi
  if ! _adk_trusted_uid "$d_uid" || (((8#$d_mode & 8#022) != 0)); then
    echo "ERROR: $path is in a group/world-writable or foreign directory ($dir); pipe the key on stdin instead" >&2
    return 1
  fi
}

_adk_trusted_uid() {
  [[ "$1" == 0 || "$1" == "$(id -u)" || ( -n "${SUDO_UID:-}" && "$1" == "$SUDO_UID" ) ]]
}
