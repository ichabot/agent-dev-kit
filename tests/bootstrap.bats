#!/usr/bin/env bats
# Tests for agent/bootstrap.sh with fake ssh and rsync (no network): what is copied, how,
# and how SSH failures are reported.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # A clean clone-like copy of the kit: the tracked files of this work tree, committed.
  K="$BATS_TEST_TMPDIR/kit"
  mkdir -p "$K"
  (cd "$ROOT" && git ls-files -z | tar --null -T - -cf -) | tar -xf - -C "$K"
  git -C "$K" init -q
  git -C "$K" add -A
  git -C "$K" -c user.name=test -c user.email=test@example.com commit -qm init
  CFG="$BATS_TEST_TMPDIR/kit.env"
  cp "$ROOT/tests/fixtures/valid.env" "$CFG"

  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  export SSH_LOG="$BATS_TEST_TMPDIR/ssh.log" RSYNC_LOG="$BATS_TEST_TMPDIR/rsync.log"
  export STAGED="$BATS_TEST_TMPDIR/staged.txt"
  : > "$SSH_LOG"; : > "$RSYNC_LOG"
  cat > "$BIN/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SSH_LOG"
case "${FAKE_SSH:-ok}" in
  hostkey)
    echo '@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@' >&2
    echo '@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @' >&2
    echo 'Host key verification failed.' >&2
    exit 255 ;;
  refused)
    echo 'ssh: connect to host 203.0.113.50 port 22: Connection refused' >&2
    exit 255 ;;
esac
exit 0
EOF
  cat > "$BIN/rsync" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RSYNC_LOG"
if [[ " $* " == *" --delete "* ]]; then
  find . -type f | sed 's|^\./||' | sort > "$STAGED"
  find . -perm /022 -print > "$STAGED.writable"
fi
exit 0
EOF
  chmod +x "$BIN/ssh" "$BIN/rsync"
  export PATH="$BIN:$PATH" ADK_SSH_WAIT=30
}

@test "copies exactly the git-tracked files of scripts/ agent/ and the tuning doc" {
  run "$K/agent/bootstrap.sh" --config "$CFG" 203.0.113.50
  [ "$status" -eq 0 ]
  expected="$(git -C "$K" ls-files -- scripts agent docs/hermes-tuning.md | sort)"
  [ -n "$expected" ]
  [ "$(cat "$STAGED")" = "$expected" ]
  main="$(grep -m1 -- ' --delete ' "$RSYNC_LOG")"
  [[ "$main" == *"--chown=root:root"* ]]
  [[ "$main" == *"--chmod=D0755,Fu+rw,Fgo-w,Fa+r,Fa+X"* ]]
  [[ "$main" == *"adk-admin@203.0.113.50:/opt/adk/" ]]
}

@test "kit.env is sent separately with mode 0600" {
  run "$K/agent/bootstrap.sh" --config "$CFG" 203.0.113.50
  [ "$status" -eq 0 ]
  env_line="$(grep -F -- "$CFG" "$RSYNC_LOG")"
  [[ "$env_line" == *"--chmod=F0600"* ]]
  [[ "$env_line" == *"--chown=root:root"* ]]
  [[ "$env_line" == *":/opt/adk/kit.env" ]]
  [ "$(grep -c -- "$CFG" "$RSYNC_LOG")" -eq 1 ]
}

@test "untracked file in agent/ aborts before anything is copied" {
  printf 'token\n' > "$K/agent/notes.txt"
  run "$K/agent/bootstrap.sh" --config "$CFG" 203.0.113.50
  [ "$status" -eq 1 ]
  [[ "$output" == *"agent/notes.txt"* ]]
  [ ! -s "$RSYNC_LOG" ]
}

@test "ignored file in scripts/ aborts before anything is copied" {
  printf 'secret\n' > "$K/scripts/lib/deploy.key"
  run "$K/agent/bootstrap.sh" --config "$CFG" 203.0.113.50
  [ "$status" -eq 1 ]
  [[ "$output" == *"deploy.key"* ]]
  [ ! -s "$RSYNC_LOG" ]
}

@test "host key mismatch fails fast with a hint" {
  ADK_SSH_WAIT=60 FAKE_SSH=hostkey run "$K/agent/bootstrap.sh" --config "$CFG" 203.0.113.50
  [ "$status" -eq 1 ]
  [[ "$output" == *"IDENTIFICATION HAS CHANGED"* ]]
  [[ "$output" == *"ssh-keygen -R 203.0.113.50"* ]]
  [ "$(wc -l < "$SSH_LOG")" -eq 1 ]
  [ ! -s "$RSYNC_LOG" ]
}

@test "SSH timeout shows the last ssh error" {
  ADK_SSH_WAIT=0 FAKE_SSH=refused run "$K/agent/bootstrap.sh" --config "$CFG" 203.0.113.50
  [ "$status" -eq 1 ]
  [[ "$output" == *"Connection refused"* ]]
  [ ! -s "$RSYNC_LOG" ]
}

@test "next step: employee key via stdin, never staged in /tmp" {
  run "$K/agent/bootstrap.sh" --config "$CFG" 203.0.113.50
  [ "$status" -eq 0 ]
  [[ "$output" == *"add-key.sh hermes < "* ]]
  [[ "$output" != *"/tmp"* ]]
}
