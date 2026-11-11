#!/usr/bin/env bash
# Restore the agent VPS from a backup directory written by agent/backup.sh. Runs as root.
#
# Usage: sudo /opt/adk/agent/restore.sh [--gitea] [--secrets] [--hermes-home] --yes <backup-dir>
#
#   --gitea        Gitea from gitea-dump.tar.gz (default when no part is named): stop Gitea,
#                  keep the current data as /var/lib/adk/gitea.before-restore-<time>, rebuild
#                  data, repositories and database from the dump, start, check /api/healthz
#   --secrets      /opt/adk/secrets and kit.env (new server); run setup.sh afterwards
#   --hermes-home  unpack hermes-home.tar AS hermes into its home (tar as that user: symlinks
#                  in the home cannot redirect it, files keep hermes as owner)
#   --yes          required: the restore replaces current data
#
# The files of the chosen parts are checked against MANIFEST (sha256) first; a part listed in
# FAILED is refused. Exit codes: 0 = restored, 1 = failure, 2 = usage.
set -euo pipefail
export LC_ALL=C
umask 077

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib/host.sh
source "$HERE/lib/host.sh"

AGENT_USER=hermes
COMPOSE_FILE=/opt/adk/services/compose.yaml
SERVICES_DIR=/opt/adk/services
DATA=/var/lib/adk/gitea
KIT_DIR=/opt/adk

usage() {
  echo "usage: $0 [--gitea] [--secrets] [--hermes-home] --yes <backup-dir>" >&2
  exit 2
}

DO_GITEA=false DO_SECRETS=false DO_HOME=false YES=false DIR=""
while (($#)); do
  case "$1" in
    --gitea) DO_GITEA=true ;;
    --secrets) DO_SECRETS=true ;;
    --hermes-home) DO_HOME=true ;;
    --yes) YES=true ;;
    -*) usage ;;
    *) [[ -z "$DIR" ]] || usage; DIR="$1" ;;
  esac
  shift
done
[[ -n "$DIR" ]] || usage
[[ "$DO_GITEA" == true || "$DO_SECRETS" == true || "$DO_HOME" == true ]] || DO_GITEA=true
[[ -d "$DIR" && ! -L "$DIR" ]] || { echo "ERROR: not a backup directory: $DIR" >&2; exit 2; }
DIR="$(cd "$DIR" && pwd)"

parts=()
[[ "$DO_GITEA" == false ]] || parts+=("gitea-dump:gitea-dump.tar.gz")
[[ "$DO_SECRETS" == false ]] || parts+=("adk-secrets:adk-secrets.tar")
[[ "$DO_HOME" == false ]] || parts+=("hermes-home:hermes-home.tar")

# --- check the backup before touching anything -----------------------------------------------
[[ -f "$DIR/MANIFEST" ]] || adk_die "$DIR has no MANIFEST (not written by backup.sh?)"
for p in "${parts[@]}"; do
  name="${p%%:*}" file="${p#*:}"
  if [[ -f "$DIR/FAILED" ]] && grep -q "^$name" "$DIR/FAILED"; then
    adk_die "part $name failed in this backup (see $DIR/FAILED); choose another backup"
  fi
  [[ -f "$DIR/$file" && ! -L "$DIR/$file" ]] || adk_die "$DIR/$file is missing"
  grep -qE "^[0-9a-f]{64}  $file\$" "$DIR/MANIFEST" || adk_die "$file is not listed in MANIFEST"
  (cd "$DIR" && grep -E "  $file\$" MANIFEST | sha256sum -c --quiet -) || adk_die "$file does not match its sha256 in MANIFEST"
done
echo "backup $DIR: checksums ok (${parts[*]%%:*})"

if [[ "$YES" != true ]]; then
  echo "Restore replaces current data. Re-run with --yes to restore: ${parts[*]%%:*}" >&2
  exit 2
fi
[[ "$(id -u)" -eq 0 ]] || adk_die "run as root (sudo $0)"

TS="$(date -u +%Y%m%dT%H%M%SZ)"
compose() { docker compose -f "$COMPOSE_FILE" --project-directory "$SERVICES_DIR" "$@"; }

# --- secrets -----------------------------------------------------------------------------
if [[ "$DO_SECRETS" == true ]]; then
  echo "== secrets"
  tar -tf "$DIR/adk-secrets.tar" | grep -vqE '^(secrets(/[A-Za-z0-9._-]+)?/?|kit\.env)$' \
    && adk_die "adk-secrets.tar contains unexpected paths"
  [[ ! -L "$KIT_DIR/secrets" ]] || adk_die "$KIT_DIR/secrets is a symlink"
  tar -xf "$DIR/adk-secrets.tar" -C "$KIT_DIR" --no-same-owner --no-overwrite-dir
  chown -R root:root "$KIT_DIR/secrets" "$KIT_DIR/kit.env"
  chmod 0700 "$KIT_DIR/secrets"
  chmod 0600 "$KIT_DIR/secrets/"* "$KIT_DIR/kit.env"
  echo "restored: $KIT_DIR/secrets and kit.env (run setup.sh next)"
fi

# --- gitea -------------------------------------------------------------------------------
if [[ "$DO_GITEA" == true ]]; then
  echo "== gitea"
  work="/var/lib/adk/restore-$TS"
  install -d -m 0700 -o root -g root "$work"
  trap 'rm -rf "$work"' EXIT
  tar -xzf "$DIR/gitea-dump.tar.gz" -C "$work" --no-same-owner
  [[ -f "$work/gitea-db.sql" ]] || adk_die "the dump has no gitea-db.sql"

  compose stop gitea
  old="$DATA.before-restore-$TS"
  mv "$DATA" "$old"
  echo "current data moved to $old"
  install -d -m 0755 -o root -g root "$DATA" "$DATA/gitea" "$DATA/gitea/conf" "$DATA/git" "$DATA/git/repositories"
  if [[ -d "$work/data" ]]; then cp -a "$work/data/." "$DATA/gitea/"; fi
  if [[ -d "$work/repos" ]]; then cp -a "$work/repos/." "$DATA/git/repositories/"; fi
  if [[ -f "$work/app.ini" ]]; then cp "$work/app.ini" "$DATA/gitea/conf/app.ini"; fi
  rm -f "$DATA/gitea/gitea.db"
  python3 -I -c '
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
with open(sys.argv[2], encoding="utf-8") as f:
    con.executescript(f.read())
con.commit()
con.close()' "$DATA/gitea/gitea.db" "$work/gitea-db.sql" || adk_die "database import failed; old data is in $old"
  # the container user git (host user adk-gitea) owns its data, as the image expects
  chown -R adk-gitea:adk-gitea "$DATA/gitea" "$DATA/git"

  compose up -d gitea
  ok=false
  for ((i = 0; i < 90; i++)); do
    if compose exec -T gitea curl -fsS -o /dev/null http://127.0.0.1:3000/api/healthz 2>/dev/null; then ok=true; break; fi
    sleep 2
  done
  [[ "$ok" == true ]] || { compose logs --tail 50 gitea >&2 || true; adk_die "gitea is not healthy after the restore; old data is in $old"; }
  compose exec -T -u git gitea gitea admin regenerate hooks < /dev/null > /dev/null
  echo "restored: gitea (healthy: /api/healthz). Check it, then remove $old"
fi

# --- home of hermes ----------------------------------------------------------------------
if [[ "$DO_HOME" == true ]]; then
  echo "== home of $AGENT_USER"
  home="$(adk_user_home "$AGENT_USER")"
  [[ -n "$home" ]] || adk_die "user $AGENT_USER does not exist (run setup.sh first)"
  adk_as_user "$AGENT_USER" tar -C "$home" --preserve-permissions -xf - < "$DIR/hermes-home.tar" \
    || adk_die "unpacking hermes-home.tar as $AGENT_USER failed"
  echo "restored: home of $AGENT_USER (unpacked as $AGENT_USER)"
fi
echo "restore done"
