#!/usr/bin/env bats
# Tests for agent/backup.sh (non-root; fake docker emulates `gitea dump`, fake rsync logs)

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BACKUP="$ROOT/agent/backup.sh"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cp "$ROOT/tests/fixtures/fake-docker" "$BATS_TEST_TMPDIR/bin/docker"
  # fake rsync: logs its arguments and copies the source directory to $RSYNC_DEST
  cat > "$BATS_TEST_TMPDIR/bin/rsync" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RSYNC_LOG"
src="${*: -2:1}"
mkdir -p "$RSYNC_DEST" && cp -a "$src/." "$RSYNC_DEST/"
exit "${FAKE_RSYNC_RC:-0}"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/docker" "$BATS_TEST_TMPDIR/bin/rsync"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export FAKE_STATE="$BATS_TEST_TMPDIR/state.json" FAKE_LOG="$BATS_TEST_TMPDIR/calls.log"
  export RSYNC_LOG="$BATS_TEST_TMPDIR/rsync.log" RSYNC_DEST="$BATS_TEST_TMPDIR/offsite"
  : > "$FAKE_LOG"; : > "$RSYNC_LOG"
  docker init

  export ADK_BACKUP_DIR="$BATS_TEST_TMPDIR/backups"
  export ADK_TEST_GITEA_DATA="$BATS_TEST_TMPDIR/gitea-data"
  mkdir -p "$ADK_TEST_GITEA_DATA"
  export ADK_BACKUP_SSH_DIR="$BATS_TEST_TMPDIR/ssh"
  mkdir -m 0700 "$ADK_BACKUP_SSH_DIR"
  export ADK_BACKUP_SIGN_KEY="$ADK_BACKUP_SSH_DIR/adk-backup-sign"
  ssh-keygen -q -t ed25519 -N '' -C adk-backup-sign -f "$ADK_BACKUP_SIGN_KEY"
  printf 'adk-backup %s\n' "$(cut -d' ' -f1,2 "$ADK_BACKUP_SIGN_KEY.pub")" > "$BATS_TEST_TMPDIR/allowed_signers"
  export ADK_TEST_KIT_DIR="$BATS_TEST_TMPDIR/opt-adk"
  mkdir -p "$ADK_TEST_KIT_DIR/secrets"
  cp "$ROOT/tests/fixtures/valid.env" "$ADK_TEST_KIT_DIR/kit.env"
  printf 'secret\n' > "$ADK_TEST_KIT_DIR/secrets/gitea-secret-key"

  H="$BATS_TEST_TMPDIR/hermes"
  export ADK_TEST_HERMES_HOME="$H"
  mkdir -p "$H/.hermes/hermes-agent/venv" "$H/.hermes/tools/browser" "$H/.hermes/sessions" "$H/.local/share/uv/python" "$H/.cache/pip"
  printf 'code\n' > "$H/.hermes/hermes-agent/venv/x.py"
  printf 'bin\n' > "$H/.hermes/tools/browser/chrome"
  printf 'session\n' > "$H/.hermes/sessions/s1.json"
  mkdir -p "$H/proj/node_modules/x" "$H/.local/share/docker/overlay2" "$H/.config"
  printf 'py\n' > "$H/.local/share/uv/python/bin"
  printf 'memory\n' > "$H/.hermes/MEMORY.md"
  printf 'cache\n' > "$H/.cache/pip/blob"
  printf 'module\n' > "$H/proj/node_modules/x/index.js"
  printf 'layer\n' > "$H/.local/share/docker/overlay2/l"
  printf 'code\n' > "$H/proj/main.go"
  printf 'root:HASH:1:0:99999:7:::\n' > "$BATS_TEST_TMPDIR/shadow"
  ln -s "$BATS_TEST_TMPDIR/shadow" "$H/.config/innocent"

  cat > "$BATS_TEST_TMPDIR/as-user" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$BATS_TEST_TMPDIR/as-user.log"
shift
exec "\$@"
EOF
  chmod +x "$BATS_TEST_TMPDIR/as-user"
  export ADK_AS_USER_HOOK="$BATS_TEST_TMPDIR/as-user"
}

refute() {
  if "$@"; then return 1; fi
}

newest() { find "$ADK_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort | tail -n 1; }

@test "creates a timestamped backup with dump, secrets, hermes home and a manifest" {
  run "$BACKUP"
  [ "$status" -eq 0 ]
  d="$ADK_BACKUP_DIR/$(newest)"
  [[ "$(basename "$d")" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]
  [ "$(stat -c %a "$ADK_BACKUP_DIR")" = "700" ]
  tar -tzf "$d/gitea-dump.tar.gz" | grep -qx gitea-db.sql
  tar -tf "$d/adk-secrets.tar" | grep -qx secrets/gitea-secret-key
  tar -tf "$d/adk-secrets.tar" | grep -qx kit.env
  (cd "$d" && sha256sum -c --quiet MANIFEST)
  [ ! -e "$d/FAILED" ]
  # gitea dump runs as the container user git, in a one-off container while gitea is stopped
  grep -q '^gitea dump --type tar.gz --file - --quiet$' "$FAKE_LOG"
  [ "$(grep -E '^(compose (stop|start)|run )' "$FAKE_LOG" | cut -c1-20)" = "$(printf 'compose stop gitea\nrun (one-off contain\ncompose start gitea')" ]
  [ "$(stat -c %a "$d/hermes-home.tar.gz")" = "600" ]
}

@test "hermes home: packed as hermes, caches and rootless docker data excluded" {
  "$BACKUP" > /dev/null
  d="$ADK_BACKUP_DIR/$(newest)"
  list="$(tar -tzf "$d/hermes-home.tar.gz")"
  grep -qx './.hermes/MEMORY.md' <<< "$list"
  grep -qx './.hermes/sessions/s1.json' <<< "$list"
  refute grep -qE 'hermes-agent|/tools/|share/uv' <<< "$list"
  grep -qx './proj/main.go' <<< "$list"
  refute grep -q '\.cache' <<< "$list"
  refute grep -q 'node_modules' <<< "$list"
  refute grep -q '\.local/share/docker' <<< "$list"
  grep -qx 'hermes' "$BATS_TEST_TMPDIR/as-user.log"
}

@test "hermes home: symlinks are stored as links, never followed" {
  "$BACKUP" > /dev/null
  d="$ADK_BACKUP_DIR/$(newest)"
  tar -tvzf "$d/hermes-home.tar.gz" ./.config/innocent | grep -q '^l'
  mkdir "$BATS_TEST_TMPDIR/x"
  tar -xzf "$d/hermes-home.tar.gz" -C "$BATS_TEST_TMPDIR/x"
  refute grep -rq 'HASH' "$BATS_TEST_TMPDIR/x"
}

@test "retention keeps 7 days and never the newest complete backup" {
  mkdir -p "$ADK_BACKUP_DIR"
  old="$(date -u -d '-9 days' +%Y%m%dT%H%M%SZ)"
  recent="$(date -u -d '-2 days' +%Y%m%dT%H%M%SZ)"
  mkdir "$ADK_BACKUP_DIR/$old" "$ADK_BACKUP_DIR/$recent" "$ADK_BACKUP_DIR/unrelated"
  run "$BACKUP"
  [ "$status" -eq 0 ]
  [ ! -e "$ADK_BACKUP_DIR/$old" ]
  [ -d "$ADK_BACKUP_DIR/$recent" ]
  [ -d "$ADK_BACKUP_DIR/unrelated" ]
}

@test "an old complete backup survives while every newer one failed" {
  mkdir -p "$ADK_BACKUP_DIR"
  old="$(date -u -d '-9 days' +%Y%m%dT%H%M%SZ)"
  mkdir "$ADK_BACKUP_DIR/$old"
  FAKE_DUMP_FAIL=1; export FAKE_DUMP_FAIL
  run "$BACKUP"
  [ "$status" -eq 1 ]
  [ -d "$ADK_BACKUP_DIR/$old" ]
}

@test "a failed gitea dump fails loudly but keeps the other parts" {
  FAKE_DUMP_FAIL=1; export FAKE_DUMP_FAIL
  run "$BACKUP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"gitea-dump"* ]]
  d="$ADK_BACKUP_DIR/$(newest)"
  grep -q '^gitea-dump' "$d/FAILED"
  [ -s "$d/adk-secrets.tar" ]
  [ -s "$d/hermes-home.tar.gz" ]
}

@test "an unreadable file in hermes's home fails the run" {
  printf 'x\n' > "$ADK_TEST_HERMES_HOME/locked"
  chmod 000 "$ADK_TEST_HERMES_HOME/locked"
  run "$BACKUP"
  chmod 600 "$ADK_TEST_HERMES_HOME/locked"
  [ "$status" -eq 1 ]
  grep -q '^hermes-home' "$ADK_BACKUP_DIR/$(newest)/FAILED"
}

@test "the MANIFEST is signed with the backup key (ssh-keygen -Y, namespace adk-backup)" {
  run "$BACKUP"
  [ "$status" -eq 0 ]
  d="$ADK_BACKUP_DIR/$(newest)"
  ssh-keygen -Y verify -f "$BATS_TEST_TMPDIR/allowed_signers" -I adk-backup -n adk-backup -s "$d/MANIFEST.sig" < "$d/MANIFEST"
  # a changed MANIFEST no longer verifies
  sed -i 's/^[0-9a-f]/0/' "$d/MANIFEST"
  run ssh-keygen -Y verify -f "$BATS_TEST_TMPDIR/allowed_signers" -I adk-backup -n adk-backup -s "$d/MANIFEST.sig" < "$d/MANIFEST"
  [ "$status" -ne 0 ]
}

@test "failed parts are recorded in the signed MANIFEST" {
  FAKE_DUMP_FAIL=1; export FAKE_DUMP_FAIL
  run "$BACKUP"
  [ "$status" -eq 1 ]
  d="$ADK_BACKUP_DIR/$(newest)"
  grep -qx 'FAILED gitea-dump' "$d/MANIFEST"
  [ -s "$d/MANIFEST.sig" ]
}

@test "without the signing key the run fails loudly" {
  rm "$ADK_BACKUP_SIGN_KEY"
  run "$BACKUP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"manifest-signature"* ]]
}

@test "gitea is started again when the dump fails" {
  FAKE_DUMP_FAIL=1; export FAKE_DUMP_FAIL
  run "$BACKUP"
  [ "$status" -eq 1 ]
  [ "$(grep -c '^compose start gitea' "$FAKE_LOG")" -eq 1 ]
}

@test "gitea cannot be stopped: no dump of a running instance, run fails" {
  FAKE_STOP_FAIL=1; export FAKE_STOP_FAIL
  run "$BACKUP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot stop gitea"* ]]
  refute grep -q '^gitea dump' "$FAKE_LOG"
}

@test "not enough free space: no backup directory, exit 1" {
  ADK_TEST_FREE_KB=1000 run "$BACKUP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not enough space"* ]]
  [ -z "$(newest)" ]
  refute grep -q 'compose stop' "$FAKE_LOG"
}

offsite_config() {
  age-keygen -o "$BATS_TEST_TMPDIR/age.key" 2> /dev/null
  recipient="$(age-keygen -y "$BATS_TEST_TMPDIR/age.key")"
  sed -i "s|^BACKUP_TARGET=.*|BACKUP_TARGET=sftp://u1@box.example.com:23/backups/adk|; s|^BACKUP_AGE_RECIPIENT=.*|BACKUP_AGE_RECIPIENT=$recipient|" "$ADK_TEST_KIT_DIR/kit.env"
  ssh-keygen -q -t ed25519 -N '' -f "$ADK_BACKUP_SSH_DIR/adk-backup"
}

@test "BACKUP_TARGET: only age-encrypted archives leave the server, with MANIFEST and signature" {
  command -v age > /dev/null || skip "age not installed"
  offsite_config
  printf '[box.example.com]:23 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl\n' > "$ADK_BACKUP_SSH_DIR/adk-backup.known_hosts"
  run "$BACKUP"
  [ "$status" -eq 0 ]
  d="$ADK_BACKUP_DIR/$(newest)"
  [ "$(find "$RSYNC_DEST" -mindepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ')" = "MANIFEST MANIFEST.sig adk-secrets.tar.age gitea-dump.tar.gz.age hermes-home.tar.gz.age " ]
  # encrypted: no plaintext secret inside, decrypts to exactly the local archive
  refute grep -rq 'CUSTOMER_IPS' "$RSYNC_DEST"
  age -d -i "$BATS_TEST_TMPDIR/age.key" -o "$BATS_TEST_TMPDIR/s.tar" "$RSYNC_DEST/adk-secrets.tar.age"
  cmp "$BATS_TEST_TMPDIR/s.tar" "$d/adk-secrets.tar"
  # pinned host key, no trust on first use, dedicated key and port, one directory per backup
  grep -q 'StrictHostKeyChecking=yes' "$RSYNC_LOG"
  grep -q "UserKnownHostsFile=$ADK_BACKUP_SSH_DIR/adk-backup.known_hosts" "$RSYNC_LOG"
  refute grep -q 'accept-new' "$RSYNC_LOG"
  grep -q -- "-i $ADK_BACKUP_SSH_DIR/adk-backup -p 23" "$RSYNC_LOG"
  grep -q "u1@box.example.com:/backups/adk/$(newest)/\$" "$RSYNC_LOG"
  # no staging directory left behind
  [ -z "$(find "$ADK_BACKUP_DIR" -maxdepth 1 -name '.offsite-*')" ]
  # the signed MANIFEST also covers the ciphertexts (checked before anything is decrypted)
  (cd "$RSYNC_DEST" && sha256sum -c --ignore-missing --quiet MANIFEST)
  [ "$(grep -cE '^[0-9a-f]{64}  [a-z-]+\.tar(\.gz)?\.age$' "$RSYNC_DEST/MANIFEST")" -eq 3 ]
  cmp "$RSYNC_DEST/MANIFEST" "$d/MANIFEST"
}

@test "BACKUP_TARGET without a pinned host key: nothing is copied, the run fails" {
  offsite_config
  run "$BACKUP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"host key of the target not pinned"* ]]
  [[ "$output" == *"--accept-backup-hostkey"* ]]
  [ ! -s "$RSYNC_LOG" ]
}

@test "BACKUP_TARGET without the ssh key: reported, nothing copied" {
  sed -i 's|^BACKUP_TARGET=.*|BACKUP_TARGET=sftp://u1@box.example.com:23/backups/adk|; s|^BACKUP_AGE_RECIPIENT=.*|BACKUP_AGE_RECIPIENT=age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p|' "$ADK_TEST_KIT_DIR/kit.env"
  run "$BACKUP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"adk-backup missing"* ]]
  [ ! -s "$RSYNC_LOG" ]
}

@test "no BACKUP_TARGET: no rsync" {
  run "$BACKUP"
  [ "$status" -eq 0 ]
  [ ! -s "$RSYNC_LOG" ]
}

@test "usage and root checks" {
  run "$BACKUP" --bogus
  [ "$status" -eq 2 ]
  run env -u ADK_AS_USER_HOOK "$BACKUP"
  [ "$status" -eq 2 ]
  run env -u ADK_BACKUP_SIGN_KEY "$BACKUP"
  [ "$status" -eq 2 ]
  [[ "$output" == *"run as root"* ]]
}

@test "MANIFEST starts with a signed header: backup <timestamp> <server name>" {
  run "$BACKUP"
  [ "$status" -eq 0 ]
  ts="$(newest)"
  [ "$(head -n 1 "$ADK_BACKUP_DIR/$ts/MANIFEST")" = "backup $ts adk-acme-agent" ]
}

@test "a dump that hangs is ended after the timeout; gitea runs again, the run fails" {
  FAKE_DUMP_SLEEP=5 ADK_TEST_DUMP_TIMEOUT=1s run "$BACKUP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"did not finish within 1s"* ]]
  grep -qx 'rm -f adk-backup-dump' "$FAKE_LOG"
  [ "$(grep -c '^compose start gitea' "$FAKE_LOG")" -eq 1 ]
  [ ! -e "$ADK_BACKUP_DIR/.gitea-stopped-by-backup" ]
}

@test "--ensure-gitea (ExecStopPost) starts gitea only if a backup stopped it" {
  run "$BACKUP" --ensure-gitea
  [ "$status" -eq 0 ]
  refute grep -q '^compose start' "$FAKE_LOG"
  # a backup killed while gitea was stopped leaves the marker
  mkdir -p "$ADK_BACKUP_DIR"
  : > "$ADK_BACKUP_DIR/.gitea-stopped-by-backup"
  run "$BACKUP" --ensure-gitea
  [ "$status" -eq 0 ]
  [ "$(grep -c '^compose start gitea' "$FAKE_LOG")" -eq 1 ]
  [ ! -e "$ADK_BACKUP_DIR/.gitea-stopped-by-backup" ]
}

@test "a killed backup run starts gitea again (signal trap)" {
  FAKE_DUMP_SLEEP=30; export FAKE_DUMP_SLEEP
  # SIGTERM to every process of the run, as systemd does when it stops the unit (timeout(1)
  # puts itself into its own process group)
  set -m
  "$BACKUP" > /dev/null 2>&1 &
  pid=$!
  set +m
  for _ in $(seq 1 50); do grep -q '^run (one-off container)' "$FAKE_LOG" && break; sleep 0.1; done
  kill -TERM -- "-$pid"
  pkill -TERM -f '^timeout --kill-after=60s' || true
  wait "$pid" || true
  [ "$(grep -c '^compose start gitea' "$FAKE_LOG")" -eq 1 ]
  [ ! -e "$ADK_BACKUP_DIR/.gitea-stopped-by-backup" ]
}

@test "adk-backup.service: --ensure-gitea after every run, bounded run time" {
  grep -qx 'ExecStopPost=/opt/adk/agent/backup.sh --ensure-gitea' "$ROOT/agent/systemd/adk-backup.service"
  grep -qE '^TimeoutStartSec=[0-9]+h$' "$ROOT/agent/systemd/adk-backup.service"
}
