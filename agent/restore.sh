#!/usr/bin/env bash
# Restore the agent VPS from a backup directory written by agent/backup.sh. Runs as root.
#
# Usage: sudo /opt/adk/agent/restore.sh [--gitea] [--secrets] [--hermes-home]
#          [--signer FILE] [--age-identity FILE] [--config FILE] --yes <backup-dir>
#
#   --gitea           Gitea from gitea-dump.tar.gz (default when no part is named): stop Gitea,
#                     keep the current data as /var/lib/adk/gitea.before-restore-<time>,
#                     rebuild data, repositories and database from the dump, start, check
#                     /api/healthz
#   --secrets         /opt/adk/secrets and kit.env (new server); run setup.sh afterwards
#   --hermes-home     unpack hermes-home.tar.gz AS hermes into its home (tar as that user:
#                     symlinks in the home cannot redirect it, files keep hermes as owner)
#   --signer FILE     public key of the backup signing key (adk-backup-sign.pub, or an
#                     allowed-signers file); default /etc/adk/backup-allowed-signers. On a new
#                     server use the copy the customer keeps offline.
#   --age-identity F  age private key for an off-site copy (*.age files); decrypted into a
#                     temporary root-only directory, never next to the backup
#   --config FILE     kit.env whose CUSTOMER_NAME names this server (default /opt/adk/kit.env;
#                     without it the server name in the backup is only shown)
#   --yes             required: the restore replaces current data
#
# A backup directory that an unprivileged user could change (owner, write permission of it, its
# files or a parent directory) is first copied into a temporary root-only directory; only the
# copies are verified and used. Checks before anything is changed: MANIFEST.sig is a valid
# signature of MANIFEST (namespace adk-backup); its first line "backup <timestamp> <server>"
# matches the directory name (an older backup renamed to a newer name is refused) and this
# server, the age of the backup is shown; every chosen file (and an .age ciphertext BEFORE it
# is decrypted) matches its sha256 in MANIFEST, no chosen part is marked FAILED, and the
# archives contain only regular files and directories at expected paths (no symlinks, hard
# links or devices: a tampered dump must not make root write elsewhere).
# Exit codes: 0 = restored, 1 = failure, 2 = usage.
set -euo pipefail
export LC_ALL=C
umask 077

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib/host.sh
source "$HERE/lib/host.sh"
# shellcheck source-path=SCRIPTDIR source=../scripts/lib/config.sh
source "$HERE/../scripts/lib/config.sh"

AGENT_USER=hermes
COMPOSE_FILE=/opt/adk/services/compose.yaml
SERVICES_DIR=/opt/adk/services
DATA=/var/lib/adk/gitea
KIT_DIR=/opt/adk
SIGN_NAMESPACE=adk-backup

usage() {
  echo "usage: $0 [--gitea] [--secrets] [--hermes-home] [--signer FILE] [--age-identity FILE] [--config FILE] --yes <backup-dir>" >&2
  exit 2
}

DO_GITEA=false DO_SECRETS=false DO_HOME=false YES=false DIR="" SIGNER=/etc/adk/backup-allowed-signers IDENTITY=""
CONFIG="$KIT_DIR/kit.env"
while (($#)); do
  case "$1" in
    --gitea) DO_GITEA=true ;;
    --secrets) DO_SECRETS=true ;;
    --hermes-home) DO_HOME=true ;;
    --yes) YES=true ;;
    --signer) (($# >= 2)) || usage; SIGNER="$2"; shift ;;
    --age-identity) (($# >= 2)) || usage; IDENTITY="$2"; shift ;;
    --config) (($# >= 2)) || usage; CONFIG="$2"; shift ;;
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
[[ "$DO_HOME" == false ]] || parts+=("hermes-home:hermes-home.tar.gz")

# decrypted archives and the allowed-signers file: root-only, on disk (not the /tmp tmpfs)
if [[ "$(id -u)" -eq 0 ]]; then
  install -d -m 0700 -o root -g root /var/lib/adk
  WORK="$(mktemp -d -p /var/lib/adk restore-tmp.XXXXXX)"
else
  WORK="$(mktemp -d)"
fi
trap 'rm -rf "$WORK"' EXIT

# --- copy into a root-only directory if anybody else could change the backup -------------
# (names of the files a restore of the chosen parts reads)
files=(MANIFEST MANIFEST.sig FAILED)
for p in "${parts[@]}"; do files+=("${p#*:}" "${p#*:}.age"); done
trusted=true
adk_dir_chain_trusted "$DIR" || trusted=false
for f in "${files[@]}"; do
  [[ -e "$DIR/$f" || -L "$DIR/$f" ]] || continue
  if [[ -L "$DIR/$f" || ! -f "$DIR/$f" ]]; then trusted=false; continue; fi
  read -r f_uid f_mode < <(stat -c '%u %a' "$DIR/$f")
  [[ "$f_uid" == "$(id -u)" ]] && (((8#$f_mode & 8#022) == 0)) || trusted=false
done
SRC_DIR="$DIR"
if [[ "$trusted" != true ]]; then
  SRC_DIR="$WORK/backup"
  mkdir -m 0700 "$SRC_DIR"
  for f in "${files[@]}"; do
    [[ -e "$DIR/$f" || -L "$DIR/$f" ]] || continue
    # -P: a symlink stays a symlink (refused below), never followed
    cp -P -- "$DIR/$f" "$SRC_DIR/$f" || adk_die "cannot copy $DIR/$f"
  done
  echo "backup $DIR: others could change it; verifying and using a root-only copy"
fi

# --- signature of MANIFEST ----------------------------------------------------------------------
[[ -f "$SRC_DIR/MANIFEST" && ! -L "$SRC_DIR/MANIFEST" ]] || adk_die "$DIR has no MANIFEST (not written by backup.sh?)"
[[ -f "$SRC_DIR/MANIFEST.sig" && ! -L "$SRC_DIR/MANIFEST.sig" ]] || adk_die "$DIR has no MANIFEST.sig: the backup is not signed, not restoring it"
[[ -f "$SIGNER" ]] || adk_die "signer key $SIGNER not found (pass the backup signing public key with --signer)"
if grep -qE '^ssh-[a-z0-9-]+ [A-Za-z0-9+/=]+( .*)?$' "$SIGNER"; then
  # a plain public key: make it an allowed-signers line
  printf '%s %s\n' "$SIGN_NAMESPACE" "$(awk 'NR == 1 {print $1, $2}' "$SIGNER")" > "$WORK/allowed_signers"
else
  cp "$SIGNER" "$WORK/allowed_signers"
fi
ssh-keygen -Y verify -f "$WORK/allowed_signers" -I "$SIGN_NAMESPACE" -n "$SIGN_NAMESPACE" \
    -s "$SRC_DIR/MANIFEST.sig" < "$SRC_DIR/MANIFEST" > /dev/null 2>&1 \
  || adk_die "MANIFEST.sig does not verify with $SIGNER: the backup was changed or signed by another key"
echo "backup $DIR: MANIFEST signature ok"

# --- which backup: signed header vs. directory name and this server ------------------------
read -r h_word h_ts h_server h_rest < "$SRC_DIR/MANIFEST" || true
[[ "$h_word" == backup && "$h_ts" =~ ^[0-9]{8}T[0-9]{6}Z$ && -n "$h_server" && -z "${h_rest:-}" ]] \
  || adk_die "MANIFEST has no header line \"backup <timestamp> <server>\" (backup of an older kit?); not restoring it"
[[ "$h_ts" == "$(basename "$DIR")" ]] \
  || adk_die "the backup was made at $h_ts but its directory is named $(basename "$DIR"): renamed (e.g. an older backup passed off as a newer one); not restoring it"
if [[ -f "$CONFIG" ]] && load_config "$CONFIG" && [[ -n "${CFG[CUSTOMER_NAME]:-}" ]]; then
  [[ "$h_server" == "adk-${CFG[CUSTOMER_NAME]}-agent" ]] \
    || adk_die "the backup belongs to server $h_server, this is adk-${CFG[CUSTOMER_NAME]}-agent ($CONFIG); not restoring it"
else
  echo "WARNING: no $CONFIG to compare the server name with" >&2
fi
h_epoch="$(date -u -d "${h_ts:0:4}-${h_ts:4:2}-${h_ts:6:2} ${h_ts:9:2}:${h_ts:11:2}:${h_ts:13:2}" +%s)"
age_s=$(($(date -u +%s) - h_epoch))
if ((age_s < 0)); then
  echo "WARNING: the backup's time $h_ts lies in the future (clock?)" >&2
fi
echo "backup of $h_server from $h_ts: $((age_s / 86400)) day(s) $((age_s % 86400 / 3600)) hour(s) old"

# --- the chosen parts: checksums (ciphertext before decrypting, then the archive) ------------
# sha256 FILE: the sha256 that the signed MANIFEST lists for FILE (empty if none)
manifest_sum() { awk -v f="$1" 'NR > 1 && $2 == f && length($1) == 64 {print $1; exit}' "$SRC_DIR/MANIFEST"; }
declare -A SRC=()
for p in "${parts[@]}"; do
  name="${p%%:*}" file="${p#*:}"
  if grep -qx "FAILED $name" "$SRC_DIR/MANIFEST" || { [[ -f "$SRC_DIR/FAILED" ]] && grep -q "^$name" "$SRC_DIR/FAILED"; }; then
    adk_die "part $name failed in this backup (see MANIFEST / FAILED); choose another backup"
  fi
  want="$(manifest_sum "$file")"
  [[ -n "$want" ]] || adk_die "$file is not listed in MANIFEST"
  if [[ -f "$SRC_DIR/$file" && ! -L "$SRC_DIR/$file" ]]; then
    SRC[$name]="$SRC_DIR/$file"
  elif [[ -f "$SRC_DIR/$file.age" && ! -L "$SRC_DIR/$file.age" ]]; then
    [[ -n "$IDENTITY" ]] || adk_die "$file is encrypted ($file.age): pass the age private key with --age-identity"
    want_age="$(manifest_sum "$file.age")"
    [[ -n "$want_age" ]] || adk_die "$file.age is not listed in MANIFEST; not decrypting it"
    [[ "$(sha256sum < "$SRC_DIR/$file.age" | cut -d' ' -f1)" == "$want_age" ]] \
      || adk_die "$file.age does not match its sha256 in MANIFEST; not decrypting it"
    age -d -i "$IDENTITY" -o "$WORK/$file" "$SRC_DIR/$file.age" || adk_die "cannot decrypt $file.age with $IDENTITY"
    SRC[$name]="$WORK/$file"
  else
    adk_die "$DIR/$file is missing"
  fi
  [[ "$(sha256sum < "${SRC[$name]}" | cut -d' ' -f1)" == "$want" ]] || adk_die "$file does not match its sha256 in MANIFEST"
done
echo "backup $DIR: checksums ok (${parts[*]%%:*})"

# check_members ARCHIVE TAR_FLAGS REGEX: only regular files and directories whose names match
# REGEX (listing captured first: no SIGPIPE under pipefail)
check_members() {
  local archive="$1" flags="$2" regex="$3" listing names bad
  listing="$(tar "-tv${flags}f" "$archive")" || adk_die "cannot list $archive"
  bad="$(awk '$1 !~ /^[-d]/' <<< "$listing")"
  [[ -z "$bad" ]] || adk_die "$(basename "$archive") contains links or special files, not restoring it: $(head -n 3 <<< "$bad")"
  names="$(tar "-t${flags}f" "$archive")" || adk_die "cannot list $archive"
  bad="$( (grep -vE "$regex" <<< "$names"; grep -E '(^|/)\.\.(/|$)' <<< "$names") || true)"
  [[ -z "$bad" ]] || adk_die "$(basename "$archive") contains unexpected paths: $(head -n 3 <<< "$bad")"
}
[[ -z "${SRC[adk-secrets]:-}" ]] || check_members "${SRC[adk-secrets]}" "" '^(secrets(/[A-Za-z0-9._-]+)?/?|kit\.env)$'
[[ -z "${SRC[gitea-dump]:-}" ]] || check_members "${SRC[gitea-dump]}" z '^[^/.][^/]*(/[^/]+)*/?$'

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
  [[ ! -L "$KIT_DIR/secrets" ]] || adk_die "$KIT_DIR/secrets is a symlink"
  [[ ! -L "$KIT_DIR/kit.env" ]] || adk_die "$KIT_DIR/kit.env is a symlink"
  find "$KIT_DIR/secrets" -mindepth 1 -type l -print -quit 2>/dev/null | grep -q . \
    && adk_die "$KIT_DIR/secrets contains symlinks; remove them first"
  tar -xf "${SRC[adk-secrets]}" -C "$KIT_DIR" --no-same-owner --no-overwrite-dir
  chown -R --no-dereference root:root "$KIT_DIR/secrets" "$KIT_DIR/kit.env"
  chmod 0700 "$KIT_DIR/secrets"
  find "$KIT_DIR/secrets" -mindepth 1 -type f -exec chmod 0600 {} +
  chmod 0600 "$KIT_DIR/kit.env"
  echo "restored: $KIT_DIR/secrets and kit.env (run setup.sh next)"
fi

# --- gitea -------------------------------------------------------------------------------
if [[ "$DO_GITEA" == true ]]; then
  echo "== gitea"
  work="/var/lib/adk/restore-$TS"
  install -d -m 0700 -o root -g root "$work"
  trap 'rm -rf "$WORK" "$work"' EXIT
  tar -xzf "${SRC[gitea-dump]}" -C "$work" --no-same-owner
  # (checked before extracting; checked again on disk)
  [[ -z "$(find "$work" ! -type f ! -type d -print -quit)" ]] || adk_die "the dump contains links or special files"
  [[ -f "$work/gitea-db.sql" ]] || adk_die "the dump has no gitea-db.sql"

  compose stop gitea
  old="$DATA.before-restore-$TS"
  mv "$DATA" "$old"
  echo "current data moved to $old"
  install -d -m 0755 -o root -g root "$DATA" "$DATA/gitea" "$DATA/gitea/conf" "$DATA/git" "$DATA/git/repositories"
  if [[ -d "$work/data" ]]; then cp -a --no-dereference "$work/data/." "$DATA/gitea/"; fi
  if [[ -d "$work/repos" ]]; then cp -a --no-dereference "$work/repos/." "$DATA/git/repositories/"; fi
  if [[ -f "$work/app.ini" ]]; then cp --remove-destination "$work/app.ini" "$DATA/gitea/conf/app.ini"; fi
  rm -f "$DATA/gitea/gitea.db"
  python3 -I -c '
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
with open(sys.argv[2], encoding="utf-8") as f:
    con.executescript(f.read())
con.commit()
con.close()' "$DATA/gitea/gitea.db" "$work/gitea-db.sql" || adk_die "database import failed; old data is in $old"
  # the container user git (host user adk-gitea) owns its data, as the image expects
  chown -R --no-dereference adk-gitea:adk-gitea "$DATA/gitea" "$DATA/git"

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
  adk_as_user "$AGENT_USER" tar -C "$home" --preserve-permissions -xzf - < "${SRC[hermes-home]}" \
    || adk_die "unpacking hermes-home.tar.gz as $AGENT_USER failed"
  echo "restored: home of $AGENT_USER (unpacked as $AGENT_USER)"
fi
echo "restore done"
