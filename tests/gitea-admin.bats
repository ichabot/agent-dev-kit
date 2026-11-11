#!/usr/bin/env bats
# Tests for the Gitea admin lock of agent/lib/gitea-admin.sh: root-only directory, lock file
# 0600 of the caller, symlinks and foreign owners refused, the lock never reaches a child that
# runs as another user (it could keep the lock open and block every later run).
# Runs as the current user: ADK_GITEA_LOCK_DIR replaces /run/adk (honored only as non-root).
# shellcheck disable=SC2034,SC2317  # globals/stubs used by the sourced libraries

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck disable=SC1091  # linted on their own (make lint)
  source "$ROOT/agent/lib/host.sh"
  # shellcheck disable=SC1091
  source "$ROOT/agent/lib/gitea-admin.sh"
  # shellcheck disable=SC1091
  source "$ROOT/agent/lib/versions.sh"
  # shellcheck disable=SC1091
  source "$ROOT/agent/lib/ci-runner.sh"
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/run"
  ADK_GITEA_LOCK_DIR="$T/run/adk"
  LOCK="$ADK_GITEA_LOCK_DIR/gitea-admin.lock"
  ME_UID="$(id -u)"
  # a "switch to another user" that records the descriptors the child inherits
  cat > "$T/record-fds" <<EOF
#!/usr/bin/env bash
for f in /proc/\$\$/fd/*; do readlink "\$f"; done > "$T/child-fds"
shift
exec "\$@"
EOF
  chmod +x "$T/record-fds"
}

refute() {
  if "$@"; then return 1; fi
}

@test "admin lock: directory 0700 and lock file 0600 of the caller, created even under umask 022" {
  umask 022
  _adk_gitea_lock
  [ -n "$_ADK_GITEA_LOCK_FD" ]
  [ "$(stat -c '%u %a %F' "$ADK_GITEA_LOCK_DIR")" = "$ME_UID 700 directory" ]
  [ "$(stat -c '%u %a %F' "$LOCK")" = "$ME_UID 600 regular empty file" ]
  # held: a second exclusive attempt fails at once
  refute flock -n "$LOCK" true
}

@test "admin lock: the root default is forced when running as root" {
  run bash -c 'id() { if [ "$#" -eq 1 ] && [ "$1" = -u ]; then echo 0; else command id "$@"; fi; }
    ADK_GITEA_LOCK_DIR=/tmp/elsewhere
    source "$1/agent/lib/host.sh"; source "$1/agent/lib/gitea-admin.sh"
    echo "$ADK_GITEA_LOCK_DIR"' bash "$ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "/run/adk" ]
}

@test "admin lock: a symlinked directory or lock file is refused, the target untouched" {
  mkdir -p "$T/elsewhere"
  chmod 0700 "$T/elsewhere"
  ln -s "$T/elsewhere" "$ADK_GITEA_LOCK_DIR"
  run _adk_gitea_lock
  [ "$status" -ne 0 ]
  [[ "$output" == *"symlink"* ]]
  [ -z "$(ls -A "$T/elsewhere")" ]
  rm "$ADK_GITEA_LOCK_DIR"
  mkdir -m 0700 "$ADK_GITEA_LOCK_DIR"
  (umask 077; : > "$T/elsewhere/target")
  ln -s "$T/elsewhere/target" "$LOCK"
  run _adk_gitea_lock
  [ "$status" -ne 0 ]
  [[ "$output" == *"symlink"* ]]
}

@test "admin lock: a directory or lock file with a wrong mode is refused" {
  mkdir -m 0755 "$ADK_GITEA_LOCK_DIR"
  run _adk_gitea_lock
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be a directory"*"0700"* ]]
  chmod 0700 "$ADK_GITEA_LOCK_DIR"
  (umask 022; : > "$LOCK")
  run _adk_gitea_lock
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be a regular file"*"0600"* ]]
  rm "$LOCK"
  mkfifo -m 0600 "$LOCK"
  run _adk_gitea_lock
  [ "$status" -ne 0 ]
}

@test "admin lock: a directory or lock file of another owner is refused" {
  # the expected owner is the caller (root in production); pretend to be someone else
  id() { if [ "$#" -eq 1 ] && [ "$1" = -u ]; then echo 4242; else command id "$@"; fi; }
  run _adk_gitea_lock
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be a directory of"* ]]
  unset -f id
  mkdir -p "$ADK_GITEA_LOCK_DIR"
  chmod 0700 "$ADK_GITEA_LOCK_DIR"
  (umask 077; : > "$LOCK")
  # (checked on the open descriptor)
  stat() { if [[ "$*" == *"/dev/fd/"* ]]; then echo "4242 600 regular empty file"; else command stat "$@"; fi; }
  run _adk_gitea_lock
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be a regular file of"* ]]
}

@test "admin lock: the lock descriptor never reaches a child run as another user" {
  _adk_gitea_lock
  [ "$(readlink "/proc/$BASHPID/fd/$_ADK_GITEA_LOCK_FD")" = "$LOCK" ]   # (control: the script holds it)
  # adk_as_user (and everything built on it, e.g. adk_user_test / user-file.sh)
  ADK_AS_USER_HOOK="$T/record-fds"
  adk_as_user hermes true
  [ -s "$T/child-fds" ] && refute grep -qF "$LOCK" "$T/child-fds"
  rm "$T/child-fds"
  mkdir -p "$T/h/sub"
  adk_user_test hermes "$T/h" -d "$T/h/sub"
  [ -s "$T/child-fds" ] && refute grep -qF "$LOCK" "$T/child-fds"
  rm "$T/child-fds"
  # adk_user_env: runuser itself (a stub here) must not see it
  runuser() { for f in "/proc/$BASHPID/fd/"*; do readlink "$f" || true; done > "$T/child-fds"; }
  adk_user_env "$(id -un)" true
  [ -s "$T/child-fds" ] && refute grep -qF "$LOCK" "$T/child-fds"
  rm "$T/child-fds"
  # setpriv path of the CI wipe
  ADK_AS_UID_HOOK="$T/record-fds"
  _adk_as_uid ci true
  [ -s "$T/child-fds" ] && refute grep -qF "$LOCK" "$T/child-fds"
  # the script still holds the lock afterwards
  [ "$(readlink "/proc/$BASHPID/fd/$_ADK_GITEA_LOCK_FD")" = "$LOCK" ]
  refute flock -n "$LOCK" true
}
