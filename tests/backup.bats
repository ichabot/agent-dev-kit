#!/usr/bin/env bats
# Tests for agent/backup.sh (non-root; fake docker emulates `gitea dump`, fake rsync logs)

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BACKUP="$ROOT/agent/backup.sh"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cp "$ROOT/tests/fixtures/fake-docker" "$BATS_TEST_TMPDIR/bin/docker"
  cat > "$BATS_TEST_TMPDIR/bin/rsync" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RSYNC_LOG"
exit "${FAKE_RSYNC_RC:-0}"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/docker" "$BATS_TEST_TMPDIR/bin/rsync"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export FAKE_STATE="$BATS_TEST_TMPDIR/state.json" FAKE_LOG="$BATS_TEST_TMPDIR/calls.log"
  export RSYNC_LOG="$BATS_TEST_TMPDIR/rsync.log"
  : > "$FAKE_LOG"; : > "$RSYNC_LOG"
  docker init

  export ADK_BACKUP_DIR="$BATS_TEST_TMPDIR/backups"
  export ADK_TEST_KIT_DIR="$BATS_TEST_TMPDIR/opt-adk"
  mkdir -p "$ADK_TEST_KIT_DIR/secrets"
  cp "$ROOT/tests/fixtures/valid.env" "$ADK_TEST_KIT_DIR/kit.env"
  printf 'secret\n' > "$ADK_TEST_KIT_DIR/secrets/gitea-secret-key"

  H="$BATS_TEST_TMPDIR/hermes"
  export ADK_TEST_HERMES_HOME="$H"
  mkdir -p "$H/.hermes" "$H/.cache/pip" "$H/proj/node_modules/x" "$H/.local/share/docker/overlay2" "$H/.config"
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
  # gitea dump runs as the container user git
  grep -q '^gitea dump --type tar.gz --file - --quiet$' "$FAKE_LOG"
  [ "$(stat -c %a "$d/hermes-home.tar")" = "600" ]
}

@test "hermes home: packed as hermes, caches and rootless docker data excluded" {
  "$BACKUP" > /dev/null
  d="$ADK_BACKUP_DIR/$(newest)"
  list="$(tar -tf "$d/hermes-home.tar")"
  grep -qx './.hermes/MEMORY.md' <<< "$list"
  grep -qx './proj/main.go' <<< "$list"
  refute grep -q '\.cache' <<< "$list"
  refute grep -q 'node_modules' <<< "$list"
  refute grep -q '\.local/share/docker' <<< "$list"
  grep -qx 'hermes' "$BATS_TEST_TMPDIR/as-user.log"
}

@test "hermes home: symlinks are stored as links, never followed" {
  "$BACKUP" > /dev/null
  d="$ADK_BACKUP_DIR/$(newest)"
  tar -tvf "$d/hermes-home.tar" ./.config/innocent | grep -q '^l'
  mkdir "$BATS_TEST_TMPDIR/x"
  tar -xf "$d/hermes-home.tar" -C "$BATS_TEST_TMPDIR/x"
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
  [ -s "$d/hermes-home.tar" ]
}

@test "an unreadable file in hermes's home fails the run" {
  printf 'x\n' > "$ADK_TEST_HERMES_HOME/locked"
  chmod 000 "$ADK_TEST_HERMES_HOME/locked"
  run "$BACKUP"
  chmod 600 "$ADK_TEST_HERMES_HOME/locked"
  [ "$status" -eq 1 ]
  grep -q '^hermes-home' "$ADK_BACKUP_DIR/$(newest)/FAILED"
}

@test "BACKUP_TARGET: rsync over ssh with the dedicated key and port" {
  sed -i 's|^BACKUP_TARGET=.*|BACKUP_TARGET=sftp://u1@box.example.com:23/backups/adk|' "$ADK_TEST_KIT_DIR/kit.env"
  run "$BACKUP"
  # the key is missing in the test: reported, run fails
  [ "$status" -eq 1 ]
  [[ "$output" == *"/root/.ssh/adk-backup missing"* ]]
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
  [[ "$output" == *"run as root"* ]]
}
