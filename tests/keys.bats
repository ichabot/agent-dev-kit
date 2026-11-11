#!/usr/bin/env bats
# Tests for agent/add-key.sh and agent/remove-key.sh

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  ADD="$ROOT/agent/add-key.sh"
  REMOVE="$ROOT/agent/remove-key.sh"
  export ADK_AUTH_KEYS_DIR="$BATS_TEST_TMPDIR/authorized_keys"
  mkdir -p "$ADK_AUTH_KEYS_DIR"
  for k in a b; do
    ssh-keygen -q -t ed25519 -N '' -C "$k@example.com" -f "$BATS_TEST_TMPDIR/$k"
  done
}

fp() { ssh-keygen -l -f "$1" | cut -d' ' -f2; }

@test "add-key writes the key to the user's file" {
  run "$ADD" hermes "$BATS_TEST_TMPDIR/a.pub"
  [ "$status" -eq 0 ]
  [ "$(cat "$ADK_AUTH_KEYS_DIR/hermes")" = "$(cat "$BATS_TEST_TMPDIR/a.pub")" ]
  [ "$(stat -c %a "$ADK_AUTH_KEYS_DIR/hermes")" = "644" ]
  [[ "$output" == *"$(fp "$BATS_TEST_TMPDIR/a.pub")"* ]]
}

@test "add-key dedupes by key material" {
  "$ADD" hermes "$BATS_TEST_TMPDIR/a.pub"
  sed 's/a@example.com/other-comment/' "$BATS_TEST_TMPDIR/a.pub" > "$BATS_TEST_TMPDIR/a2.pub"
  run "$ADD" hermes "$BATS_TEST_TMPDIR/a2.pub"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already"* ]]
  [ "$(wc -l < "$ADK_AUTH_KEYS_DIR/hermes")" -eq 1 ]
  "$ADD" hermes "$BATS_TEST_TMPDIR/b.pub"
  [ "$(wc -l < "$ADK_AUTH_KEYS_DIR/hermes")" -eq 2 ]
}

@test "add-key refuses other users" {
  for u in root ci gitea ../hermes "hermes x" ""; do
    run "$ADD" "$u" "$BATS_TEST_TMPDIR/a.pub"
    [ "$status" -eq 2 ] || { echo "accepted user: '$u'"; return 1; }
  done
  [ -z "$(ls -A "$ADK_AUTH_KEYS_DIR")" ]
}

@test "add-key refuses invalid keys" {
  run "$ADD" hermes "$BATS_TEST_TMPDIR/a"
  [ "$status" -eq 1 ]
  printf 'ssh-ed25519 AAAAgarbage x\n' > "$BATS_TEST_TMPDIR/bad.pub"
  run "$ADD" hermes "$BATS_TEST_TMPDIR/bad.pub"
  [ "$status" -eq 1 ]
  printf 'no-pty %s' "$(cat "$BATS_TEST_TMPDIR/a.pub")" > "$BATS_TEST_TMPDIR/opt.pub"
  run "$ADD" hermes "$BATS_TEST_TMPDIR/opt.pub"
  [ "$status" -eq 1 ]
  [ ! -e "$ADK_AUTH_KEYS_DIR/hermes" ]
}

@test "add-key: missing key file is a usage error" {
  run "$ADD" hermes "$BATS_TEST_TMPDIR/nope.pub"
  [ "$status" -eq 2 ]
  run "$ADD" hermes
  [ "$status" -eq 2 ]
}

@test "remove-key removes exactly the matching key" {
  "$ADD" hermes "$BATS_TEST_TMPDIR/a.pub"
  "$ADD" hermes "$BATS_TEST_TMPDIR/b.pub"
  run "$REMOVE" hermes "$(fp "$BATS_TEST_TMPDIR/a.pub")"
  [ "$status" -eq 0 ]
  [ "$(cat "$ADK_AUTH_KEYS_DIR/hermes")" = "$(cat "$BATS_TEST_TMPDIR/b.pub")" ]
  [ "$(stat -c %a "$ADK_AUTH_KEYS_DIR/hermes")" = "644" ]
}

@test "remove-key: unknown fingerprint exits 1 and changes nothing" {
  "$ADD" hermes "$BATS_TEST_TMPDIR/a.pub"
  before="$(cat "$ADK_AUTH_KEYS_DIR/hermes")"
  run "$REMOVE" hermes "$(fp "$BATS_TEST_TMPDIR/b.pub")"
  [ "$status" -eq 1 ]
  [ "$(cat "$ADK_AUTH_KEYS_DIR/hermes")" = "$before" ]
}

@test "remove-key refuses malformed fingerprints and other users" {
  run "$REMOVE" hermes "not-a-fingerprint"
  [ "$status" -eq 2 ]
  run "$REMOVE" root "$(fp "$BATS_TEST_TMPDIR/a.pub")"
  [ "$status" -eq 2 ]
}

@test "remove-key keeps the last admin key unless --force" {
  "$ADD" adk-admin "$BATS_TEST_TMPDIR/a.pub"
  run "$REMOVE" adk-admin "$(fp "$BATS_TEST_TMPDIR/a.pub")"
  [ "$status" -eq 1 ]
  [[ "$output" == *"last"* ]]
  [ -s "$ADK_AUTH_KEYS_DIR/adk-admin" ]
  run "$REMOVE" --force adk-admin "$(fp "$BATS_TEST_TMPDIR/a.pub")"
  [ "$status" -eq 0 ]
  [ ! -s "$ADK_AUTH_KEYS_DIR/adk-admin" ]
}

@test "remove-key may empty the hermes file (access revoked)" {
  "$ADD" hermes "$BATS_TEST_TMPDIR/a.pub"
  run "$REMOVE" hermes "$(fp "$BATS_TEST_TMPDIR/a.pub")"
  [ "$status" -eq 0 ]
  [ -e "$ADK_AUTH_KEYS_DIR/hermes" ]
  [ ! -s "$ADK_AUTH_KEYS_DIR/hermes" ]
}

@test "without ADK_AUTH_KEYS_DIR non-root is refused" {
  [ "$(id -u)" -eq 0 ] && skip "running as root"
  unset ADK_AUTH_KEYS_DIR
  run "$ADD" hermes "$BATS_TEST_TMPDIR/a.pub"
  [ "$status" -eq 2 ]
  [[ "$output" == *"root"* ]]
}
