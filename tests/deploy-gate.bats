#!/usr/bin/env bats
# Tests for test/deploy-gate.sh (forced command of user deploy on the TEST VM).
# Fake sudo and logger through ADK_TEST_BIN (honored only for non-root users other than deploy).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GATE="$ROOT/test/deploy-gate.sh"
  export ADK_TEST_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$ADK_TEST_BIN"
  export CALLS="$BATS_TEST_TMPDIR/calls" LOG="$BATS_TEST_TMPDIR/log"
  # shellcheck disable=SC2016  # expanded by the fake commands
  printf '#!/bin/sh\nfor a in "$@"; do printf "[%%s]" "$a"; done >> "%s"\necho >> "%s"\nexit "${FAKE_RC:-0}"\n' "$CALLS" "$CALLS" > "$ADK_TEST_BIN/sudo"
  # shellcheck disable=SC2016
  printf '#!/bin/sh\necho "$*" >> "%s"\n' "$LOG" > "$ADK_TEST_BIN/logger"
  chmod +x "$ADK_TEST_BIN/sudo" "$ADK_TEST_BIN/logger"
  SHA=0123456789abcdef0123456789abcdef01234567
}

gate() { SSH_ORIGINAL_COMMAND="$1" SSH_CLIENT="203.0.113.50 40000 22" run "$GATE"; }

@test "deploy <project> <sha> runs exactly sudo -n deploy.sh project sha" {
  gate "deploy shop $SHA"
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = "[-n][/opt/adk/test/deploy.sh][shop][$SHA]" ]
  grep -q "accepted from 203.0.113.50: deploy shop $SHA" "$LOG"
}

@test "version tags are accepted" {
  for ref in v1.2.3 v0.0.1 v10.20.30 v1.0.0-rc.1 v2.0.0-beta-2; do
    : > "$CALLS"
    gate "deploy my-app $ref"
    [ "$status" -eq 0 ] || { echo "refused: $ref"; return 1; }
    [ "$(cat "$CALLS")" = "[-n][/opt/adk/test/deploy.sh][my-app][$ref]" ]
  done
}

@test "the exit code of deploy.sh is passed on" {
  FAKE_RC=7 gate "deploy shop $SHA"
  [ "$status" -eq 7 ]
  grep -q "exit 7" "$LOG"
}

@test "everything else is refused without calling sudo" {
  nl=$'\n'
  for c in "" "id" "/bin/sh" "bash -i" "scp -t /tmp" "scp -f /etc/passwd" "internal-sftp" \
      "/usr/lib/openssh/sftp-server" "rsync --server -e.LsfxCIvu . /tmp" \
      "deploy" "deploy shop" "deploy shop $SHA extra" "deploy  shop $SHA" "deploy shop  $SHA" \
      " deploy shop $SHA" "deploy shop $SHA " "deploy shop $SHA$nl" "deploy shop $SHA${nl}id" \
      "deploy x; id" "deploy shop $SHA; id" "deploy shop $SHA && id" "deploy shop \$(id)" \
      "deploy shop \`id\`" "deploy ../x $SHA" "deploy x/../y $SHA" "deploy Shop $SHA" \
      "deploy 1shop $SHA" "deploy s $SHA" "deploy -shop $SHA" "deploy shop_x $SHA" \
      "deploy aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa $SHA" \
      "deploy shop ${SHA:0:39}" "deploy shop ${SHA}0" "deploy shop ${SHA^^}" "deploy shop main" \
      "deploy shop HEAD" "deploy shop v1.2" "deploy shop 1.2.3" "deploy shop v01.2.3" \
      "deploy shop v1.2.3+build" "deploy shop v1.2.3-" "deploy shop v1.2.3-rc/1" \
      "deploy shop v1.2.3-\$x" "Deploy shop $SHA" "deploy${nl}shop $SHA" "deploy	shop $SHA"; do
    gate "$c"
    [ "$status" -eq 2 ] || { echo "accepted: $(printf '%q' "$c")"; return 1; }
  done
  [ ! -e "$CALLS" ]
  grep -q "refused" "$LOG"
}

@test "interactive login (no SSH_ORIGINAL_COMMAND) is refused" {
  SSH_CLIENT="203.0.113.50 40000 22" run env -u SSH_ORIGINAL_COMMAND "$GATE"
  [ "$status" -eq 2 ]
  [[ "$output" == *"interactive"* ]]
  [ ! -e "$CALLS" ]
}

@test "overlong requests are refused, the log stays printable" {
  gate "deploy shop $SHA$(printf 'x%.0s' {1..300})"
  [ "$status" -eq 2 ]
  gate "deploy shop $(printf '\033[2J')$SHA"
  [ "$status" -eq 2 ]
  if grep -q $'\033' "$LOG"; then echo "raw escape in the log"; return 1; fi
}

@test "stdin of the client never reaches deploy.sh" {
  printf '#!/bin/sh\ncat > "%s"\n' "$BATS_TEST_TMPDIR/stdin" > "$ADK_TEST_BIN/sudo"
  chmod +x "$ADK_TEST_BIN/sudo"
  SSH_ORIGINAL_COMMAND="deploy shop $SHA" run "$GATE" <<< "malicious input"
  [ "$status" -eq 0 ]
  [ ! -s "$BATS_TEST_TMPDIR/stdin" ]
}
