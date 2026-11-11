#!/usr/bin/env bash
# Nightly backup of the agent VPS (adk-backup.timer, 03:30). Runs as root.
#
# Usage: sudo /opt/adk/agent/backup.sh [--config FILE]     (default: /opt/adk/kit.env)
#        sudo /opt/adk/agent/backup.sh --ensure-gitea       (ExecStopPost of adk-backup.service)
#
# Writes /var/backups/adk/<UTC timestamp>/ (root, 0700; local copies are NOT encrypted):
#   gitea-dump.tar.gz   `gitea dump` (database as SQL, repositories, data, app.ini) of a
#                       STOPPED Gitea: a one-off container of the same image dumps as user git
#                       while the service is down (no pushes or jobs during the dump; at most
#                       2 hours); Gitea is started again afterwards in any case: by this script,
#                       and if it is killed (or the server shuts down meanwhile) by
#                       --ensure-gitea, which adk-backup.service runs as ExecStopPost (a marker
#                       file records that the backup stopped Gitea)
#   adk-secrets.tar     /opt/adk/secrets and /opt/adk/kit.env
#   hermes-home.tar.gz  home of hermes, packed AS hermes (tar never follows symlinks; root never
#                       reads in that home); without caches (.cache, node_modules), the rootless
#                       Docker data and the Hermes software that setup.sh installs again
#   MANIFEST            first line "backup <UTC timestamp> <server name adk-CUSTOMER_NAME-agent>"
#                       (restore.sh compares it with the directory name: an older backup cannot
#                       pass as a newer one), sha256 of the files above and, with BACKUP_TARGET,
#                       of their age-encrypted copies, plus "FAILED <part>" lines
#   MANIFEST.sig        ssh-keygen -Y signature of MANIFEST (key /root/.ssh/adk-backup-sign,
#                       namespace adk-backup); restore.sh verifies it
# Before starting, the free space on /var/backups is checked against the size of the data.
# Keeps 7 days by directory name (the newest complete backup is never deleted).
# With BACKUP_TARGET every archive is encrypted with age to BACKUP_AGE_RECIPIENT (the private
# key stays with the customer, offline) and copied with MANIFEST and MANIFEST.sig by rsync over
# SSH (key /root/.ssh/adk-backup, host key pinned in /root/.ssh/adk-backup.known_hosts by
# setup.sh --accept-backup-hostkey; no trust on first use).
# Every part is attempted; any failure ends with exit 1 (systemd marks the unit failed, the
# reason is in the journal: journalctl -u adk-backup) and the directory gets a FAILED file.
#
# Tests (non-root with ADK_AS_USER_HOOK): ADK_BACKUP_DIR, ADK_TEST_HERMES_HOME,
# ADK_TEST_KIT_DIR, ADK_TEST_GITEA_DATA, ADK_BACKUP_SIGN_KEY, ADK_BACKUP_SSH_DIR replace the
# real paths; ADK_TEST_FREE_KB fakes the free space, ADK_TEST_DUMP_TIMEOUT the dump timeout.
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
SERVICES_DIR=/opt/adk/services
SIGN_NAMESPACE=adk-backup
HOME_EXCLUDES=(--exclude=.cache --exclude=node_modules --exclude=./.local/share/docker
  --exclude=./.local/share/uv --exclude=./.hermes/hermes-agent --exclude=./.hermes/tools
  --exclude=./.hermes/cache --exclude=./.hermes/installs)

DUMP_TIMEOUT=2h
DUMP_CONTAINER=adk-backup-dump

usage() { echo "usage: $0 [--config FILE] | --ensure-gitea" >&2; exit 2; }

KIT_DIR=/opt/adk
CONFIG=""
ENSURE_GITEA=false
while (($#)); do
  case "$1" in
    --config) (($# >= 2)) || usage; CONFIG="$2"; shift 2 ;;
    --ensure-gitea) ENSURE_GITEA=true; shift ;;
    *) usage ;;
  esac
done

FREE_KB=""
if [[ "$(id -u)" -ne 0 ]]; then
  [[ -n "${ADK_AS_USER_HOOK:-}" && -n "${ADK_BACKUP_DIR:-}" && -n "${ADK_TEST_HERMES_HOME:-}" && -n "${ADK_TEST_KIT_DIR:-}" \
    && -n "${ADK_TEST_GITEA_DATA:-}" && -n "${ADK_BACKUP_SIGN_KEY:-}" && -n "${ADK_BACKUP_SSH_DIR:-}" ]] \
    || { echo "ERROR: run as root (sudo $0)" >&2; exit 2; }
  BACKUP_ROOT="$ADK_BACKUP_DIR"
  AGENT_HOME="$ADK_TEST_HERMES_HOME"
  KIT_DIR="$ADK_TEST_KIT_DIR"
  GITEA_DATA="$ADK_TEST_GITEA_DATA"
  SIGN_KEY="$ADK_BACKUP_SIGN_KEY"
  SSH_DIR="$ADK_BACKUP_SSH_DIR"
  FREE_KB="${ADK_TEST_FREE_KB:-}"
  DUMP_TIMEOUT="${ADK_TEST_DUMP_TIMEOUT:-$DUMP_TIMEOUT}"
else
  BACKUP_ROOT=/var/backups/adk
  AGENT_HOME="$(adk_user_home "$AGENT_USER")"
  GITEA_DATA=/var/lib/adk/gitea
  SIGN_KEY=/root/.ssh/adk-backup-sign
  SSH_DIR=/root/.ssh
fi
BACKUP_KEY="$SSH_DIR/adk-backup"
KNOWN_HOSTS="$SSH_DIR/adk-backup.known_hosts"
# exists while Gitea is stopped by a backup (root-only directory)
GITEA_MARKER="$BACKUP_ROOT/.gitea-stopped-by-backup"

compose() { docker compose -f "$COMPOSE_FILE" --project-directory "$SERVICES_DIR" "$@"; }
log() { echo "backup: $*"; }

# start_gitea_if_stopped: start Gitea if a backup stopped it (marker), then drop the marker
start_gitea_if_stopped() {
  [[ -e "$GITEA_MARKER" ]] || return 0
  if compose start gitea > /dev/null 2>&1 || compose up -d gitea > /dev/null 2>&1; then
    rm -f "$GITEA_MARKER"
    log "gitea started again"
  else
    echo "ERROR: gitea could not be started again after the dump; start it: docker compose -f $COMPOSE_FILE up -d gitea" >&2
    return 1
  fi
}

if [[ "$ENSURE_GITEA" == true ]]; then
  [[ ! -L "$BACKUP_ROOT" ]] || adk_die "$BACKUP_ROOT is a symlink"
  start_gitea_if_stopped
  exit
fi

CONFIG="${CONFIG:-$KIT_DIR/kit.env}"
[[ -f "$CONFIG" ]] || { echo "ERROR: config file not found: $CONFIG" >&2; exit 2; }
load_config "$CONFIG"
((${#CFG_ERRORS[@]} == 0)) || adk_die "invalid $CONFIG (run scripts/check-config.sh)"
TARGET="${CFG[BACKUP_TARGET]:-}"
RECIPIENT="${CFG[BACKUP_AGE_RECIPIENT]:-}"
[[ -z "$TARGET" || -n "$RECIPIENT" ]] || adk_die "BACKUP_TARGET without BACKUP_AGE_RECIPIENT (run scripts/check-config.sh)"
# the server's name (agent/provision.sh), signed into MANIFEST
SERVER_NAME="adk-${CFG[CUSTOMER_NAME]}-agent"

[[ ! -L "$BACKUP_ROOT" ]] || adk_die "$BACKUP_ROOT is a symlink"
mkdir -p "$BACKUP_ROOT"
chmod 0700 "$BACKUP_ROOT"

# --- free space ---------------------------------------------------------------------------
# Upper bound: Gitea data + secrets + the part of hermes's home that is saved (measured AS
# hermes), uncompressed, plus 10 % and 512 MB headroom.
need_kb=0
for d in "$GITEA_DATA" "$KIT_DIR/secrets"; do
  if [[ -d "$d" ]]; then need_kb=$((need_kb + $(du -sk --apparent-size --one-file-system "$d" 2>/dev/null | cut -f1))); fi
done
# (from inside the home, so the ./ exclude patterns match as they do for tar)
# shellcheck disable=SC2016  # expanded by the inner sh
home_kb="$(adk_as_user "$AGENT_USER" sh -c 'cd "$1" || exit 1; shift; exec du -sk --apparent-size --one-file-system "$@" .' \
  sh "$AGENT_HOME" "${HOME_EXCLUDES[@]}" 2>/dev/null | cut -f1 || true)"
[[ "$home_kb" =~ ^[0-9]+$ ]] && need_kb=$((need_kb + home_kb))
need_kb=$((need_kb + need_kb / 10 + 524288))
[[ -n "$FREE_KB" ]] || FREE_KB="$(df -Pk "$BACKUP_ROOT" | awk 'NR == 2 {print $4}')"
if ((FREE_KB < need_kb)); then
  echo "ERROR: not enough space in $BACKUP_ROOT: $((FREE_KB / 1024)) MB free, about $((need_kb / 1024)) MB needed; no backup made (free space or remove old backups)" >&2
  exit 1
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
DIR="$BACKUP_ROOT/$TS"
mkdir "$DIR"
FAILED=()
fail() { echo "ERROR: $*" >&2; FAILED+=("$1"); }

# --- Gitea (stopped while the dump runs) ----------------------------------------------------
log "gitea dump (gitea stopped meanwhile, at most $DUMP_TIMEOUT)"
trap 'start_gitea_if_stopped || true' EXIT
trap 'exit 1' INT TERM HUP
: > "$GITEA_MARKER"
if compose stop gitea > /dev/null 2>&1; then
  docker rm -f "$DUMP_CONTAINER" > /dev/null 2>&1 || true
  rc=0
  timeout --kill-after=60s "$DUMP_TIMEOUT" docker compose -f "$COMPOSE_FILE" --project-directory "$SERVICES_DIR" run --rm --no-deps --name "$DUMP_CONTAINER" -T -w /tmp gitea \
    su-exec git gitea dump --type tar.gz --file - --quiet < /dev/null > "$DIR/gitea-dump.tar.gz" || rc=$?
  if ((rc == 124 || rc == 137)); then
    docker rm -f "$DUMP_CONTAINER" > /dev/null 2>&1 || true
    fail "gitea-dump: gitea dump did not finish within $DUMP_TIMEOUT"
  # (listing first, then grep: "grep -q" in a pipe would make tar die of SIGPIPE under pipefail)
  elif ((rc == 0)) && listing="$(tar -tzf "$DIR/gitea-dump.tar.gz")" && grep -qx 'gitea-db.sql' <<< "$listing"; then
    log "gitea-dump.tar.gz $(du -h "$DIR/gitea-dump.tar.gz" | cut -f1)"
  else
    fail "gitea-dump: gitea dump failed or the archive has no gitea-db.sql"
  fi
else
  fail "gitea-dump: cannot stop gitea for a consistent dump"
fi
start_gitea_if_stopped || FAILED+=("gitea-start")

# --- secrets and kit.env -------------------------------------------------------------------
log "secrets"
if tar -C "$KIT_DIR" -cf "$DIR/adk-secrets.tar" secrets kit.env; then
  log "adk-secrets.tar"
else
  fail "adk-secrets: tar of $KIT_DIR/secrets and kit.env failed"
fi

# --- home of hermes (packed and compressed as hermes) -----------------------------------------
log "home of $AGENT_USER"
rc=0
# Excluded: caches, rootless Docker data, and software setup.sh installs again (Hermes code,
# its tools and Python runtimes); kept: ~/.hermes config, memories, sessions, skills, projects.
adk_as_user "$AGENT_USER" tar -C "$AGENT_HOME" --one-file-system "${HOME_EXCLUDES[@]}" \
  -czf - . > "$DIR/hermes-home.tar.gz" || rc=$?
case "$rc" in
  0) log "hermes-home.tar.gz $(du -h "$DIR/hermes-home.tar.gz" | cut -f1)" ;;
  1) log "hermes-home.tar.gz (some files changed while reading; archive complete)" ;;
  *) fail "hermes-home: tar as $AGENT_USER exited with $rc (unreadable files? see above)" ;;
esac

# --- off-site: encrypted first, so the signed MANIFEST covers the ciphertexts too -----------
STAGE=""
if [[ -n "$TARGET" ]]; then
  if [[ ! -f "$BACKUP_KEY" ]]; then
    fail "offsite: $BACKUP_KEY missing (run setup.sh)"
  elif [[ ! -s "$KNOWN_HOSTS" ]]; then
    fail "offsite: host key of the target not pinned (run setup.sh, then setup.sh --accept-backup-hostkey <fingerprint>)"
  elif ! command -v age > /dev/null; then
    fail "offsite: age is not installed (run setup.sh)"
  else
    stage="$BACKUP_ROOT/.offsite-$TS"
    rm -rf -- "$stage"
    mkdir -m 0700 "$stage"
    ok=true
    for f in "$DIR"/*.tar*; do
      age -r "$RECIPIENT" -o "$stage/$(basename "$f").age" "$f" || { ok=false; break; }
    done
    if [[ "$ok" == true ]]; then STAGE="$stage"; else rm -rf -- "$stage"; fail "offsite: age encryption failed"; fi
  fi
fi

# --- manifest and signature -----------------------------------------------------------------
(
  printf 'backup %s %s\n' "$TS" "$SERVER_NAME"
  cd "$DIR"
  sha256sum -- *.tar*
  if [[ -n "$STAGE" ]]; then (cd "$STAGE" && sha256sum -- *.age); fi
  for f in "${FAILED[@]}"; do printf 'FAILED %s\n' "${f%%:*}"; done
) > "$DIR/MANIFEST"
if [[ -f "$SIGN_KEY" && ! -L "$SIGN_KEY" ]] \
    && ssh-keygen -q -Y sign -f "$SIGN_KEY" -n "$SIGN_NAMESPACE" "$DIR/MANIFEST" > /dev/null 2>&1 \
    && [[ -s "$DIR/MANIFEST.sig" ]]; then
  log "MANIFEST signed"
else
  fail "manifest-signature: cannot sign MANIFEST with $SIGN_KEY (run setup.sh)"
fi
if ((${#FAILED[@]})); then
  printf '%s\n' "${FAILED[@]}" > "$DIR/FAILED"
fi

# --- retention: keep KEEP_DAYS days, never the newest complete backup ----------------------
# Directory names are UTC timestamps, so the lexical order is the time order.
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

# --- off-site copy: encrypted, signed, pinned host key --------------------------------------
if [[ -n "$STAGE" ]]; then
  rest="${TARGET#sftp://}"
  userhost="${rest%%/*}"
  path="/${rest#*/}"
  [[ "$rest" == */* ]] || path="."
  port=22
  if [[ "$userhost" == *:* ]]; then port="${userhost##*:}"; userhost="${userhost%:*}"; fi
  log "encrypted copy to $userhost:$path/$TS (port $port)"
  ok=true
  cp -p "$DIR/MANIFEST" "$STAGE/" || ok=false
  [[ ! -f "$DIR/MANIFEST.sig" ]] || cp -p "$DIR/MANIFEST.sig" "$STAGE/" || ok=false
  [[ ! -f "$DIR/FAILED" ]] || cp -p "$DIR/FAILED" "$STAGE/" || ok=false
  if [[ "$ok" != true ]]; then
    fail "offsite: cannot stage MANIFEST and signature"
  elif ! rsync -a --partial -e "ssh -i $BACKUP_KEY -p $port -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$KNOWN_HOSTS" \
      "$STAGE/" "$userhost:$path/$TS/"; then
    fail "offsite: rsync to $userhost:$path failed"
  else
    log "off-site: $(find "$STAGE" -maxdepth 1 -name '*.age' | wc -l) encrypted archive(s), MANIFEST and signature copied"
  fi
  rm -rf -- "$STAGE"
fi

if ((${#FAILED[@]})); then
  printf '%s\n' "${FAILED[@]}" > "$DIR/FAILED"
  echo "ERROR: backup $DIR incomplete: ${#FAILED[@]} part(s) failed (see FAILED there and the messages above)" >&2
  exit 1
fi
log "done: $DIR"
