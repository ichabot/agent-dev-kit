#!/usr/bin/env bats
# Tests for agent/set-secret.sh (run as non-root: ADK_SECRETS_DIR points into the test dir)

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SET="$ROOT/agent/set-secret.sh"
  export ADK_SECRETS_DIR="$BATS_TEST_TMPDIR/secrets"
  VALUE="tok-$RANDOM-$RANDOM-Zq9"
}

refute() {
  if "$@"; then return 1; fi
}

@test "stores a whitelisted secret from stdin with mode 0600 in a 0700 directory" {
  run "$SET" dns-api-token <<< "$VALUE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dns-api-token"* ]]
  [[ "$output" != *"$VALUE"* ]]
  [ "$(cat "$ADK_SECRETS_DIR/dns-api-token")" = "$VALUE" ]
  [ "$(stat -c %a "$ADK_SECRETS_DIR/dns-api-token")" = "600" ]
  [ "$(stat -c %a "$ADK_SECRETS_DIR")" = "700" ]
  # exactly the value, no trailing newline
  [ "$(stat -c %s "$ADK_SECRETS_DIR/dns-api-token")" -eq "${#VALUE}" ]
}

@test "second run with the same value reports ok, a new value replaces it" {
  "$SET" dns-api-token <<< "$VALUE" > /dev/null
  run "$SET" dns-api-token <<< "$VALUE"
  [ "$status" -eq 0 ]
  [[ "$output" == "ok: "* ]]
  run "$SET" dns-api-token <<< "new-$VALUE"
  [ "$status" -eq 0 ]
  [[ "$output" == "changed: "* ]]
  [ "$(cat "$ADK_SECRETS_DIR/dns-api-token")" = "new-$VALUE" ]
}

@test "CRLF input is accepted (token copied on Windows)" {
  run "$SET" dns-api-token < <(printf '%s\r\n' "$VALUE")
  [ "$status" -eq 0 ]
  [ "$(cat "$ADK_SECRETS_DIR/dns-api-token")" = "$VALUE" ]
}

@test "names outside the whitelist are refused" {
  for name in gitea-secret-key ../etc/passwd caddy.env "" DNS-API-TOKEN; do
    run "$SET" "$name" <<< "$VALUE"
    [ "$status" -eq 2 ]
    [[ "$output" != *"$VALUE"* ]]
  done
  [ ! -e "$ADK_SECRETS_DIR/gitea-secret-key" ]
}

@test "the value is never accepted as an argument" {
  run "$SET" dns-api-token "$VALUE"
  [ "$status" -eq 2 ]
  [[ "$output" != *"$VALUE"* ]]
  [ ! -e "$ADK_SECRETS_DIR/dns-api-token" ]
}

@test "empty, multi-line and whitespace values are refused without echoing them" {
  run "$SET" dns-api-token < /dev/null
  [ "$status" -eq 1 ]
  run "$SET" dns-api-token < <(printf '%s\n%s\n' "$VALUE" "$VALUE")
  [ "$status" -eq 1 ]
  [[ "$output" != *"$VALUE"* ]]
  run "$SET" dns-api-token <<< "a $VALUE"
  [ "$status" -eq 1 ]
  [[ "$output" != *"$VALUE"* ]]
  [ ! -e "$ADK_SECRETS_DIR/dns-api-token" ]
}

@test "a value with a single quote is refused (Caddy's env file quotes with it)" {
  run "$SET" dns-api-token <<< "ab'$VALUE"
  [ "$status" -eq 1 ]
  [[ "$output" != *"$VALUE"* ]]
  [[ "$output" == *"single quote"* ]]
  [ ! -e "$ADK_SECRETS_DIR/dns-api-token" ]
}

@test "a symlinked secret file or directory is refused" {
  mkdir -m 0700 "$ADK_SECRETS_DIR"
  printf 'keep\n' > "$BATS_TEST_TMPDIR/victim"
  ln -s "$BATS_TEST_TMPDIR/victim" "$ADK_SECRETS_DIR/dns-api-token"
  run "$SET" dns-api-token <<< "$VALUE"
  [ "$status" -ne 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/victim")" = "keep" ]
  rm -rf "$ADK_SECRETS_DIR"
  mkdir "$BATS_TEST_TMPDIR/elsewhere"
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$ADK_SECRETS_DIR"
  run "$SET" dns-api-token <<< "$VALUE"
  [ "$status" -ne 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/elsewhere/dns-api-token" ]
}

@test "a group/other-accessible secrets directory is tightened to 0700" {
  mkdir -m 0755 "$ADK_SECRETS_DIR"
  run "$SET" dns-api-token <<< "$VALUE"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$ADK_SECRETS_DIR")" = "700" ]
}

@test "usage without a name exits 2" {
  run "$SET"
  [ "$status" -eq 2 ]
  run refute test -e "$ADK_SECRETS_DIR"
  [ "$status" -eq 0 ]
}

@test "gitea-pull-token: 40 hex characters only, stored 0600" {
  run "$SET" gitea-pull-token <<< "not-a-token"
  [ "$status" -eq 1 ]
  run "$SET" gitea-pull-token <<< "0123456789abcdef0123456789abcdef0123456"
  [ "$status" -eq 1 ]
  run "$SET" gitea-pull-token <<< "0123456789abcdef0123456789abcdef01234567"
  [ "$status" -eq 0 ]
  [ "$(cat "$ADK_SECRETS_DIR/gitea-pull-token")" = "0123456789abcdef0123456789abcdef01234567" ]
  [ "$(stat -c %a "$ADK_SECRETS_DIR/gitea-pull-token")" = 600 ]
  [[ "$output" != *"0123456789abcdef"* ]]
  [[ "$output" == *"next deployment"* ]]
}
