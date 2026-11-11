#!/usr/bin/env bats
# Tests for the idempotency helpers in agent/lib/host.sh (run as the current user).
#
# Files in a user's home are written through adk_as_user. As non-root the user switch is
# replaced by ADK_AS_USER_HOOK, a fake that logs every call and runs it as the test user;
# the real runuser path is covered by the integration test on a VM.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck disable=SC1091  # linted on its own (make lint)
  source "$ROOT/agent/lib/host.sh"
  OWNER="$(id -un):$(id -gn)"
  ME="$(id -un)"
  F="$BATS_TEST_TMPDIR/file"
  H="$BATS_TEST_TMPDIR/home"
  mkdir -p "$H"
  HOOK_LOG="$BATS_TEST_TMPDIR/hook.log"
  : > "$HOOK_LOG"
  cat > "$BATS_TEST_TMPDIR/as-user" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$HOOK_LOG"
shift
exec "\$@"
EOF
  chmod +x "$BATS_TEST_TMPDIR/as-user"
  export ADK_AS_USER_HOOK="$BATS_TEST_TMPDIR/as-user"
  # Stand-ins for root-owned files an attacker points a symlink at.
  mkdir -p "$BATS_TEST_TMPDIR/etc-docker"
  printf '{"secret": "root-daemon-config"}\n' > "$BATS_TEST_TMPDIR/etc-docker/daemon.json"
  chmod 0600 "$BATS_TEST_TMPDIR/etc-docker/daemon.json"
  chmod 0700 "$BATS_TEST_TMPDIR/etc-docker"
  printf 'root:SECRETHASH:20000:0:99999:7:::\n' > "$BATS_TEST_TMPDIR/shadow"
  chmod 0640 "$BATS_TEST_TMPDIR/shadow"
}

# refute CMD...: fail if CMD succeeds (a bare "! cmd" does not fail a bats test)
refute() {
  if "$@"; then return 1; fi
}

# snapshot PATH...: content, mode and mtime, to prove a file was not touched
snapshot() {
  local p
  for p in "$@"; do stat -c '%n %a %Y %s' "$p"; cat "$p" 2>/dev/null || true; done
}

# --- root-owned files (adk_put_file) ------------------------------------------

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

@test "adk_put_file refuses a symlinked target" {
  ln -s "$BATS_TEST_TMPDIR/shadow" "$F"
  before="$(snapshot "$BATS_TEST_TMPDIR/shadow")"
  run adk_put_file "$F" 0644 "$OWNER" <<< "x"
  [ "$status" -ne 0 ]
  [[ "$output" == *"symlink"* ]]
  [ "$(snapshot "$BATS_TEST_TMPDIR/shadow")" = "$before" ]
}

# --- files in a user's home (written as that user) -----------------------------

@test "adk_user_put_block is idempotent at top and bottom" {
  printf 'case $- in *i*) ;; *) return;; esac\nalias ll=ls\n' > "$H/.bashrc"
  ADK_CHANGES=0
  adk_user_put_block "$ME" "$H" "$H/.bashrc" "top block" top <<< "export A=1" > /dev/null
  adk_user_put_block "$ME" "$H" "$H/.bashrc" "test block" bottom <<< "export B=2" > /dev/null
  [ "$ADK_CHANGES" -eq 2 ]
  [ "$(head -n1 "$H/.bashrc")" = "# >>> top block" ]
  [ "$(tail -n1 "$H/.bashrc")" = "# <<< test block" ]
  before="$(cat "$H/.bashrc")"
  ADK_CHANGES=0
  adk_user_put_block "$ME" "$H" "$H/.bashrc" "top block" top <<< "export A=1" > /dev/null
  adk_user_put_block "$ME" "$H" "$H/.bashrc" "test block" bottom <<< "export B=2" > /dev/null
  [ "$ADK_CHANGES" -eq 0 ]
  [ "$(grep -c '^# >>> test block' "$H/.bashrc")" -eq 1 ]
  grep -q '^alias ll=ls$' "$H/.bashrc"
  [ "$(cat "$H/.bashrc")" = "$before" ]
}

@test "adk_user_put_block replaces an outdated block and creates a missing file" {
  adk_user_put_block "$ME" "$H" "$H/.profile" "m" top <<< "export A=1" > /dev/null
  adk_user_put_block "$ME" "$H" "$H/.profile" "m" top <<< "export A=2" > /dev/null
  grep -q '^export A=2$' "$H/.profile"
  [ "$(grep -c 'export A=' "$H/.profile")" -eq 1 ]
  [ "$(stat -c %a "$H/.profile")" = "644" ]
}

@test "home reads and writes go through the user switch" {
  adk_user_mkdir "$ME" "$H" "$H/.config" 0700 > /dev/null
  adk_user_put_file "$ME" "$H" "$H/.config/x.json" 0644 <<< "{}" > /dev/null
  adk_user_put_block "$ME" "$H" "$H/.bashrc" "m" top <<< "export A=1" > /dev/null
  adk_user_test "$ME" "$H" -f "$H/.config/x.json"
  [ "$(grep -c "^$ME " "$HOOK_LOG")" -eq 4 ]
  refute grep -qv "^$ME " "$HOOK_LOG"
}

@test "adk_user_put_file writes once, fixes the mode, reports ok" {
  adk_user_mkdir "$ME" "$H" "$H/.config" 0700 > /dev/null
  ADK_CHANGES=0
  adk_user_put_file "$ME" "$H" "$H/.config/d.json" 0644 <<< "{}" > /dev/null
  [ "$ADK_CHANGES" -eq 1 ]
  chmod 0666 "$H/.config/d.json"
  adk_user_put_file "$ME" "$H" "$H/.config/d.json" 0644 <<< "{}" > /dev/null || true
  [ "$ADK_CHANGES" -eq 2 ]
  [ "$(stat -c %a "$H/.config/d.json")" = "644" ]
  run adk_user_put_file "$ME" "$H" "$H/.config/d.json" 0644 <<< "{}"
  [ "$status" -eq 1 ]
  [[ "$output" == "ok: "* ]]
}

@test "adk_user_mkdir creates with mode and fixes it later" {
  ADK_CHANGES=0
  adk_user_mkdir "$ME" "$H" "$H/.config" 0700 > /dev/null
  [ -d "$H/.config" ]
  [ "$(stat -c %a "$H/.config")" = "700" ]
  chmod 0755 "$H/.config"
  adk_user_mkdir "$ME" "$H" "$H/.config" 0700 > /dev/null || true
  [ "$(stat -c %a "$H/.config")" = "700" ]
  [ "$ADK_CHANGES" -eq 2 ]
  run adk_user_mkdir "$ME" "$H" "$H/.config" 0700
  [ "$status" -eq 1 ]
}

@test "symlinked ~/.config/docker to a root dir: refused, target neither modified nor read" {
  mkdir -p "$H/.config"
  ln -s "$BATS_TEST_TMPDIR/etc-docker" "$H/.config/docker"
  before="$(snapshot "$BATS_TEST_TMPDIR/etc-docker" "$BATS_TEST_TMPDIR/etc-docker/daemon.json")"
  run adk_user_mkdir "$ME" "$H" "$H/.config/docker" 0700
  [ "$status" -ne 0 ]
  [ "$status" -ne 1 ]
  [[ "$output" == *"symlink"* ]]
  run adk_user_put_file "$ME" "$H" "$H/.config/docker/daemon.json" 0644 <<< '{"log-driver": "x"}'
  [ "$status" -ne 0 ]
  [ "$status" -ne 1 ]
  [[ "$output" == *"symlink"* ]]
  [[ "$output" != *"root-daemon-config"* ]]
  [ "$(snapshot "$BATS_TEST_TMPDIR/etc-docker" "$BATS_TEST_TMPDIR/etc-docker/daemon.json")" = "$before" ]
}

@test "symlinked daemon.json and symlinked parent dir are refused" {
  mkdir -p "$H/.config/docker"
  ln -s "$BATS_TEST_TMPDIR/etc-docker/daemon.json" "$H/.config/docker/daemon.json"
  before="$(snapshot "$BATS_TEST_TMPDIR/etc-docker/daemon.json")"
  run adk_user_put_file "$ME" "$H" "$H/.config/docker/daemon.json" 0644 <<< '{}'
  [ "$status" -gt 1 ]
  rm -rf "$H/.config"
  ln -s "$BATS_TEST_TMPDIR/etc-docker" "$H/.config"
  run adk_user_put_file "$ME" "$H" "$H/.config/daemon.json" 0644 <<< '{}'
  [ "$status" -gt 1 ]
  run adk_user_test "$ME" "$H" -f "$H/.config/daemon.json"
  [ "$status" -gt 1 ]
  [ "$(snapshot "$BATS_TEST_TMPDIR/etc-docker/daemon.json")" = "$before" ]
}

@test "symlinked ~/.bashrc to a shadow file: refused, content not leaked" {
  ln -s "$BATS_TEST_TMPDIR/shadow" "$H/.bashrc"
  before="$(snapshot "$BATS_TEST_TMPDIR/shadow")"
  run adk_user_put_block "$ME" "$H" "$H/.bashrc" "m" top <<< "export A=1"
  [ "$status" -gt 1 ]
  [[ "$output" == *"symlink"* ]]
  [[ "$output" != *"SECRETHASH"* ]]
  [ -L "$H/.bashrc" ]
  refute grep -rqs --exclude=.bashrc SECRETHASH "$H"
  [ "$(snapshot "$BATS_TEST_TMPDIR/shadow")" = "$before" ]
}

@test "adk_user_test follows only a final symlink (as the user)" {
  mkdir -p "$H/.local/bin" "$H/.hermes/bin"
  printf '#!/bin/sh\n' > "$H/.hermes/bin/hermes"
  chmod +x "$H/.hermes/bin/hermes"
  ln -s "$H/.hermes/bin/hermes" "$H/.local/bin/hermes"
  adk_user_test "$ME" "$H" -x "$H/.local/bin/hermes"
  run adk_user_test "$ME" "$H" -x "$H/.local/bin/nothing"
  [ "$status" -eq 1 ]
}

@test "paths outside the home or with .. are refused" {
  run adk_user_put_file "$ME" "$H" "$BATS_TEST_TMPDIR/elsewhere" 0644 <<< "x"
  [ "$status" -gt 1 ]
  run adk_user_put_file "$ME" "$H" "$H/../elsewhere" 0644 <<< "x"
  [ "$status" -gt 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/elsewhere" ]
}

@test "the user helper refuses to run as root" {
  [ "$(id -u)" -eq 0 ] || skip "not root"
  run bash "$ROOT/agent/lib/user-file.sh" put "$H" "$H/x" 0644 <<< "x"
  [ "$status" -ne 0 ]
}

# --- /opt/adk check -------------------------------------------------------------

@test "adk_check_kit_tree accepts a clean tree, refuses group/other-writable entries" {
  mkdir -p "$BATS_TEST_TMPDIR/kit/agent"
  printf 'x\n' > "$BATS_TEST_TMPDIR/kit/agent/setup.sh"
  (umask 077; printf 'A=1\n' > "$BATS_TEST_TMPDIR/kit/kit.env")
  chmod -R go-w "$BATS_TEST_TMPDIR/kit"
  run adk_check_kit_tree "$BATS_TEST_TMPDIR/kit" "$ME"
  [ "$status" -eq 0 ]
  chmod g+w "$BATS_TEST_TMPDIR/kit/agent/setup.sh"
  run adk_check_kit_tree "$BATS_TEST_TMPDIR/kit" "$ME"
  [ "$status" -ne 0 ]
  [[ "$output" == *"setup.sh"* ]]
  chmod g-w "$BATS_TEST_TMPDIR/kit/agent/setup.sh"
  chmod o+w "$BATS_TEST_TMPDIR/kit/agent"
  run adk_check_kit_tree "$BATS_TEST_TMPDIR/kit" "$ME"
  [ "$status" -ne 0 ]
}

@test "adk_check_kit_tree refuses a readable kit.env and a foreign owner" {
  mkdir -p "$BATS_TEST_TMPDIR/kit"
  printf 'A=1\n' > "$BATS_TEST_TMPDIR/kit/kit.env"
  chmod 0644 "$BATS_TEST_TMPDIR/kit/kit.env"
  chmod 0755 "$BATS_TEST_TMPDIR/kit"
  run adk_check_kit_tree "$BATS_TEST_TMPDIR/kit" "$ME"
  [ "$status" -ne 0 ]
  [[ "$output" == *"kit.env"* ]]
  chmod 0600 "$BATS_TEST_TMPDIR/kit/kit.env"
  run adk_check_kit_tree "$BATS_TEST_TMPDIR/kit" "$ME"
  [ "$status" -eq 0 ]
  [ "$(id -u)" -eq 0 ] && skip "running as root"
  run adk_check_kit_tree "$BATS_TEST_TMPDIR/kit" root
  [ "$status" -ne 0 ]
}

# --- Docker apt key ---------------------------------------------------------------

@test "adk_gpg_key_fpr_is matches the primary key fingerprint only" {
  command -v gpg > /dev/null || skip "gpg not installed"
  export GNUPGHOME="$BATS_TEST_TMPDIR/gnupg"
  mkdir -m 0700 "$GNUPGHOME"
  gpg --batch -q --passphrase '' --quick-gen-key 'test <t@example.com>' ed25519 sign never 2>/dev/null
  gpg --batch -q --armor --export t@example.com > "$BATS_TEST_TMPDIR/k.asc"
  fpr="$(gpg --batch --with-colons --list-keys t@example.com | awk -F: '$1 == "fpr" {print $10; exit}')"
  [ "${#fpr}" -eq 40 ]
  adk_gpg_key_fpr_is "$BATS_TEST_TMPDIR/k.asc" "$fpr"
  refute adk_gpg_key_fpr_is "$BATS_TEST_TMPDIR/k.asc" 9DC858229FC7DD38854AE2D88D81803C0EBFCD88
  printf 'garbage\n' > "$BATS_TEST_TMPDIR/bad.asc"
  refute adk_gpg_key_fpr_is "$BATS_TEST_TMPDIR/bad.asc" "$fpr"
  refute adk_gpg_key_fpr_is "$BATS_TEST_TMPDIR/missing.asc" "$fpr"
}

# --- egress rules (nftables) -------------------------------------------------------

@test "adk_egress_rules blocks the metadata service for the given uids, gids and user sessions" {
  run adk_egress_rules "1000 1001" "1000 1001"
  [ "$status" -eq 0 ]
  [[ "$output" == *"table inet adk_egress"* ]]
  [[ "$output" == *"delete table inet adk_egress"* ]]
  [[ "$output" == *"169.254.169.254"* ]]
  [[ "$output" == *"fd00:ec2::254"* ]]
  [[ "$output" == *"hook output"* ]]
  [[ "$output" == *"meta skuid @restricted_uids jump restricted"* ]]
  [[ "$output" == *"meta skgid @restricted_gids jump restricted"* ]]
  [[ "$output" == *"ip daddr @metadata_v4 counter reject"* ]]
  [[ "$output" == *"ip6 daddr @metadata_v6 counter reject"* ]]
  run adk_egress_rules 1000 1000
  [[ "$output" == *"elements = { 1000 }"* ]]
}

@test "adk_egress_rules: subordinate id ranges are in the sets (interval sets)" {
  run adk_egress_rules "1001 1002 100000-165535 165536-231071" "1001 1002 100000-165535 165536-231071"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'flags interval' <<< "$output")" -eq 2 ]
  [ "$(grep -c 'elements = { 1001, 1002, 100000-165535, 165536-231071 }' <<< "$output")" -eq 2 ]
  grep -q 'type uid' <<< "$output"
  grep -q 'type gid' <<< "$output"
}

@test "adk_egress_rules: second layer by cgroup (all user sessions and user managers)" {
  run adk_egress_rules 1001 1001
  [[ "$output" == *'socket cgroupv2 level 1 "user.slice" jump restricted'* ]]
}

@test "adk_egress_rules keeps the uids away from root Docker containers except ports 80/443" {
  run adk_egress_rules "1001 1002" "1001"
  [ "$status" -eq 0 ]
  # published ports (Caddy) stay reachable, also after Docker's DNAT of the host address
  [[ "$output" == *'oifname "br-*" tcp dport { 80, 443 } accept'* ]]
  [[ "$output" == *'oifname "br-*" counter reject with icmpx admin-prohibited comment "root docker networks"'* ]]
  [[ "$output" == *'oifname "docker0" counter reject with icmpx admin-prohibited comment "root docker networks"'* ]]
}

@test "adk_egress_rules refuses non-numeric, root or reversed ids" {
  run adk_egress_rules hermes 1000
  [ "$status" -ne 0 ]
  run adk_egress_rules 0 1000
  [ "$status" -ne 0 ]
  run adk_egress_rules 1000 0-5
  [ "$status" -ne 0 ]
  run adk_egress_rules 200-100 1000
  [ "$status" -ne 0 ]
  run adk_egress_rules "" 1000
  [ "$status" -ne 0 ]
  run adk_egress_rules 1000
  [ "$status" -ne 0 ]
}

@test "adk_egress_rules output is accepted by nft (if available)" {
  command -v nft > /dev/null || skip "nft not installed"
  adk_egress_rules "1000 100000-165535" "1000 100000-165535" > "$BATS_TEST_TMPDIR/egress.nft"
  run nft -c -f "$BATS_TEST_TMPDIR/egress.nft"
  if [[ "$output" == *"Operation not permitted"* || "$output" == *"ermission denied"* ]]; then
    skip "nft -c needs CAP_NET_ADMIN here"
  fi
  [ "$status" -eq 0 ]
}
