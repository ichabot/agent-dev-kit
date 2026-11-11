#!/usr/bin/env bash
# Remove an SSH public key (by fingerprint) from a user's root-owned key file.
#
# Usage: sudo /opt/adk/agent/remove-key.sh [--force] [--terminate] <adk-admin|hermes|deploy> <SHA256:fingerprint>
#
#   --force      allow removing the last adk-admin key (locks every administrator out)
#   --terminate  also end all sessions and tunnels of the user (loginctl terminate-user);
#                for hermes the lingering user manager (rootless Docker) keeps running or
#                is started again - audit it (printed below). For adk-admin this ends your
#                own session too.
#
# The fingerprint is the second field of `ssh-keygen -l -f key.pub`. A removed key cannot
# log in again, but open sessions stay up without --terminate. Runs under a lock on the
# keys directory. ADK_AUTH_KEYS_DIR overrides the directory for tests only.
# Exit codes: 0 = removed, 1 = not found / refused, 2 = usage / permissions.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib/keyfile.sh
source "$HERE/lib/keyfile.sh"

usage() { echo "usage: $0 [--force] [--terminate] <adk-admin|hermes|deploy> <SHA256:fingerprint>" >&2; exit 2; }

force=false terminate=false
while (($#)); do
  case "$1" in
    --force) force=true; shift ;;
    --terminate) terminate=true; shift ;;
    -*) usage ;;
    *) break ;;
  esac
done
(($# == 2)) || usage
user="$1" fp="$2"
adk_check_key_user "$user" || exit 2
[[ "$fp" =~ $ADK_FINGERPRINT_RE ]] || { echo "ERROR: not a SHA256 fingerprint: $fp" >&2; exit 2; }
adk_check_keys_dir || exit 2
adk_lock_keys_dir || exit 2

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
  [[ -n "$line" && "$line" != \#* ]] || continue
  adk_pubkey_fingerprint "$line" > /dev/null 2>&1 && remaining=$((remaining + 1))
done
if [[ "$user" == "adk-admin" ]] && ((remaining == 0)) && [[ "$force" != true ]]; then
  echo "ERROR: $fp is the last valid adk-admin key; removing it locks out all admins (use --force)" >&2
  exit 1
fi

if ((${#kept[@]})); then printf '%s\n' "${kept[@]}"; fi | adk_write_keys_file "$file"
echo "removed from $user: $fp"

if [[ "$terminate" == true ]]; then
  loginctl terminate-user "$user" 2>/dev/null || true   # no session: nothing to end
  echo "sessions and tunnels of $user terminated"
  if [[ "$user" == hermes && "$(loginctl show-user "$user" -p Linger --value 2>/dev/null)" == yes ]] \
      && uid="$(id -u "$user" 2>/dev/null)"; then
    systemctl start "user@$uid.service" || true
    echo "user services of $user running (linger: rootless Docker)"
  fi
fi
cat <<EOF
Check what the key holder may have left running as $user:
  sudo crontab -l -u $user
  sudo ls -la ~$user/.config/systemd/user/
  sudo -u $user XDG_RUNTIME_DIR=/run/user/\$(id -u $user) systemctl --user list-units --type=service
  sudo -u $user DOCKER_HOST=unix:///run/user/\$(id -u $user)/docker.sock docker ps -a
EOF
