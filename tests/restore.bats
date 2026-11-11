#!/usr/bin/env bats
# Tests for agent/restore.sh argument and backup checks (no Docker, no root needed: the
# script stops before the first change when the checks fail or --yes is missing).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RESTORE="$ROOT/agent/restore.sh"
  B="$BATS_TEST_TMPDIR/20260101T033000Z"
  mkdir -p "$B"
  printf 'dump\n' | gzip > "$B/gitea-dump.tar.gz"
  printf 'secrets\n' > "$B/adk-secrets.tar"
  printf 'home\n' > "$B/hermes-home.tar"
  (cd "$B" && sha256sum -- *.tar* > MANIFEST)
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho "docker $*" >> "%s/docker.log"\nexit 99\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/docker"
  chmod +x "$BATS_TEST_TMPDIR/bin/docker"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

no_docker() { [ ! -e "$BATS_TEST_TMPDIR/docker.log" ]; }

@test "usage errors exit 2" {
  run "$RESTORE"
  [ "$status" -eq 2 ]
  run "$RESTORE" --bogus "$B"
  [ "$status" -eq 2 ]
  run "$RESTORE" --yes "$B" "$B"
  [ "$status" -eq 2 ]
  run "$RESTORE" --yes "$BATS_TEST_TMPDIR/missing"
  [ "$status" -eq 2 ]
  no_docker
}

@test "a symlinked backup directory is refused" {
  ln -s "$B" "$BATS_TEST_TMPDIR/link"
  run "$RESTORE" --yes "$BATS_TEST_TMPDIR/link"
  [ "$status" -eq 2 ]
}

@test "without --yes: checksums are verified, nothing is changed" {
  run "$RESTORE" "$B"
  [ "$status" -eq 2 ]
  [[ "$output" == *"checksums ok (gitea-dump)"* ]]
  [[ "$output" == *"--yes"* ]]
  no_docker
}

@test "all parts can be selected" {
  run "$RESTORE" --gitea --secrets --hermes-home "$B"
  [ "$status" -eq 2 ]
  [[ "$output" == *"checksums ok (gitea-dump adk-secrets hermes-home)"* ]]
}

@test "missing MANIFEST is refused" {
  rm "$B/MANIFEST"
  run "$RESTORE" --yes "$B"
  [ "$status" -eq 1 ]
  [[ "$output" == *"MANIFEST"* ]]
  no_docker
}

@test "a modified archive is refused" {
  printf 'tampered\n' | gzip > "$B/gitea-dump.tar.gz"
  run "$RESTORE" --yes "$B"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sha256"* ]]
  no_docker
}

@test "a part listed in FAILED is refused, other parts are allowed" {
  printf 'gitea-dump: gitea dump failed\n' > "$B/FAILED"
  run "$RESTORE" --yes "$B"
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed in this backup"* ]]
  run "$RESTORE" --hermes-home "$B"
  [ "$status" -eq 2 ]
  [[ "$output" == *"checksums ok (hermes-home)"* ]]
}

@test "a missing part is refused" {
  rm "$B/hermes-home.tar"
  run "$RESTORE" --hermes-home --yes "$B"
  [ "$status" -eq 1 ]
  [[ "$output" == *"hermes-home.tar is missing"* ]]
}

@test "as non-root the restore stops after the checks" {
  [ "$(id -u)" -ne 0 ] || skip "runs as root"
  run "$RESTORE" --yes "$B"
  [ "$status" -eq 1 ]
  [[ "$output" == *"run as root"* ]]
  no_docker
}
