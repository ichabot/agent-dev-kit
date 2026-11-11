#!/usr/bin/env bash
# Nightly backup of the agent VPS (adk-backup.timer, 03:30). Runs as root.
#
# Usage: sudo /opt/adk/agent/backup.sh [--config FILE]     (default: /opt/adk/kit.env)
#
# Writes /var/backups/adk/<UTC timestamp>/ (root, 0700):
#   gitea-dump.tar.gz   `gitea dump` (database as SQL, repositories, data, app.ini), made as
#                       the container user git
#   adk-secrets.tar     /opt/adk/secrets and /opt/adk/kit.env
#   hermes-home.tar     home of hermes, packed AS hermes (tar never follows symlinks; root never
#                       reads in that home); without caches (.cache, node_modules), the rootless
#                       Docker data and the Hermes software that setup.sh installs again
#   MANIFEST            sha256 of the files above
# Keeps 7 days (the newest complete backup is never deleted). With BACKUP_TARGET the new
# directory is copied with rsync over SSH (key /root/.ssh/adk-backup, set up by setup.sh).
# Every part is attempted; any failure ends with exit 1 (systemd marks the unit failed, the
# reason is in the journal: journalctl -u adk-backup) and the directory gets a FAILED file.
#
# Tests (non-root with ADK_AS_USER_HOOK): ADK_BACKUP_DIR, ADK_TEST_HERMES_HOME,
# ADK_TEST_KIT_DIR replace /var/backups/adk, ~hermes and /opt/adk.
set -euo pipefail
export LC_ALL=C
umask 077

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib/host.sh
source "$HERE/lib/host.sh"
# shellcheck source-path=SCRIPTDIR source=../scripts/lib/config.sh
source "$ROOT/scripts/lib/config.sh"

AGENT_USER=hermes
KEEP_DAYS=7
COMPOSE_FILE=/opt/adk/services/compose.yaml
BACKUP_KEY=/root/.ssh/adk-backup

usage() { echo "usage: $0 [--config FILE]" >&2; exit 2; }

KIT_DIR=/opt/adk
CONFIG=""
while (($#)); do
  case "$1" in
    --config) (($# >= 2)) || usage; CONFIG="$2"; shift 2 ;;
    *) usage ;;
  esac
done

if [[ "$(id -u)" -ne 0 ]]; then
  [[ -n "${ADK_AS_USER_HOOK:-}" && -n "${ADK_BACKUP_DIR:-}" && -n "${ADK_TEST_HERMES_HOME:-}" && -n "${ADK_TEST_KIT_DIR:-}" ]] \
    || { echo "ERROR: run as root (sudo $0)" >&2; exit 2; }
  BACKUP_ROOT="$ADK_BACKUP_DIR"
  AGENT_HOME="$ADK_TEST_HERMES_HOME"
  KIT_DIR="$ADK_TEST_KIT_DIR"
else
  BACKUP_ROOT=/var/backups/adk
  AGENT_HOME="$(adk_user_home "$AGENT_USER")"
fi
CONFIG="${CONFIG:-$KIT_DIR/kit.env}"
[[ -f "$CONFIG" ]] || { echo "ERROR: config file not found: $CONFIG" >&2; exit 2; }
load_config "$CONFIG"
((${#CFG_ERRORS[@]} == 0)) || adk_die "invalid $CONFIG (run scripts/check-config.sh)"
TARGET="${CFG[BACKUP_TARGET]:-}"

[[ ! -L "$BACKUP_ROOT" ]] || adk_die "$BACKUP_ROOT is a symlink"
mkdir -p "$BACKUP_ROOT"
chmod 0700 "$BACKUP_ROOT"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
DIR="$BACKUP_ROOT/$TS"
mkdir "$DIR"
FAILED=()
fail() { echo "ERROR: $*" >&2; FAILED+=("$1"); }
log() { echo "backup: $*"; }

# --- Gitea -------------------------------------------------------------------------------
log "gitea dump"
# (listing first, then grep: "grep -q" in a pipe would make tar die of SIGPIPE under pipefail)
if docker compose -f "$COMPOSE_FILE" exec -T -u git -w /tmp gitea \
    gitea dump --type tar.gz --file - --quiet < /dev/null > "$DIR/gitea-dump.tar.gz" \
  && listing="$(tar -tzf "$DIR/gitea-dump.tar.gz")" && grep -qx 'gitea-db.sql' <<< "$listing"; then
  log "gitea-dump.tar.gz $(du -h "$DIR/gitea-dump.tar.gz" | cut -f1)"
else
  fail "gitea-dump: gitea dump failed or the archive has no gitea-db.sql"
fi

# --- secrets and kit.env -------------------------------------------------------------------
log "secrets"
if tar -C "$KIT_DIR" -cf "$DIR/adk-secrets.tar" secrets kit.env; then
  log "adk-secrets.tar"
else
  fail "adk-secrets: tar of $KIT_DIR/secrets and kit.env failed"
fi

# --- home of hermes (packed as hermes) -------------------------------------------------------
log "home of $AGENT_USER"
rc=0
# Excluded: caches, rootless Docker data, and software setup.sh installs again (Hermes code,
# its tools and Python runtimes); kept: ~/.hermes config, memories, sessions, skills, projects.
adk_as_user "$AGENT_USER" tar -C "$AGENT_HOME" --one-file-system \
  --exclude=.cache --exclude=node_modules --exclude=./.local/share/docker \
  --exclude=./.local/share/uv --exclude=./.hermes/hermes-agent --exclude=./.hermes/tools \
  --exclude=./.hermes/cache --exclude=./.hermes/installs \
  -cf - . > "$DIR/hermes-home.tar" || rc=$?
case "$rc" in
  0) log "hermes-home.tar $(du -h "$DIR/hermes-home.tar" | cut -f1)" ;;
  1) log "hermes-home.tar (some files changed while reading; archive complete)" ;;
  *) fail "hermes-home: tar as $AGENT_USER exited with $rc (unreadable files? see above)" ;;
esac

# --- manifest, result --------------------------------------------------------------------
(cd "$DIR" && sha256sum -- *.tar* > MANIFEST)
if ((${#FAILED[@]})); then
  printf '%s\n' "${FAILED[@]}" > "$DIR/FAILED"
fi

# --- retention: keep KEEP_DAYS days, never the newest complete backup ----------------------
newest_ok="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended -regex '.*/[0-9]{8}T[0-9]{6}Z' \
  ! -exec test -e '{}/FAILED' \; -printf '%f\n' | sort | tail -n 1)"
cutoff="$(date -u -d "-$KEEP_DAYS days" +%Y%m%dT%H%M%SZ)"
while IFS= read -r old; do
  [[ -n "$old" && "$old" != "$newest_ok" && "$old" != "$TS" ]] || continue
  if [[ "$old" < "$cutoff" ]]; then
    rm -rf -- "${BACKUP_ROOT:?}/$old"
    log "removed $old (older than $KEEP_DAYS days)"
  fi
done < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended -regex '.*/[0-9]{8}T[0-9]{6}Z' -printf '%f\n' | sort)

# --- off-site copy -------------------------------------------------------------------------
if [[ -n "$TARGET" ]]; then
  rest="${TARGET#sftp://}"
  userhost="${rest%%/*}"
  path="/${rest#*/}"
  [[ "$rest" == */* ]] || path="."
  port=22
  if [[ "$userhost" == *:* ]]; then port="${userhost##*:}"; userhost="${userhost%:*}"; fi
  log "copy to $userhost:$path (port $port)"
  if [[ ! -f "$BACKUP_KEY" ]]; then
    fail "offsite: $BACKUP_KEY missing (run setup.sh)"
  elif ! rsync -a --partial -e "ssh -i $BACKUP_KEY -p $port -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$BACKUP_KEY.known_hosts" \
      "$DIR" "$userhost:$path/"; then
    fail "offsite: rsync to $userhost:$path failed"
  fi
fi

if ((${#FAILED[@]})); then
  printf '%s\n' "${FAILED[@]}" > "$DIR/FAILED"
  echo "ERROR: backup $DIR incomplete: ${#FAILED[@]} part(s) failed (see FAILED there and the messages above)" >&2
  exit 1
fi
log "done: $DIR"
