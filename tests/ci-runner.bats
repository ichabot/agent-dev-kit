#!/usr/bin/env bats
# Tests for agent/lib/ci-runner.sh: per-job wipe, ephemeral registration, runner unit.
# Everything that would touch real processes, users or Gitea is replaced by shell functions;
# the real run is covered by the integration test on a VM.
# shellcheck disable=SC2034,SC2317,SC2016  # globals/stubs used by the sourced library

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck disable=SC1091  # linted on their own (make lint)
  source "$ROOT/agent/lib/host.sh"
  # shellcheck disable=SC1091
  source "$ROOT/agent/lib/versions.sh"
  # shellcheck disable=SC1091
  source "$ROOT/agent/lib/gitea-admin.sh"
  # shellcheck disable=SC1091
  source "$ROOT/agent/lib/ci-runner.sh"
  ME="$(id -un)"
  LOG="$BATS_TEST_TMPDIR/calls.log"
  : > "$LOG"
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/homes" "$T/scan"
  HOME_DIR="$T/homes/$ME"
  printf '%s:100000:65536\nother:165536:65536\n%s:300000:10\n' "$ME" "$(id -u)" > "$T/subuid"
  ADK_SUBUID_FILE="$T/subuid"
  ADK_CI_SCAN_DIRS=("$T/scan")
  ADK_CI_SCAN_PRUNE=(/proc)
}

refute() {
  if "$@"; then return 1; fi
}

@test "adk_subid_ranges: ranges of the user by name and by uid only" {
  run adk_subid_ranges "$T/subuid" "$ME" "$(id -u)"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '100000-165535\n300000-300009')" ]
  run adk_subid_ranges "$T/subuid" nobody-here 4242
  [ -z "$output" ]
}

@test "_adk_pids_in_ranges matches real or effective uid inside a range only" {
  mkdir -p "$T/bin"
  printf '#!/bin/sh\nprintf "  10 100000 100000\\n  11 1000 1000\\n  12 165535 0\\n  13 99999 99999\\n  14 0 165536\\n"\n' > "$T/bin/ps"
  chmod +x "$T/bin/ps"
  PATH="$T/bin:$PATH" run _adk_pids_in_ranges 100000-165535 1000-1000
  [ "$output" = "$(printf '10\n11\n12')" ]
}

@test "adk_ci_kill refuses to kill the calling user or root" {
  run adk_ci_kill "$ME"
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing"* ]]
  run adk_ci_kill root
  [ "$status" -ne 0 ]
}

@test "adk_ci_wipe: kills first, then deletes home, state and stray files; recreates both empty" {
  adk_user_home() { echo "$HOME_DIR"; }
  adk_ci_kill() { echo "kill $1 home-present=$([ -d "$HOME_DIR" ] && echo yes)" >> "$LOG"; }
  mkdir -p "$HOME_DIR/.config/systemd/user" "$HOME_DIR/.local/share/docker/image" "$T/state/host"
  printf '[Service]\nExecStart=/bin/evil\n' > "$HOME_DIR/.config/systemd/user/evil.service"
  printf 'evil-image\n' > "$HOME_DIR/.local/share/docker/image/tag"
  printf '{"token":"x"}\n' > "$T/state/.runner"
  printf 'left\n' > "$T/scan/planted"
  mkdir "$T/scan/dir"; printf 'x\n' > "$T/scan/dir/f"
  # a symlink in the scan dir is removed itself, its target stays
  printf 'keep\n' > "$T/target"
  ln -s "$T/target" "$T/scan/link"
  run adk_ci_wipe "$ME" "$T/state"
  [ "$status" -eq 0 ]
  [ "$(cat "$LOG")" = "kill $ME home-present=yes" ]
  [ -d "$HOME_DIR" ] && [ -z "$(ls -A "$HOME_DIR")" ]
  [ "$(stat -c %a "$HOME_DIR")" = "700" ]
  [ -d "$T/state" ] && [ -z "$(ls -A "$T/state")" ]
  [ "$(stat -c %a "$T/state")" = "700" ]
  [ -z "$(ls -A "$T/scan")" ]
  [ "$(cat "$T/target")" = "keep" ]
  refute ls -d "$T"/homes/.adk-wipe-* 2> /dev/null
}

@test "adk_ci_wipe: a symlinked state directory is removed as a link, never followed" {
  adk_user_home() { echo "$HOME_DIR"; }
  adk_ci_kill() { :; }
  mkdir -p "$HOME_DIR" "$T/elsewhere"
  printf 'keep\n' > "$T/elsewhere/file"
  ln -s "$T/elsewhere" "$T/state"
  run adk_ci_wipe "$ME" "$T/state"
  [ "$status" -eq 0 ]
  [ -d "$T/state" ] && [ ! -L "$T/state" ]
  [ "$(cat "$T/elsewhere/file")" = "keep" ]
}

@test "adk_ci_wipe stops when processes survive (nothing deleted)" {
  adk_user_home() { echo "$HOME_DIR"; }
  adk_ci_kill() { return 1; }
  mkdir -p "$HOME_DIR"
  printf 'x\n' > "$HOME_DIR/file"
  run adk_ci_wipe "$ME" "$T/state"
  [ "$status" -ne 0 ]
  [ -f "$HOME_DIR/file" ]
}

@test "adk_ci_wipe refuses odd home paths" {
  adk_ci_kill() { :; }
  adk_user_home() { echo "/"; }
  run adk_ci_wipe "$ME" "$T/state"
  [ "$status" -ne 0 ]
  adk_user_home() { echo "$T/homes/../x"; }
  run adk_ci_wipe "$ME" "$T/state"
  [ "$status" -ne 0 ]
}

@test "adk_runner_register: fresh token via stdin only, ephemeral, old registrations and tokens invalidated" {
  sql() { echo "sql $1" >> "$LOG"; case "$1" in SELECT*) echo 7 ;; esac; }
  gitea_cli() { echo "gitea_cli $*" >> "$LOG"; printf 'some banner\nREGTOKEN123\n'; }
  adk_as_user() {
    local user="$1"; shift
    echo "as $user $*" >> "$LOG"
    # the inner sh reads the token from stdin
    "$@" > /dev/null
  }
  mkdir -p "$T/bin"
  printf '#!/bin/sh\necho "runner argv: $*" >> "%s"\necho "runner env token: ${GITEA_RUNNER_REGISTRATION_TOKEN}" >> "%s"\n' "$LOG" "$LOG" > "$T/bin/gitea-runner"
  chmod +x "$T/bin/gitea-runner"
  ADK_RUNNER_BIN="$T/bin/gitea-runner" ADK_RUNNER_STATE="$T"
  run adk_runner_register git.example.com acme
  [ "$status" -eq 0 ]
  grep -q "gitea_cli actions generate-runner-token --scope acme" "$LOG"
  grep -q "runner argv: -c /etc/adk/runner.yaml register --no-interactive --ephemeral --instance https://git.example.com --name adk-acme" "$LOG"
  grep -q "runner env token: REGTOKEN123" "$LOG"
  # the token never appears in an argument list or the output
  refute grep -E '^(as|gitea_cli|sql|runner argv).*REGTOKEN123' "$LOG"
  [[ "$output" != *REGTOKEN123* ]]
  # order: old runners removed, tokens invalidated, generate, register, invalidate again
  order="$(grep -nE "^sql UPDATE action_runner SET deleted|^sql UPDATE action_runner_token|^gitea_cli actions|^runner argv" "$LOG" | cut -d: -f2- | cut -c1-40)"
  [[ "$(sed -n 1p <<< "$order")" == "sql UPDATE action_runner SET deleted"* ]]
  [[ "$(sed -n 2p <<< "$order")" == "sql UPDATE action_runner_token SET is_a"* ]]
  [[ "$(sed -n 3p <<< "$order")" == "gitea_cli actions generate-runner-token"* ]]
  [[ "$(sed -n 4p <<< "$order")" == "runner argv:"* ]]
  [[ "$(sed -n 5p <<< "$order")" == "sql UPDATE action_runner_token SET is_a"* ]]
  grep -q "WHERE repo_id = 0 AND owner_id IN (0, 7);" "$LOG"
}

@test "adk_runner_register: a failed registration still invalidates the token" {
  sql() { echo "sql $1" >> "$LOG"; case "$1" in SELECT*) echo 7 ;; esac; }
  gitea_cli() { printf 'REGTOKEN123\n'; }
  adk_as_user() { shift; "$@" > /dev/null; }
  ADK_RUNNER_BIN=/bin/false ADK_RUNNER_STATE="$T"
  run adk_runner_register git.example.com acme
  [ "$status" -ne 0 ]
  [ "$(grep -c 'UPDATE action_runner_token' "$LOG")" -eq 2 ]
}

@test "runner unit: one job per run, root wipe before and after, runs as ci" {
  run adk_runner_unit 1001
  [ "$status" -eq 0 ]
  grep -qx 'User=ci' <<< "$output"
  grep -qx 'ExecStartPre=+/opt/adk/agent/ci-reset.sh prepare' <<< "$output"
  grep -qx 'ExecStopPost=+/opt/adk/agent/ci-reset.sh wipe' <<< "$output"
  grep -qx 'ExecStart=/usr/local/bin/gitea-runner --config /etc/adk/runner.yaml daemon --once' <<< "$output"
  grep -qx 'Restart=always' <<< "$output"
  grep -qx 'Environment=DOCKER_HOST=unix:///run/user/1001/docker.sock' <<< "$output"
  grep -qx 'NoNewPrivileges=yes' <<< "$output"
  refute grep -qi 'token' <<< "$output"
}
