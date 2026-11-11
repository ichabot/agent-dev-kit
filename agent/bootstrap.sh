#!/usr/bin/env bash
# From the installer's machine: copy the kit to a freshly provisioned agent VPS (or TEST VM)
# and run agent/setup.sh (test/setup.sh) there.
#
# Usage: agent/bootstrap.sh [--role agent|test] [--user USER] [--identity FILE] [--config FILE] <host>
#
#   --role agent|test  agent (default): copies scripts/ agent/ docs/hermes-tuning.md, runs
#                    agent/setup.sh; test: copies scripts/ agent/ test/, runs test/setup.sh
#   --user USER      admin login (default: adk-admin)
#   --identity FILE  SSH private key (default: ssh's own choice / agent)
#   --config FILE    kit.env to copy (default: kit.env in the repository root)
#
# Steps: validate kit.env, check the work tree, wait for SSH, wait for cloud-init, rsync the
# git-tracked files of scripts/ agent/ docs/hermes-tuning.md plus kit.env to /opt/adk
# (root-owned, kit.env 0600), sudo /opt/adk/agent/setup.sh.
# Only git-tracked files are copied; untracked or ignored files under scripts/ or agent/
# (a stray token, a *.key) abort the run instead of landing world-readable in /opt/adk.
# Lab/test only: ADK_TLS_INTERNAL and ADK_RUNNER_ADD_HOST from the environment are passed on
# to setup.sh (see agent/render-services.sh); they are not kit.env keys.
# Exit codes: 0 = done, 1 = failure, 2 = usage.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
REMOTE_DIR=/opt/adk
WAIT_SECONDS="${ADK_SSH_WAIT:-600}"

usage() { echo "usage: $0 [--role agent|test] [--user USER] [--identity FILE] [--config FILE] <host>" >&2; exit 2; }
die() { echo "ERROR: $*" >&2; exit 1; }

USER_NAME=adk-admin CONFIG="$ROOT/kit.env" HOST="" ROLE=agent
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30)
while (($#)); do
  case "$1" in
    --role) (($# >= 2)) || usage; ROLE="$2"; shift 2 ;;
    --user) (($# >= 2)) || usage; USER_NAME="$2"; shift 2 ;;
    --identity)
      (($# >= 2)) || usage; [[ -f "$2" ]] || usage
      # absolute: rsync runs ssh from the staging directory
      SSH_OPTS+=(-o IdentitiesOnly=yes -i "$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"); shift 2 ;;
    --config) (($# >= 2)) || usage; CONFIG="$2"; shift 2 ;;
    -*) usage ;;
    *) [[ -z "$HOST" ]] || usage; HOST="$1"; shift ;;
  esac
done
[[ -n "$HOST" ]] || usage
[[ "$ROLE" == agent || "$ROLE" == test ]] || usage
[[ "$USER_NAME" =~ ^[a-z_][a-z0-9_-]*$ ]] || usage
[[ "$HOST" =~ ^[A-Za-z0-9.:-]+$ ]] || usage
[[ -f "$CONFIG" ]] || { echo "ERROR: config file not found: $CONFIG" >&2; exit 2; }
SETUP_ENV=""
if [[ -n "${ADK_TLS_INTERNAL:-}" ]]; then
  [[ "$ADK_TLS_INTERNAL" == 1 ]] || { echo "ERROR: ADK_TLS_INTERNAL must be 1 or empty" >&2; exit 2; }
  SETUP_ENV+="ADK_TLS_INTERNAL=1 "
fi
if [[ -n "${ADK_RUNNER_ADD_HOST:-}" ]]; then
  [[ "$ROLE" == agent ]] || { echo "ERROR: ADK_RUNNER_ADD_HOST is for the agent VPS only" >&2; exit 2; }
  [[ "$ADK_RUNNER_ADD_HOST" =~ ^[0-9A-Fa-f.:]+$ ]] || { echo "ERROR: ADK_RUNNER_ADD_HOST must be an IP address" >&2; exit 2; }
  SETUP_ENV+="ADK_RUNNER_ADD_HOST=$ADK_RUNNER_ADD_HOST "
fi
for tool in ssh rsync python3 git tar; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required on this machine"
done

"$ROOT/scripts/check-config.sh" "$CONFIG" >/dev/null || {
  "$ROOT/scripts/check-config.sh" "$CONFIG" || true
  die "fix $CONFIG first"
}

# --- what is copied: git-tracked files only ---------------------------------
SYNC_PATHS=(scripts agent docs/hermes-tuning.md)
SETUP=agent/setup.sh
if [[ "$ROLE" == test ]]; then
  SYNC_PATHS=(scripts agent test)
  SETUP=test/setup.sh
fi
git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "$ROOT is not a git work tree; bootstrap copies only git-tracked files"
stray="$(git -C "$ROOT" status --porcelain --ignored --untracked-files=all -- "${SYNC_PATHS[@]}" \
  | grep -E '^(\?\?|!!) ' || true)"
if [[ -n "$stray" ]]; then
  printf '%s\n' "$stray" >&2
  die "untracked or ignored files in the copied directories (see above); move them out of the repository first"
fi
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir "$STAGE/kit"
git -C "$ROOT" ls-files -z -- "${SYNC_PATHS[@]}" \
  | (cd "$ROOT" && tar --null -T - -cf -) | tar -xf - -C "$STAGE/kit" \
  || die "cannot stage the tracked files (deleted but not committed?)"

TARGET="$USER_NAME@$HOST"
[[ "$HOST" == *:* ]] && TARGET="$USER_NAME@[$HOST]"   # IPv6 literal for rsync
SSH_TARGET="$USER_NAME@$HOST"
# shellcheck disable=SC2029  # arguments are meant to expand locally
remote() { ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "$@"; }

echo "== waiting for SSH on $HOST (up to ${WAIT_SECONDS}s)"
deadline=$((SECONDS + WAIT_SECONDS))
until remote true 2>"$STAGE/ssh.err"; do
  if grep -qE 'IDENTIFICATION HAS CHANGED|Host key verification failed' "$STAGE/ssh.err"; then
    cat "$STAGE/ssh.err" >&2
    die "the host key of $HOST differs from known_hosts (reused IP?). If that is expected: ssh-keygen -R $HOST, then re-run"
  fi
  if ((SECONDS >= deadline)); then
    echo "last ssh error:" >&2
    tail -n 5 "$STAGE/ssh.err" >&2
    die "no SSH login as $USER_NAME on $HOST"
  fi
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
# Fixed modes (dirs 0755, files 0644/0755) whatever the local umask; kit.env 0600.
remote "sudo install -d -m 0755 -o root -g root $REMOTE_DIR"
RSYNC_SSH="ssh $(printf '%q ' "${SSH_OPTS[@]}")"
(
  cd "$STAGE/kit"
  rsync -rlp --delete --relative --chown=root:root --chmod=D0755,Fu+rw,Fgo-w,Fa+r,Fa+X \
    -e "$RSYNC_SSH" --rsync-path="sudo rsync" \
    "${SYNC_PATHS[@]/#/./}" "$TARGET:$REMOTE_DIR/"
)
rsync -p --chown=root:root --chmod=F0600 -e "$RSYNC_SSH" --rsync-path="sudo rsync" \
  "$CONFIG" "$TARGET:$REMOTE_DIR/kit.env"

echo "== running $SETUP"
remote "sudo $SETUP_ENV$REMOTE_DIR/$SETUP"

echo
if [[ "$ROLE" == test ]]; then
  echo "Done. Next: CI deploy key and Gitea pull token from the agent VPS (docs/test-vm.md):"
  echo "  ssh $SSH_TARGET cat /etc/ssh/ssh_host_ed25519_key.pub | ssh adk-admin@<agent> sudo $REMOTE_DIR/agent/test-deploy-key.sh --host $HOST \\"
  echo "    | ssh $SSH_TARGET sudo $REMOTE_DIR/agent/add-key.sh --forced-command deploy"
  echo "  ssh adk-admin@<agent> sudo $REMOTE_DIR/agent/test-pull-token.sh | ssh $SSH_TARGET sudo $REMOTE_DIR/agent/set-secret.sh gitea-pull-token"
  exit 0
fi
echo "Done. Add the employee's key for Hermes Desktop (read from stdin, never staged on the VPS):"
echo "  ssh $SSH_TARGET sudo $REMOTE_DIR/agent/add-key.sh hermes < mitarbeiter.pub"
