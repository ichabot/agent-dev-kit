#!/usr/bin/env bash
# Forced command of user deploy on the TEST VM (sshd ForceCommand + key option command=).
# Runs as deploy. The only accepted request is
#
#   deploy <project> <ref>
#
# in $SSH_ORIGINAL_COMMAND, nothing else (no shell, no scp/sftp, no interactive login, no
# extra words, no newline): project = ^[a-z][a-z0-9-]{1,38}$, ref = a full 40-hex commit SHA
# or a tag v<major>.<minor>.<patch>[-<prerelease>]. Every request is logged (syslog tag
# adk-deploy-gate). An accepted request runs the root step through exactly one sudoers rule:
#
#   sudo -n /opt/adk/test/deploy.sh <project> <ref>
#
# deploy.sh validates both arguments again as root. Exit codes: 0 = deployed, 2 = request
# refused, otherwise the exit code of deploy.sh.
# Tests (non-root, not user deploy): ADK_TEST_BIN replaces the directory of sudo and logger.
set -euo pipefail
export LC_ALL=C
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077

BIN=/usr/bin
if [[ -n "${ADK_TEST_BIN:-}" && "$(id -u)" -ne 0 && "$(id -un)" != deploy ]]; then
  BIN="$ADK_TEST_BIN"
fi
MAX_LEN=200
PROJECT_RE='[a-z][a-z0-9-]{1,38}'
REF_RE='[0-9a-f]{40}|v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?'

log() { "$BIN/logger" -t adk-deploy-gate -- "$*" 2>/dev/null || true; }

# shown: the request as printable, length-limited text (never raw control characters)
shown() {
  local s="${1:0:$MAX_LEN}"
  printf '%q' "$s"
}

refuse() {
  log "refused ($1) from ${SSH_CLIENT%% *}: $(shown "${SSH_ORIGINAL_COMMAND-<none>}")"
  echo "ERROR: refused ($1). Only 'deploy <project> <commit-sha|vX.Y.Z>' is accepted." >&2
  exit 2
}

SSH_CLIENT="${SSH_CLIENT:-unknown}"
[[ -n "${SSH_ORIGINAL_COMMAND+set}" ]] || refuse "interactive login"
cmd="$SSH_ORIGINAL_COMMAND"
((${#cmd} <= MAX_LEN)) || refuse "request too long"
# (bash [[ =~ ]]: ERE without REG_NEWLINE, $ only at the very end; the classes exclude spaces,
# newlines and every shell metacharacter)
if [[ ! "$cmd" =~ ^deploy\ ($PROJECT_RE)\ ($REF_RE)$ ]]; then
  refuse "not 'deploy <project> <ref>'"
fi
project="${BASH_REMATCH[1]}"
ref="${BASH_REMATCH[2]}"

log "accepted from ${SSH_CLIENT%% *}: deploy $project $ref"
rc=0
"$BIN/sudo" -n /opt/adk/test/deploy.sh "$project" "$ref" < /dev/null || rc=$?
log "finished: deploy $project $ref (exit $rc)"
exit "$rc"
