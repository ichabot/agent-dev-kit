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

# --- add-key: key from stdin (default) ----------------------------------------

@test "add-key reads the key from stdin" {
  run "$ADD" hermes < "$BATS_TEST_TMPDIR/a.pub"
  [ "$status" -eq 0 ]
  [ "$(cat "$ADK_AUTH_KEYS_DIR/hermes")" = "$(cat "$BATS_TEST_TMPDIR/a.pub")" ]
  [[ "$output" == *"added"* ]]
}

@test "add-key: empty or invalid stdin is refused" {
  run "$ADD" hermes < /dev/null
  [ "$status" -eq 1 ]
  run "$ADD" hermes < "$BATS_TEST_TMPDIR/a"
  [ "$status" -eq 1 ]
  [ ! -e "$ADK_AUTH_KEYS_DIR/hermes" ]
}

@test "add-key: key file in a world-writable directory is refused" {
  mkdir -m 1777 "$BATS_TEST_TMPDIR/tmp"
  cp "$BATS_TEST_TMPDIR/a.pub" "$BATS_TEST_TMPDIR/tmp/key.pub"
  run "$ADD" hermes "$BATS_TEST_TMPDIR/tmp/key.pub"
  [ "$status" -eq 2 ]
  [[ "$output" == *"world-writable"* ]]
  [ ! -e "$ADK_AUTH_KEYS_DIR/hermes" ]
}

@test "add-key: group/other-writable or symlinked key file is refused" {
  cp "$BATS_TEST_TMPDIR/a.pub" "$BATS_TEST_TMPDIR/w.pub"
  chmod 0666 "$BATS_TEST_TMPDIR/w.pub"
  run "$ADD" hermes "$BATS_TEST_TMPDIR/w.pub"
  [ "$status" -eq 2 ]
  ln -s "$BATS_TEST_TMPDIR/a.pub" "$BATS_TEST_TMPDIR/l.pub"
  run "$ADD" hermes "$BATS_TEST_TMPDIR/l.pub"
  [ "$status" -eq 2 ]
  [ ! -e "$ADK_AUTH_KEYS_DIR/hermes" ]
}

@test "add-key: existing file without trailing newline keeps both keys intact" {
  printf '%s' "$(cat "$BATS_TEST_TMPDIR/a.pub")" > "$ADK_AUTH_KEYS_DIR/hermes"
  run "$ADD" hermes < "$BATS_TEST_TMPDIR/b.pub"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$ADK_AUTH_KEYS_DIR/hermes")" -eq 2 ]
  [ "$(sed -n 1p "$ADK_AUTH_KEYS_DIR/hermes")" = "$(cat "$BATS_TEST_TMPDIR/a.pub")" ]
  [ "$(sed -n 2p "$ADK_AUTH_KEYS_DIR/hermes")" = "$(cat "$BATS_TEST_TMPDIR/b.pub")" ]
}

@test "add-key: concurrent runs lose no key (lock)" {
  for i in 1 2 3 4 5 6 7 8; do
    ssh-keygen -q -t ed25519 -N '' -C "k$i@example.com" -f "$BATS_TEST_TMPDIR/k$i"
  done
  for i in 1 2 3 4 5 6 7 8; do
    "$ADD" hermes < "$BATS_TEST_TMPDIR/k$i.pub" > /dev/null &
  done
  wait
  [ "$(wc -l < "$ADK_AUTH_KEYS_DIR/hermes")" -eq 8 ]
}

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

@test "add-key: missing key file or extra arguments are usage errors" {
  run "$ADD" hermes "$BATS_TEST_TMPDIR/nope.pub"
  [ "$status" -eq 2 ]
  run "$ADD" hermes "$BATS_TEST_TMPDIR/a.pub" extra
  [ "$status" -eq 2 ]
  run "$ADD"
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

@test "remove-key counts only valid keys as remaining admin keys" {
  "$ADD" adk-admin < "$BATS_TEST_TMPDIR/a.pub"
  printf 'not-a-key at all\n' >> "$ADK_AUTH_KEYS_DIR/adk-admin"
  run "$REMOVE" adk-admin "$(fp "$BATS_TEST_TMPDIR/a.pub")"
  [ "$status" -eq 1 ]
  [[ "$output" == *"last"* ]]
}

@test "remove-key --terminate ends the user's sessions" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  for c in loginctl systemctl; do
    # shellcheck disable=SC2016  # expanded by the fake command
    printf '#!/bin/sh\necho "%s $*" >> "%s"\n[ "$1" = show-user ] && echo yes\nexit 0\n' \
      "$c" "$BATS_TEST_TMPDIR/calls.log" > "$BATS_TEST_TMPDIR/bin/$c"
    chmod +x "$BATS_TEST_TMPDIR/bin/$c"
  done
  "$ADD" hermes < "$BATS_TEST_TMPDIR/a.pub"
  "$ADD" hermes < "$BATS_TEST_TMPDIR/b.pub"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run "$REMOVE" hermes "$(fp "$BATS_TEST_TMPDIR/b.pub")"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/calls.log" ]
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run "$REMOVE" --terminate hermes "$(fp "$BATS_TEST_TMPDIR/a.pub")"
  [ "$status" -eq 0 ]
  grep -qx "loginctl terminate-user hermes" "$BATS_TEST_TMPDIR/calls.log"
  [[ "$output" == *"crontab"* ]]
}

# --- deploy user (TEST VM): forced-command keys only ----------------------------

GATE_PREFIX='restrict,command="/opt/adk/test/deploy-gate.sh"'

@test "add-key --forced-command deploy: key line restricted to the deploy gate" {
  run "$ADD" --forced-command deploy < "$BATS_TEST_TMPDIR/a.pub"
  [ "$status" -eq 0 ]
  [ "$(cat "$ADK_AUTH_KEYS_DIR/deploy")" = "$GATE_PREFIX $(cat "$BATS_TEST_TMPDIR/a.pub")" ]
  [ "$(stat -c %a "$ADK_AUTH_KEYS_DIR/deploy")" = "644" ]
  [[ "$output" == *"$(fp "$BATS_TEST_TMPDIR/a.pub")"* ]]
}

@test "add-key: deploy without --forced-command is refused" {
  run "$ADD" deploy < "$BATS_TEST_TMPDIR/a.pub"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--forced-command"* ]]
  [ ! -e "$ADK_AUTH_KEYS_DIR/deploy" ]
}

@test "add-key: --forced-command for other users is refused" {
  for u in adk-admin hermes; do
    run "$ADD" --forced-command "$u" < "$BATS_TEST_TMPDIR/a.pub"
    [ "$status" -eq 2 ] || { echo "accepted for $u"; return 1; }
  done
  [ -z "$(ls -A "$ADK_AUTH_KEYS_DIR")" ]
}

@test "add-key: deploy key dedupe ignores the options; key options from stdin are refused" {
  "$ADD" --forced-command deploy < "$BATS_TEST_TMPDIR/a.pub"
  run "$ADD" --forced-command deploy < "$BATS_TEST_TMPDIR/a.pub"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already"* ]]
  [ "$(wc -l < "$ADK_AUTH_KEYS_DIR/deploy")" -eq 1 ]
  printf 'command="/bin/sh" %s\n' "$(cat "$BATS_TEST_TMPDIR/b.pub")" > "$BATS_TEST_TMPDIR/opt.pub"
  run "$ADD" --forced-command deploy < "$BATS_TEST_TMPDIR/opt.pub"
  [ "$status" -eq 1 ]
  [ "$(wc -l < "$ADK_AUTH_KEYS_DIR/deploy")" -eq 1 ]
}

@test "add-key: a plain hermes key does not count as present for deploy (and vice versa)" {
  "$ADD" hermes < "$BATS_TEST_TMPDIR/a.pub"
  run "$ADD" --forced-command deploy < "$BATS_TEST_TMPDIR/a.pub"
  [ "$status" -eq 0 ]
  [[ "$output" == *"added"* ]]
}

@test "remove-key removes a deploy key by fingerprint" {
  "$ADD" --forced-command deploy < "$BATS_TEST_TMPDIR/a.pub"
  "$ADD" --forced-command deploy < "$BATS_TEST_TMPDIR/b.pub"
  run "$REMOVE" deploy "$(fp "$BATS_TEST_TMPDIR/a.pub")"
  [ "$status" -eq 0 ]
  [ "$(cat "$ADK_AUTH_KEYS_DIR/deploy")" = "$GATE_PREFIX $(cat "$BATS_TEST_TMPDIR/b.pub")" ]
}
