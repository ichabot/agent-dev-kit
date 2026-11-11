#!/usr/bin/env bash
# From the installer's machine: copy the kit to a freshly provisioned agent VPS and run
# agent/setup.sh there.
#
# Usage: agent/bootstrap.sh [--user USER] [--identity FILE] [--config FILE] <host>
#
#   --user USER      admin login (default: adk-admin)
#   --identity FILE  SSH private key (default: ssh's own choice / agent)
#   --config FILE    kit.env to copy (default: kit.env in the repository root)
#
# Steps: validate kit.env, wait for SSH, wait for cloud-init, rsync scripts/ agent/ kit.env
# docs/hermes-tuning.md to /opt/adk (root-owned, kit.env 0600), sudo /opt/adk/agent/setup.sh.
# Exit codes: 0 = done, 1 = failure, 2 = usage.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
REMOTE_DIR=/opt/adk
WAIT_SECONDS="${ADK_SSH_WAIT:-600}"

usage() { echo "usage: $0 [--user USER] [--identity FILE] [--config FILE] <host>" >&2; exit 2; }
die() { echo "ERROR: $*" >&2; exit 1; }

USER_NAME=adk-admin CONFIG="$ROOT/kit.env" HOST=""
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30)
while (($#)); do
  case "$1" in
    --user) (($# >= 2)) || usage; USER_NAME="$2"; shift 2 ;;
    --identity) (($# >= 2)) || usage; [[ -f "$2" ]] || usage; SSH_OPTS+=(-o IdentitiesOnly=yes -i "$2"); shift 2 ;;
    --config) (($# >= 2)) || usage; CONFIG="$2"; shift 2 ;;
    -*) usage ;;
    *) [[ -z "$HOST" ]] || usage; HOST="$1"; shift ;;
  esac
done
[[ -n "$HOST" ]] || usage
[[ "$USER_NAME" =~ ^[a-z_][a-z0-9_-]*$ ]] || usage
[[ "$HOST" =~ ^[A-Za-z0-9.:-]+$ ]] || usage
[[ -f "$CONFIG" ]] || { echo "ERROR: config file not found: $CONFIG" >&2; exit 2; }

"$ROOT/scripts/check-config.sh" "$CONFIG" >/dev/null || {
  "$ROOT/scripts/check-config.sh" "$CONFIG" || true
  die "fix $CONFIG first"
}

TARGET="$USER_NAME@$HOST"
[[ "$HOST" == *:* ]] && TARGET="$USER_NAME@[$HOST]"   # IPv6 literal for rsync
SSH_TARGET="$USER_NAME@$HOST"
# shellcheck disable=SC2029  # arguments are meant to expand locally
remote() { ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "$@"; }

echo "== waiting for SSH on $HOST (up to ${WAIT_SECONDS}s)"
deadline=$((SECONDS + WAIT_SECONDS))
until remote true 2>/dev/null; do
  ((SECONDS < deadline)) || die "no SSH login as $USER_NAME on $HOST"
  sleep 5
done

echo "== waiting for cloud-init"
rc=0
remote cloud-init status --wait >/dev/null || rc=$?
case "$rc" in
  0) echo "cloud-init: done" ;;
  2) echo "WARNING: cloud-init finished with recoverable errors (see /var/log/cloud-init.log)" ;;
  *) remote cloud-init status --long || true; die "cloud-init failed" ;;
esac

echo "== copying the kit to $REMOTE_DIR"
remote "sudo install -d -m 0755 -o root -g root $REMOTE_DIR"
RSYNC_SSH="ssh $(printf '%q ' "${SSH_OPTS[@]}")"
(
  cd "$ROOT"
  rsync -rlp --delete --relative --chown=root:root --chmod=go-w \
    --exclude '__pycache__' -e "$RSYNC_SSH" --rsync-path="sudo rsync" \
    ./scripts ./agent ./docs/hermes-tuning.md "$TARGET:$REMOTE_DIR/"
)
rsync -p --chown=root:root --chmod=F0600 -e "$RSYNC_SSH" --rsync-path="sudo rsync" \
  "$CONFIG" "$TARGET:$REMOTE_DIR/kit.env"

echo "== running setup.sh"
remote "sudo $REMOTE_DIR/agent/setup.sh"

echo
echo "Done. Add the employee's key for Hermes Desktop:"
echo "  scp key.pub $SSH_TARGET:/tmp/ && ssh $SSH_TARGET sudo $REMOTE_DIR/agent/add-key.sh hermes /tmp/key.pub"
