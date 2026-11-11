#!/usr/bin/env bats
# Tests for agent/restore.sh: signature, checksums, archive contents, encrypted parts (no
# Docker, no root needed: the script stops before the first change when a check fails or
# --yes is missing).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RESTORE="$ROOT/agent/restore.sh"
  T="$BATS_TEST_TMPDIR"
  B="$T/20260101T033000Z"
  mkdir -p "$B" "$T/src/data" "$T/src/repos/acme/demo.git" "$T/src/secrets"
  printf 'CREATE TABLE t (x);\n' > "$T/src/gitea-db.sql"
  printf 'ref: refs/heads/main\n' > "$T/src/repos/acme/demo.git/HEAD"
  tar -C "$T/src" -czf "$B/gitea-dump.tar.gz" gitea-db.sql data repos
  printf 'k\n' > "$T/src/secrets/gitea-secret-key"
  printf 'CUSTOMER_NAME=acme\n' > "$T/src/kit.env"
  tar -C "$T/src" -cf "$B/adk-secrets.tar" secrets kit.env
  printf 'home\n' | gzip > "$B/hermes-home.tar.gz"
  ssh-keygen -q -t ed25519 -N '' -C adk-backup-sign -f "$T/sign"
  manifest
  mkdir -p "$T/bin"
  printf '#!/bin/sh\necho "docker $*" >> "%s/docker.log"\nexit 99\n' "$T" > "$T/bin/docker"
  chmod +x "$T/bin/docker"
  export PATH="$T/bin:$PATH"
}

# manifest [TS] [SERVER]: (re)write and sign MANIFEST like backup.sh (header, archives and
# their .age copies)
manifest() {
  (
    cd "$B" || exit 1
    printf 'backup %s %s\n' "${1:-20260101T033000Z}" "${2:-adk-acme-agent}"
    sha256sum -- *.tar*
  ) > "$T/MANIFEST.new"
  mv "$T/MANIFEST.new" "$B/MANIFEST"
  sign
}
sign() {
  rm -f "$B/MANIFEST.sig"
  ssh-keygen -q -Y sign -f "$T/sign" -n adk-backup "$B/MANIFEST" > /dev/null 2>&1
}

r() { "$RESTORE" --signer "$T/sign.pub" --config "$ROOT/tests/fixtures/valid.env" "$@"; }

no_docker() { [ ! -e "$T/docker.log" ]; }

refute() {
  if "$@"; then return 1; fi
}

@test "usage errors exit 2" {
  run "$RESTORE"
  [ "$status" -eq 2 ]
  run r --bogus "$B"
  [ "$status" -eq 2 ]
  run r --yes "$B" "$B"
  [ "$status" -eq 2 ]
  run r --yes "$T/missing"
  [ "$status" -eq 2 ]
  run "$RESTORE" --signer
  [ "$status" -eq 2 ]
  no_docker
}

@test "a symlinked backup directory is refused" {
  ln -s "$B" "$T/link"
  run r --yes "$T/link"
  [ "$status" -eq 2 ]
}

@test "without --yes: signature and checksums are verified, nothing is changed" {
  run r "$B"
  [ "$status" -eq 2 ]
  [[ "$output" == *"MANIFEST signature ok"* ]]
  [[ "$output" == *"checksums ok (gitea-dump)"* ]]
  [[ "$output" == *"--yes"* ]]
  no_docker
}

@test "all parts can be selected" {
  run r --gitea --secrets --hermes-home "$B"
  [ "$status" -eq 2 ]
  [[ "$output" == *"checksums ok (gitea-dump adk-secrets hermes-home)"* ]]
}

@test "missing MANIFEST or signature is refused" {
  rm "$B/MANIFEST.sig"
  run r --yes "$B"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not signed"* ]]
  rm "$B/MANIFEST"
  run r --yes "$B"
  [ "$status" -eq 1 ]
  [[ "$output" == *"MANIFEST"* ]]
  no_docker
}

@test "a MANIFEST signed by another key or changed after signing is refused" {
  ssh-keygen -q -t ed25519 -N '' -f "$T/other"
  run "$RESTORE" --signer "$T/other.pub" "$B"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not verify"* ]]
  # attacker replaces an archive and fixes up the (unsigned) checksum
  printf 'evil\n' | gzip > "$B/hermes-home.tar.gz"
  (cd "$B" && { printf 'backup 20260101T033000Z adk-acme-agent\n'; sha256sum -- *.tar*; } > MANIFEST)
  run r --hermes-home "$B"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not verify"* ]]
  no_docker
}

@test "an allowed-signers file works as --signer too" {
  printf 'adk-backup %s\n' "$(cut -d' ' -f1,2 "$T/sign.pub")" > "$T/allowed"
  run "$RESTORE" --signer "$T/allowed" "$B"
  [ "$status" -eq 2 ]
  [[ "$output" == *"signature ok"* ]]
}

@test "a modified archive is refused" {
  printf 'tampered\n' | gzip > "$B/gitea-dump.tar.gz"
  run r --yes "$B"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sha256"* ]]
  no_docker
}

@test "a part marked FAILED (in the signed MANIFEST or in FAILED) is refused, other parts are allowed" {
  printf 'FAILED gitea-dump\n' >> "$B/MANIFEST"
  sign
  run r --yes "$B"
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed in this backup"* ]]
  run r --hermes-home "$B"
  [ "$status" -eq 2 ]
  [[ "$output" == *"checksums ok (hermes-home)"* ]]
  manifest
  printf 'gitea-dump: gitea dump failed\n' > "$B/FAILED"
  run r --yes "$B"
  [ "$status" -eq 1 ]
}

@test "a missing part is refused" {
  rm "$B/hermes-home.tar.gz"
  run r --hermes-home --yes "$B"
  [ "$status" -eq 1 ]
  [[ "$output" == *"hermes-home.tar.gz is missing"* ]]
}

@test "secrets archive: symlinks and unexpected paths are refused (listing not cut short)" {
  ln -s /etc/shadow "$T/src/secrets/evil"
  tar -C "$T/src" -cf "$B/adk-secrets.tar" secrets kit.env
  manifest
  run r --secrets "$B"
  [ "$status" -eq 1 ]
  [[ "$output" == *"links or special files"* ]]
  rm "$T/src/secrets/evil"
  # many good entries first, the bad one last: no SIGPIPE shortcut skips it
  for i in $(seq 1 300); do printf 'x\n' > "$T/src/secrets/s$i"; done
  mkdir -p "$T/src/etc/cron.d"; printf 'x\n' > "$T/src/etc/cron.d/evil"
  tar -C "$T/src" -cf "$B/adk-secrets.tar" secrets kit.env etc/cron.d/evil
  manifest
  run r --secrets "$B"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unexpected paths"* ]]
  no_docker
}

@test "gitea dump with a symlink (e.g. conf/app.ini -> /etc/cron.d/x) is refused before anything runs" {
  mkdir -p "$T/src/data/conf"
  ln -s /etc/cron.d/evil "$T/src/data/conf/app.ini"
  tar -C "$T/src" -czf "$B/gitea-dump.tar.gz" gitea-db.sql data repos
  manifest
  run r --yes "$B"
  [ "$status" -eq 1 ]
  [[ "$output" == *"links or special files"* ]]
  no_docker
}

@test "gitea dump with a .. path is refused" {
  printf 'x\n' > "$T/x"
  tar -C "$T/src" -P -czf "$B/gitea-dump.tar.gz" gitea-db.sql "../x"
  tar -tzf "$B/gitea-dump.tar.gz" | grep -qx '\.\./x'
  manifest
  run r "$B"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unexpected paths"* ]]
  no_docker
}

@test "gitea dump with an absolute path is refused" {
  tar -C "$T/src" -P -czf "$B/gitea-dump.tar.gz" gitea-db.sql "$T/src/kit.env"
  manifest
  run r "$B"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unexpected paths"* ]]
  no_docker
}

@test "encrypted off-site copy: needs --age-identity, then verifies like a local backup" {
  command -v age > /dev/null || skip "age not installed"
  age-keygen -o "$T/age.key" 2> /dev/null
  for f in "$B"/*.tar*; do age -r "$(age-keygen -y "$T/age.key")" -o "$f.age" "$f"; done
  manifest
  rm "$B"/*.tar "$B"/*.tar.gz
  run r --gitea --secrets --hermes-home "$B"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--age-identity"* ]]
  run r --gitea --secrets --hermes-home --age-identity "$T/age.key" "$B"
  [ "$status" -eq 2 ]
  [[ "$output" == *"checksums ok (gitea-dump adk-secrets hermes-home)"* ]]
  # nothing decrypted next to the backup
  [ -z "$(find "$B" -name '*.tar' -o -name '*.tar.gz')" ]
}

@test "as non-root the restore stops after the checks" {
  [ "$(id -u)" -ne 0 ] || skip "runs as root"
  run r --yes "$B"
  [ "$status" -eq 1 ]
  [[ "$output" == *"run as root"* ]]
  no_docker
}

@test "the signed header must match the directory name: a renamed (older) backup is refused" {
  run r "$B"
  [ "$status" -eq 2 ]
  [[ "$output" == *"backup of adk-acme-agent from 20260101T033000Z:"*"day(s)"*"old"* ]]
  mv "$B" "$T/20991231T033000Z"
  run r "$T/20991231T033000Z"
  [ "$status" -eq 1 ]
  [[ "$output" == *"renamed"* ]]
  no_docker
}

@test "a backup of another server or without a header is refused" {
  manifest 20260101T033000Z adk-other-agent
  run r "$B"
  [ "$status" -eq 1 ]
  [[ "$output" == *"belongs to server adk-other-agent"* ]]
  (cd "$B" && sha256sum -- *.tar* > MANIFEST) && sign
  run r "$B"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no header line"* ]]
  no_docker
}

@test "encrypted copy: the ciphertext is checked against the signed MANIFEST before decrypting" {
  command -v age > /dev/null || skip "age not installed"
  age-keygen -o "$T/age.key" 2> /dev/null
  age -r "$(age-keygen -y "$T/age.key")" -o "$B/hermes-home.tar.gz.age" "$B/hermes-home.tar.gz"
  manifest
  rm "$B/hermes-home.tar.gz"
  # a different ciphertext of the same archive (age output is random): refused, not decrypted
  printf 'other\n' | gzip | age -r "$(age-keygen -y "$T/age.key")" -o "$B/hermes-home.tar.gz.age"
  run r --hermes-home --age-identity "$T/age.key" "$B"
  [ "$status" -eq 1 ]
  [[ "$output" == *"hermes-home.tar.gz.age does not match its sha256 in MANIFEST; not decrypting it"* ]]
  # a ciphertext the MANIFEST does not list at all
  grep -v '\.age$' "$B/MANIFEST" > "$T/m" && mv "$T/m" "$B/MANIFEST" && sign
  run r --hermes-home --age-identity "$T/age.key" "$B"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not listed in MANIFEST; not decrypting it"* ]]
}

@test "a backup directory others could change is verified and used as a root-only copy" {
  mkdir -m 0777 "$T/shared"
  mv "$B" "$T/shared/"
  S="$T/shared/20260101T033000Z"
  run r --gitea --secrets --hermes-home "$S"
  [ "$status" -eq 2 ]
  [[ "$output" == *"others could change it; verifying and using a root-only copy"* ]]
  [[ "$output" == *"checksums ok (gitea-dump adk-secrets hermes-home)"* ]]
  # a symlinked MANIFEST stays a symlink in the copy and is refused
  mv "$S/MANIFEST" "$T/real-manifest"
  ln -s "$T/real-manifest" "$S/MANIFEST"
  run r "$S"
  [ "$status" -eq 1 ]
  [[ "$output" == *"has no MANIFEST"* ]]
  no_docker
}

@test "a group-writable file in an otherwise private backup also leads to the copy" {
  chmod g+w "$B/hermes-home.tar.gz"
  run r --hermes-home "$B"
  [ "$status" -eq 2 ]
  [[ "$output" == *"root-only copy"* ]]
  chmod g-w "$B/hermes-home.tar.gz"
  run r --hermes-home "$B"
  [[ "$output" != *"root-only copy"* ]]
}
