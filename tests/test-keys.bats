#!/usr/bin/env bats
# shellcheck disable=SC2154  # $stderr is set by run --separate-stderr
# Tests for agent/test-deploy-key.sh and agent/test-pull-token.sh against the fake Gitea
# (tests/fixtures/fake-docker); gitea-init.sh creates the organization and the bots first.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  INIT="$ROOT/agent/gitea-init.sh"
  KEYSH="$ROOT/agent/test-deploy-key.sh"
  PULLSH="$ROOT/agent/test-pull-token.sh"
  CFG="$BATS_TEST_TMPDIR/kit.env"
  cp "$ROOT/tests/fixtures/valid.env" "$CFG"
  mkdir -p "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/hermes" "$BATS_TEST_TMPDIR/root" "$BATS_TEST_TMPDIR/secrets"
  chmod 0700 "$BATS_TEST_TMPDIR/hermes" "$BATS_TEST_TMPDIR/secrets"
  cp "$ROOT/tests/fixtures/fake-docker" "$BATS_TEST_TMPDIR/bin/docker"
  chmod +x "$BATS_TEST_TMPDIR/bin/docker"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export FAKE_STATE="$BATS_TEST_TMPDIR/state.json" FAKE_LOG="$BATS_TEST_TMPDIR/calls.log"
  : > "$FAKE_LOG"
  docker init
  export ADK_TEST_HERMES_HOME="$BATS_TEST_TMPDIR/hermes"
  export ADK_TEST_PASSWORD_FILE="$BATS_TEST_TMPDIR/root/adk-gitea-initial-password"
  export ADK_TEST_SECRETS_DIR="$BATS_TEST_TMPDIR/secrets"
  printf '#!/usr/bin/env bash\nshift\nexec "$@"\n' > "$BATS_TEST_TMPDIR/as-user"
  chmod +x "$BATS_TEST_TMPDIR/as-user"
  export ADK_AS_USER_HOOK="$BATS_TEST_TMPDIR/as-user"
  export ADK_GITEA_LOCK_DIR="$BATS_TEST_TMPDIR/run-adk"
  "$INIT" --config "$CFG" > /dev/null
  ssh-keygen -q -t ed25519 -N '' -f "$BATS_TEST_TMPDIR/hostkey"
  HOSTKEY="$(cat "$BATS_TEST_TMPDIR/hostkey.pub")"
  : > "$FAKE_LOG"
}

st() {
  python3 -I -c 'import json, sys; s = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$FAKE_STATE" "$1"
}

no_match() {
  if grep -q "$@"; then return 1; fi
}

# --- test-deploy-key.sh ---------------------------------------------------------------

@test "deploy key: created once, private key only in the secret store, public key on stdout" {
  run --separate-stderr "$KEYSH" --config "$CFG" --host 198.51.100.60 <<< "$HOSTKEY"
  [ "$status" -eq 0 ]
  key="$BATS_TEST_TMPDIR/secrets/test-deploy-key"
  [ "$(stat -c %a "$key")" = 600 ]
  # stdout: exactly the public key
  [ "$output" = "$(cat "$key.pub")" ]
  [[ "$output" == ssh-ed25519\ * ]]
  [[ "$output$stderr" != *PRIVATE* ]]
  # the organization secret holds the private key
  [ "$(st 's["org_secrets"]["TEST_DEPLOY_KEY"]')" = "$(cat "$key")" ]
  # never in an argv (the fake logs every command line, secrets masked only for tokens)
  no_match -F "$(sed -n 2p "$key")" "$FAKE_LOG"
  grep -q 'API (body from stdin config)' "$FAKE_LOG"
  # variables: host and pinned host key
  [ "$(st 's["org_variables"]["TEST_DEPLOY_HOST"]')" = "198.51.100.60" ]
  [ "$(st 's["org_variables"]["TEST_DEPLOY_KNOWN_HOSTS"]')" = "198.51.100.60 $(cut -d' ' -f1,2 <<< "$HOSTKEY")" ]
  # temporary admin token gone
  [ "$(st 'len([t for t in s["tokens"] if t["name"].startswith("adk-init-")])')" = 0 ]
}

@test "deploy key: second run changes nothing, same key" {
  "$KEYSH" --config "$CFG" --host 198.51.100.60 <<< "$HOSTKEY" > "$BATS_TEST_TMPDIR/pub1"
  : > "$FAKE_LOG"
  run --separate-stderr "$KEYSH" --config "$CFG" --host 198.51.100.60 <<< "$HOSTKEY"
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$BATS_TEST_TMPDIR/pub1")" ]
  [[ "$stderr" != *"changed:"* ]]
  no_match 'API PUT' "$FAKE_LOG"
  no_match 'API POST' "$FAKE_LOG"
}

@test "deploy key: a new host or host key updates the variables only" {
  "$KEYSH" --config "$CFG" --host 198.51.100.60 <<< "$HOSTKEY" > /dev/null
  run --separate-stderr "$KEYSH" --config "$CFG" --host test.example.com <<< "$HOSTKEY"
  [ "$status" -eq 0 ]
  [ "$(st 's["org_variables"]["TEST_DEPLOY_HOST"]')" = "test.example.com" ]
  [[ "$(st 's["org_variables"]["TEST_DEPLOY_KNOWN_HOSTS"]')" == "test.example.com ssh-ed25519 "* ]]
  [[ "$stderr" == *"ok: Actions secret TEST_DEPLOY_KEY"* ]]
}

@test "deploy key: bad host or host keys are refused before anything changes" {
  for h in "" "-oProxyCommand=x" "a b" "Host.Example.com" "198.51.100.60;id"; do
    run "$KEYSH" --config "$CFG" --host "$h" <<< "$HOSTKEY"
    [ "$status" -eq 2 ] || { echo "accepted host: $h"; return 1; }
  done
  for k in "" "not a key" "ssh-ed25519 AAAAgarbage" "command=\"x\" $HOSTKEY" "$(cat "$BATS_TEST_TMPDIR/hostkey")"; do
    run "$KEYSH" --config "$CFG" --host 198.51.100.60 <<< "$k"
    [ "$status" -ne 0 ] || { echo "accepted key: $k"; return 1; }
  done
  [ ! -e "$BATS_TEST_TMPDIR/secrets/test-deploy-key" ]
  [ "$(st 'len(s.get("org_secrets", {}))')" = 0 ]
}

# --- test-pull-token.sh ---------------------------------------------------------------

@test "pull token: read-only scopes, to a pipe only, older tokens revoked" {
  run bash -c '"$0" --config "$1" | cat' "$PULLSH" "$CFG"
  [ "$status" -eq 0 ]
  first="$(grep -E '^[0-9a-f]{40}$' <<< "$output")"
  [ -n "$first" ]
  [ "$(st '[t["scopes"] for t in s["tokens"] if t["user"] == "test-pull"]')" = "['read:repository,read:package']" ]
  sleep 1
  run bash -c '"$0" --config "$1" | cat' "$PULLSH" "$CFG"
  [ "$status" -eq 0 ]
  second="$(grep -E '^[0-9a-f]{40}$' <<< "$output")"
  [ "$first" != "$second" ]
  [ "$(st '[t["token"] for t in s["tokens"] if t["user"] == "test-pull"]')" = "['$second']" ]
  no_match -F "$second" "$FAKE_LOG"
}

@test "pull token: refused when stdout is a terminal" {
  command -v script > /dev/null || skip "script(1) not installed"
  run script -qec "$PULLSH --config $CFG" /dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"terminal"* ]]
  [ "$(st 'len([t for t in s["tokens"] if t["user"] == "test-pull"])')" = 0 ]
}
