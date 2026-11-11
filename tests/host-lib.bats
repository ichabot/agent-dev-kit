#!/usr/bin/env bats
# Tests for the idempotency helpers in agent/lib/host.sh (run as the current user).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck disable=SC1091  # linted on its own (make lint)
  source "$ROOT/agent/lib/host.sh"
  OWNER="$(id -un):$(id -gn)"
  F="$BATS_TEST_TMPDIR/file"
}

@test "adk_put_file writes once, then reports ok" {
  ADK_CHANGES=0
  adk_put_file "$F" 0640 "$OWNER" <<< "hello" > /dev/null
  [ "$ADK_CHANGES" -eq 1 ]
  [ "$(cat "$F")" = "hello" ]
  [ "$(stat -c %a "$F")" = "640" ]
  run adk_put_file "$F" 0640 "$OWNER" <<< "hello"
  [ "$status" -eq 1 ]
  [[ "$output" == "ok: "* ]]
}

@test "adk_put_file fixes the mode of an unchanged file" {
  printf 'x\n' > "$F"
  chmod 0666 "$F"
  ADK_CHANGES=0
  adk_put_file "$F" 0600 "$OWNER" <<< "x" > /dev/null || true
  [ "$ADK_CHANGES" -eq 1 ]
  [ "$(stat -c %a "$F")" = "600" ]
}

@test "adk_put_block is idempotent at top and bottom" {
  printf 'case $- in *i*) ;; *) return;; esac\nalias ll=ls\n' > "$F"
  ADK_CHANGES=0
  adk_put_block "$F" "$OWNER" "top block" top <<< "export A=1" > /dev/null
  adk_put_block "$F" "$OWNER" "test block" bottom <<< "export B=2" > /dev/null
  [ "$ADK_CHANGES" -eq 2 ]
  [ "$(head -n1 "$F")" = "# >>> top block" ]
  [ "$(tail -n1 "$F")" = "# <<< test block" ]
  before="$(cat "$F")"
  ADK_CHANGES=0
  adk_put_block "$F" "$OWNER" "top block" top <<< "export A=1" > /dev/null
  adk_put_block "$F" "$OWNER" "test block" bottom <<< "export B=2" > /dev/null
  [ "$ADK_CHANGES" -eq 0 ]
  [ "$(grep -c '^# >>> test block' "$F")" -eq 1 ]
  grep -q '^alias ll=ls$' "$F"
  [ "$(cat "$F")" = "$before" ]
}

@test "adk_put_block replaces an outdated block" {
  adk_put_block "$F" "$OWNER" "m" top <<< "export A=1" > /dev/null
  adk_put_block "$F" "$OWNER" "m" top <<< "export A=2" > /dev/null
  grep -q '^export A=2$' "$F"
  [ "$(grep -c 'export A=' "$F")" -eq 1 ]
}
