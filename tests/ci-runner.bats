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
  # the wipe needs exactly one range per user
  printf '%s:100000:65536\nother:165536:65536\n' "$ME" > "$T/subuid1"
  printf '%s:200000:65536\n' "$ME" > "$T/subgid1"
  ADK_SUBGID_FILE="$T/subgid1"
  ADK_CI_TMP_DIRS=("$T/scan")
  ADK_CI_SPOOL_DIRS=("$T/spool/crontabs")
  ADK_CI_SCAN_DIRS=("$T/scan" "$T/elsewhere-scan")
  ADK_CI_SCAN_PRUNE=(/proc)
  mkdir -p "$T/spool/crontabs" "$T/elsewhere-scan"
  # "as the user": the test user plays user ci (no namespace, see _adk_ci_ns_delete)
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/as-uid.log"\nshift\nexec "$@"\n' "$T" > "$T/as-uid"
  chmod +x "$T/as-uid"
  export ADK_AS_UID_HOOK="$T/as-uid"
}

# wipe_stubs: no real locking, killing or IPC in tests
wipe_stubs() {
  adk_user_home() { echo "$HOME_DIR"; }
  adk_ci_lock() { echo "lock $1" >> "$LOG"; }
  adk_ci_kill() { echo "kill $1 home-present=$([ -d "$HOME_DIR" ] && echo yes) spool=$(find "$T/spool/crontabs" -mindepth 1 | wc -l)" >> "$LOG"; }
  _adk_ipc_clean() { echo "ipc $*" >> "$LOG"; }
  # (the test user, playing ci, of course has processes: bats)
  _adk_pids_in_ranges() { :; }
  ADK_SUBUID_FILE="$T/subuid1"
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

@test "adk_ci_wipe: lock, spools, kill, spools again, then deletions; home and state recreated empty" {
  wipe_stubs
  # a process that was still running writes a crontab during the kill
  adk_ci_kill() {
    echo "kill $1 home-present=$([ -d "$HOME_DIR" ] && echo yes) spool=$(find "$T/spool/crontabs" -mindepth 1 | wc -l)" >> "$LOG"
    printf '* * * * * /bin/late\n' > "$T/spool/crontabs/late"
  }
  mkdir -p "$HOME_DIR/.config/systemd/user" "$HOME_DIR/.local/share/docker/image" "$T/state/host"
  printf '[Service]\nExecStart=/bin/evil\n' > "$HOME_DIR/.config/systemd/user/evil.service"
  printf 'evil-image\n' > "$HOME_DIR/.local/share/docker/image/tag"
  printf '{"token":"x"}\n' > "$T/state/.runner"
  printf '* * * * * /bin/evil\n' > "$T/spool/crontabs/$ME"
  printf 'left\n' > "$T/scan/planted"
  mkdir "$T/scan/dir"; printf 'x\n' > "$T/scan/dir/f"
  # a symlink in the scan dir is removed itself, its target stays
  printf 'keep\n' > "$T/target"
  ln -s "$T/target" "$T/scan/link"
  run adk_ci_wipe "$ME" "$T/state"
  [ "$status" -eq 0 ]
  [ "$(cat "$LOG")" = "$(printf 'lock %s\nkill %s home-present=yes spool=0\nipc %s-%s 100000-165535' "$ME" "$ME" "$(id -u)" "$(id -u)")" ]
  [ -d "$HOME_DIR" ] && [ -z "$(ls -A "$HOME_DIR")" ]
  [ "$(stat -c %a "$HOME_DIR")" = "700" ]
  [ -d "$T/state" ] && [ -z "$(ls -A "$T/state")" ]
  [ "$(stat -c %a "$T/state")" = "700" ]
  [ -z "$(ls -A "$T/scan")" ]
  [ -z "$(ls -A "$T/spool/crontabs")" ]
  [ "$(cat "$T/target")" = "keep" ]
  # quarantine directories are root-only and empty afterwards
  [ "$(stat -c %a "$T/homes/.adk-wipe")" = "700" ] && [ -z "$(ls -A "$T/homes/.adk-wipe")" ]
  [ -z "$(ls -A "$T/.adk-wipe")" ]
}

@test "adk_ci_wipe: world-writable trees are cleaned AS the user (find -delete), never by root by name" {
  wipe_stubs
  mkdir -p "$HOME_DIR"
  printf 'x\n' > "$T/scan/f"
  run adk_ci_wipe "$ME" "$T/state"
  [ "$status" -eq 0 ]
  grep -qE "^$ME timeout --kill-after=10s 300 find $T/scan -xdev -mindepth 1 \\( -uid $(id -u) -o \\( -uid \\+99999 -uid -165536 \\) \\) -delete\$" "$T/as-uid.log"
  # no rm on single names anywhere in the library
  refute grep -nE 'rm -rf[^\n]*"\$r"|while IFS= read -r -d' "$ROOT/agent/lib/ci-runner.sh"
}

@test "adk_ci_wipe: a directory swapped for a symlink between enumeration and deletion never leads outside" {
  # Deterministic version: the switch to "the user" lists what a name-based deletion would
  # have seen, then swaps J for a symlink to a directory with the same file names, then lets
  # the deletion run. A root "rm" on the listed names (the old way) would delete outside/f*.
  wipe_stubs
  mkdir -p "$HOME_DIR" "$T/scan/H/J/sub" "$T/outside/sub"
  for i in 1 2 3; do printf 'job\n' > "$T/scan/H/J/f$i"; printf 'keep\n' > "$T/outside/f$i"; done
  printf 'job\n' > "$T/scan/H/J/sub/g"; printf 'keep\n' > "$T/outside/sub/g"
  cat > "$T/swap-hook" <<EOF
#!/bin/sh
shift
find "$T/scan" -mindepth 1 -print > "$T/enumerated"
mv -T "$T/scan/H/J" "$T/J.moved" && ln -s "$T/outside" "$T/scan/H/J"
exec "\$@"
EOF
  chmod +x "$T/swap-hook"
  ADK_AS_UID_HOOK="$T/swap-hook"
  run adk_ci_wipe "$ME" "$T/state"
  [ "$status" -eq 0 ]
  grep -qx "$T/scan/H/J/f1" "$T/enumerated"
  grep -qx "$T/scan/H/J/sub/g" "$T/enumerated"
  [ "$(cat "$T/outside/f1" "$T/outside/f2" "$T/outside/f3" "$T/outside/sub/g")" = "$(printf 'keep\nkeep\nkeep\nkeep')" ]
  # the symlink itself went away, its target stayed
  [ ! -L "$T/scan/H/J" ]
}

@test "adk_ci_wipe: a directory swapped for a symlink during the cleanup never leads outside" {
  # The attack: the agent owns /tmp/H (0777), a job puts its files into /tmp/H/J, and while
  # the wipe runs the agent swaps J for a symlink to a directory the job must not touch.
  wipe_stubs
  mkdir -p "$HOME_DIR" "$T/outside/sub"
  for i in $(seq 1 40); do printf 'keep\n' > "$T/outside/f$i"; done
  printf 'keep\n' > "$T/outside/sub/g"
  H="$T/scan/H"
  (
    while [ ! -e "$T/stop" ]; do
      mkdir -p "$H/D.$$/sub" 2> /dev/null || continue
      for i in $(seq 1 40); do : > "$H/D.$$/f$i" 2> /dev/null; done
      : > "$H/D.$$/sub/g" 2> /dev/null
      ln -sfn "$T/outside" "$H/L.$$" 2> /dev/null
      mv -T "$H/D.$$" "$H/J" 2> /dev/null
      mv -T "$H/J" "$H/old.$$" 2> /dev/null && mv -T "$H/L.$$" "$H/J" 2> /dev/null
      rm -f "$H/J" 2> /dev/null
      rm -rf "$H/old.$$" "$H/D.$$" 2> /dev/null
    done
  ) 3>&- &
  swapper=$!
  for n in $(seq 1 30); do
    adk_ci_wipe "$ME" "$T/state" > /dev/null 2>&1 || true
  done
  touch "$T/stop"
  wait "$swapper" || true
  [ "$(find "$T/outside" -type f | wc -l)" -eq 41 ]
}

@test "adk_ci_wipe: a symlink to a directory is never followed by the cleanup" {
  wipe_stubs
  mkdir -p "$HOME_DIR" "$T/outside" "$T/scan/H"
  printf 'keep\n' > "$T/outside/f"
  ln -s "$T/outside" "$T/scan/H/J"
  run adk_ci_wipe "$ME" "$T/state"
  [ "$status" -eq 0 ]
  [ "$(cat "$T/outside/f")" = "keep" ]
  [ ! -e "$T/scan/H/J" ] && [ ! -L "$T/scan/H/J" ]
}

@test "adk_ci_wipe: a symlinked state directory is removed as a link, never followed" {
  wipe_stubs
  mkdir -p "$HOME_DIR" "$T/elsewhere"
  printf 'keep\n' > "$T/elsewhere/file"
  ln -s "$T/elsewhere" "$T/state"
  run adk_ci_wipe "$ME" "$T/state"
  [ "$status" -eq 0 ]
  [ -d "$T/state" ] && [ ! -L "$T/state" ]
  [ "$(cat "$T/elsewhere/file")" = "keep" ]
}

@test "adk_ci_wipe: a spool directory an unprivileged user could change is refused" {
  wipe_stubs
  mkdir -p "$HOME_DIR" "$T/real-spool"
  printf 'x\n' > "$T/real-spool/$ME"
  ADK_CI_SPOOL_DIRS=("$T/spool/link")
  ln -s "$T/real-spool" "$T/spool/link"
  run adk_ci_wipe "$ME" "$T/state"
  [ "$status" -ne 0 ]
  [[ "$output" == *"can be changed by an unprivileged user"* ]]
  [ -f "$T/real-spool/$ME" ]
  ADK_CI_SPOOL_DIRS=("$T/ww/spool")
  mkdir -p "$T/ww/spool" && chmod 0777 "$T/ww"
  run adk_ci_wipe "$ME" "$T/state"
  [ "$status" -ne 0 ]
}

@test "adk_dir_chain_trusted: owner, group and other write, sticky bit, symlinks" {
  mkdir -p "$T/a/b" "$T/sticky/x" "$T/ww/x"
  adk_dir_chain_trusted "$T/a/b"
  adk_dir_chain_trusted /
  chmod 1777 "$T/sticky"
  adk_dir_chain_trusted "$T/sticky/x"
  chmod 0777 "$T/ww"
  refute adk_dir_chain_trusted "$T/ww/x"
  ln -s "$T/a" "$T/l"
  refute adk_dir_chain_trusted "$T/l/b"
  refute adk_dir_chain_trusted "$T/a/../a/b"
  refute adk_dir_chain_trusted "relative/path"
}

@test "adk_ci_wipe: leftovers of a crashed wipe in the quarantine directory are removed first" {
  wipe_stubs
  mkdir -p "$HOME_DIR/sub" "$T/homes/.adk-wipe/$ME.$$/x" "$T/homes/.adk-wipe/other.1"
  chmod 0700 "$T/homes/.adk-wipe"
  printf 'old\n' > "$T/homes/.adk-wipe/$ME.$$/x/f"
  printf 'new\n' > "$HOME_DIR/sub/f"
  run adk_ci_wipe "$ME" "$T/state"
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$T/homes/.adk-wipe")" ]
  [ -d "$HOME_DIR" ] && [ -z "$(ls -A "$HOME_DIR")" ]
}

@test "adk_ci_wipe: subordinate ranges that overlap another user's or contain an account are refused" {
  wipe_stubs
  mkdir -p "$HOME_DIR"
  printf 'x\n' > "$HOME_DIR/file"
  printf 'x\n' > "$T/scan/f"
  printf '%s:100000:65536\nother:150000:65536\n' "$ME" > "$T/subuid-overlap"
  ADK_SUBUID_FILE="$T/subuid-overlap"
  run adk_ci_wipe "$ME" "$T/state"
  [ "$status" -ne 0 ]
  [[ "$output" == *"overlap"* ]]
  [ -f "$HOME_DIR/file" ] && [ -f "$T/scan/f" ]
  [ ! -s "$LOG" ]
  # subgid ranges as well
  ADK_SUBUID_FILE="$T/subuid1"
  printf '%s:200000:65536\nother:265000:10\n' "$ME" > "$T/subgid-overlap"
  ADK_SUBGID_FILE="$T/subgid-overlap"
  run adk_ci_wipe "$ME" "$T/state"
  [ "$status" -ne 0 ]
  [[ "$output" == *"overlap"* ]]
  # an account whose uid lies inside the subuid range
  ADK_SUBGID_FILE="$T/subgid1"
  getent() { if [ "$*" = passwd ]; then printf 'root:x:0:0::/root:/bin/sh\nodd:x:100005:100005::/home/odd:/bin/sh\n'; else command getent "$@"; fi; }
  run adk_ci_wipe "$ME" "$T/state"
  [ "$status" -ne 0 ]
  [[ "$output" == *"100005"* ]]
  [ -f "$HOME_DIR/file" ]
}

@test "adk_ci_kill: subordinate ranges that overlap another user's are refused before any kill" {
  kill_stubs
  printf 'ci:500000:65536\nother:565535:10\n' > "$T/subuid-ci"
  run adk_ci_kill ci
  [ "$status" -ne 0 ]
  [[ "$output" == *"overlap"* ]]
  refute grep -q "as-uid" "$LOG"
}

@test "adk_ci_wipe: the cleanup of the world-writable trees has a time limit and fails closed" {
  wipe_stubs
  mkdir -p "$HOME_DIR" "$T/bin"
  printf 'x\n' > "$HOME_DIR/file"
  # a find that never ends (e.g. /tmp flooded with millions of files)
  printf '#!/bin/sh\ncase "$*" in *-delete*) exec sleep 30 ;; esac\nexec /usr/bin/find "$@"\n' > "$T/bin/find"
  chmod +x "$T/bin/find"
  ADK_CI_WIPE_TIMEOUT=1 PATH="$T/bin:$PATH" run adk_ci_wipe "$ME" "$T/state"
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not finish within 1"* ]]
  # nothing after it ran: home and state still there, nothing recreated
  [ -f "$HOME_DIR/file" ]
}

@test "ci-runner.sh: the default paths are forced when running as root" {
  run bash -c 'id() { if [ "$#" -eq 1 ] && [ "$1" = -u ]; then echo 0; else command id "$@"; fi; }
    ADK_RUNNER_STATE=/tmp/s ADK_CGROUP_ROOT=/tmp/c ADK_RUN_USER_DIR=/tmp/r ADK_SYSVIPC_DIR=/tmp/i
    ADK_RUNNER_CONFIG=/tmp/x ADK_RUNNER_BIN=/tmp/b ADK_CI_WIPE_TIMEOUT=1
    source "$1/agent/lib/host.sh"; source "$1/agent/lib/ci-runner.sh"
    echo "$ADK_RUNNER_STATE $ADK_CGROUP_ROOT $ADK_RUN_USER_DIR $ADK_SYSVIPC_DIR $ADK_RUNNER_CONFIG $ADK_RUNNER_BIN $ADK_CI_WIPE_TIMEOUT"' bash "$ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "/var/lib/adk-runner /sys/fs/cgroup /run/user /proc/sysvipc /etc/adk/runner.yaml /usr/local/bin/gitea-runner 300" ]
}

@test "adk_dir_chain_trusted: group-writable only for a system group without regular users" {
  mkdir -p "$T/g/x"
  # $T/g pretends to be group-writable by group 27 (stat stub); members from a getent stub
  stat() { if [ "${*: -1}" = "$T/g" ]; then echo "0 27 775"; else command stat "$@"; fi; }
  MEMBERS="" PRIMARY=""
  getent() {
    case "$*" in
      "group 27") printf 'grp:x:27:%s\n' "$MEMBERS" ;;
      passwd) printf 'root:x:0:0::/root:/bin/sh\nmail:x:8:8::/var/mail:/usr/sbin/nologin\n%s' "$PRIMARY" ;;
      "passwd root") echo 'root:x:0:0::/root:/bin/sh' ;;
      "passwd mail") echo 'mail:x:8:8::/var/mail:/usr/sbin/nologin' ;;
      "passwd alice") echo 'alice:x:1001:1001::/home/alice:/bin/sh' ;;
      *) return 2 ;;
    esac
  }
  # no members, or only root and system accounts: trusted
  adk_dir_chain_trusted "$T/g/x"
  MEMBERS="root,mail"
  adk_dir_chain_trusted "$T/g/x"
  # a regular user in the group (listed, or with it as primary group), or an unknown member
  MEMBERS="root,alice"
  refute adk_dir_chain_trusted "$T/g/x"
  MEMBERS="ghost"
  refute adk_dir_chain_trusted "$T/g/x"
  MEMBERS="" PRIMARY="$(printf 'bob:x:1002:27::/home/bob:/bin/sh\n')"
  refute adk_dir_chain_trusted "$T/g/x"
  # a non-system group is never trusted for group write
  MEMBERS="" PRIMARY=""
  stat() { if [ "${*: -1}" = "$T/g" ]; then echo "0 1500 775"; else command stat "$@"; fi; }
  refute adk_dir_chain_trusted "$T/g/x"
}

@test "adk_ci_wipe: files of the user elsewhere are reported, not removed by root" {
  wipe_stubs
  mkdir -p "$HOME_DIR"
  printf 'x\n' > "$T/elsewhere-scan/survivor"
  run adk_ci_wipe "$ME" "$T/state"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: a file of $ME survived the wipe"*"survivor"* ]]
  [ -f "$T/elsewhere-scan/survivor" ]
}

@test "adk_ci_wipe stops when processes survive (nothing deleted in the home)" {
  wipe_stubs
  adk_ci_kill() { return 1; }
  mkdir -p "$HOME_DIR"
  printf 'x\n' > "$HOME_DIR/file"
  run adk_ci_wipe "$ME" "$T/state"
  [ "$status" -ne 0 ]
  [ -f "$HOME_DIR/file" ]
}

@test "adk_ci_wipe refuses odd home paths" {
  wipe_stubs
  adk_user_home() { echo "/"; }
  run adk_ci_wipe "$ME" "$T/state"
  [ "$status" -ne 0 ]
  adk_user_home() { echo "$T/homes/../x"; }
  run adk_ci_wipe "$ME" "$T/state"
  [ "$status" -ne 0 ]
}

@test "_adk_ci_ns_prefix: the user is root inside, its subuids/subgids keep their numbers" {
  ADK_SUBUID_FILE="$T/subuid1"
  _adk_ci_ns_prefix "$ME"
  [ "${ADK_NS_PREFIX[*]}" = "unshare --user --map-root-user --map-users=100000:100000:65536 --map-groups=200000:200000:65536 --" ]
  [ "$ADK_NS_RANGE" = "100000-165535" ]
  # two ranges or a range below 65536 would make ids ambiguous inside
  ADK_SUBUID_FILE="$T/subuid"
  run _adk_ci_ns_prefix "$ME"
  [ "$status" -ne 0 ]
  printf '%s:1000:500\n' "$ME" > "$T/low"
  ADK_SUBUID_FILE="$T/low"
  run _adk_ci_ns_prefix "$ME"
  [ "$status" -ne 0 ]
}

# kill_stubs: adk_ci_kill against a fake user ci (uid 4242, subuids 500000-565535)
kill_stubs() {
  id() { if [ "${1:-}" = -u ] && [ "${2:-}" = ci ]; then echo 4242; else command id "$@"; fi; }
  systemctl() { echo "systemctl $*" >> "$LOG"; }
  loginctl() { echo "loginctl $*" >> "$LOG"; }
  _adk_as_uid() { echo "as-uid $*" >> "$LOG"; }
  kill() { echo "kill $*" >> "$LOG"; }
  sleep() { :; }
  ADK_CGROUP_ROOT="$T/cg"
  S="$T/cg/user.slice/user-4242.slice"
  mkdir -p "$S/user@4242.service" "$S/session-3.scope" "$S/user-runtime-dir@4242.service"
  : > "$S/user@4242.service/cgroup.kill"; : > "$S/session-3.scope/cgroup.kill"
  : > "$S/user-runtime-dir@4242.service/cgroup.kill"
  ADK_RUN_USER_DIR="$T/run-user"
  mkdir -p "$T/run-user/4242"
  mountpoint() { return 1; }
  printf 'ci:500000:65536\n' > "$T/subuid-ci"
  ADK_SUBUID_FILE="$T/subuid-ci"
}

@test "adk_ci_kill: cgroup.kill below the user slice, kill -1 as the user and as each surviving subuid; runtime dir removed; refuses self/root" {
  run adk_ci_kill "$ME"
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing"* ]]
  run adk_ci_kill root
  [ "$status" -ne 0 ]
  kill_stubs
  # (runs in command substitutions: count in a file) survivors with subuid 500001 on the first
  # look only
  _adk_uids_in_ranges() { echo x >> "$T/looks"; [ "$(wc -l < "$T/looks")" -gt 1 ] || echo 500001; }
  _adk_pids_in_ranges() { :; }
  run adk_ci_kill ci
  [ "$status" -eq 0 ]
  [ "$(cat "$S/user@4242.service/cgroup.kill")" = "1" ]
  [ "$(cat "$S/session-3.scope/cgroup.kill")" = "1" ]
  # root's helper that unmounts /run/user/UID is left alone; the runtime dir is gone afterwards
  [ ! -s "$S/user-runtime-dir@4242.service/cgroup.kill" ]
  grep -qx "systemctl stop user-runtime-dir@4242.service" "$LOG"
  [ ! -e "$T/run-user/4242" ]
  grep -qx "as-uid ci kill -s KILL -- -1" "$LOG"
  # the subuid survivor: kill -1 with its own uid (no pid list that could hit a reused pid)
  grep -qx "as-uid 500001 kill -s KILL -- -1" "$LOG"
  refute grep -q "^kill " "$LOG"
  grep -qx "systemctl stop user@4242.service" "$LOG"
}

@test "adk_ci_kill: surviving processes leave /run/user/<uid> alone" {
  kill_stubs
  _adk_uids_in_ranges() { echo 500001; }
  _adk_pids_in_ranges() { echo 999999; }
  printf 'job state\n' > "$T/run-user/4242/f"
  run adk_ci_kill ci
  [ "$status" -ne 0 ]
  [[ "$output" == *"processes of ci survive"* ]]
  [ -f "$T/run-user/4242/f" ]
  refute grep -q "user-runtime-dir@4242" "$LOG"
}

@test "_adk_uids_in_ranges: distinct real or effective uids inside the ranges" {
  mkdir -p "$T/bin"
  printf '#!/bin/sh\nprintf "100000 100000\\n1000 1000\\n165535 0\\n99999 99999\\n0 100001\\n100000 100000\\n"\n' > "$T/bin/ps"
  chmod +x "$T/bin/ps"
  PATH="$T/bin:$PATH" run _adk_uids_in_ranges 100000-165535 1000-1000
  [ "$output" = "$(printf '1000\n100000\n100001\n165535')" ]
}

@test "_adk_as_uid: a bare number runs with that uid and gid; never root" {
  unset ADK_AS_UID_HOOK
  id() { if [ "$#" -eq 1 ] && [ "$1" = -u ]; then echo 0; else command id "$@"; fi; }
  env() { echo "env $*" >> "$LOG"; }
  _adk_as_uid 500001 kill -s KILL -- -1
  grep -qE "^env -i .* setpriv --reuid=500001 --regid=500001 --clear-groups -- kill -s KILL -- -1$" "$LOG"
  run _adk_as_uid 0 true
  [ "$status" -ne 0 ]
}

@test "_adk_ipc_clean removes SysV objects owned or created by the ranges, by id" {
  mkdir -p "$T/ipc"
  {
    printf '       key      shmid perms                  size  cpid  lpid nattch   uid   gid  cuid  cgid\n'
    printf '         0         11   600                  4096   10    10      0  1001  1001  1001  1001\n'
    printf '         0         12   600                  4096   10    10      0     0     0     0     0\n'
    printf '         0         13   600                  4096   10    10      0  1000  1000 100005 100005\n'
  } > "$T/ipc/shm"
  printf '       key      semid perms      nsems   uid   gid  cuid  cgid\n         0         21   600          1 100000 100000 100000 100000\n' > "$T/ipc/sem"
  printf '       key      msqid perms      cbytes       qnum lspid lrpid   uid   gid  cuid  cgid\n         0         31   600           0          0     0     0  1000  1000  1000  1000\n' > "$T/ipc/msg"
  ipcrm() { echo "ipcrm $*" >> "$LOG"; }
  ADK_SYSVIPC_DIR="$T/ipc"
  _adk_ipc_clean 1001-1001 100000-165535
  [ "$(cat "$LOG")" = "$(printf 'ipcrm -m 11\nipcrm -m 13\nipcrm -s 21')" ]
}

@test "adk_ci_lock expires the account and drops linger; unlock reverts both" {
  usermod() { echo "usermod $*" >> "$LOG"; }
  loginctl() { echo "loginctl $*" >> "$LOG"; }
  adk_ci_lock ci
  adk_ci_unlock ci
  [ "$(cat "$LOG")" = "$(printf 'usermod -L -e 1 ci\nloginctl disable-linger ci\nusermod -e  ci\nloginctl enable-linger ci')" ]
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

@test "runner unit: bound to the egress limits, refuses to start without the table" {
  run adk_runner_unit 1001
  [ "$status" -eq 0 ]
  grep -qx 'Requires=adk-egress.service' <<< "$output"
  grep -qx 'BindsTo=adk-egress.service' <<< "$output"
  grep -qE '^After=.*adk-egress.service' <<< "$output"
  # the table check is the first start step, before prepare
  [ "$(grep -m1 '^ExecStartPre=' <<< "$output")" = "ExecStartPre=+/bin/sh -c '/usr/sbin/nft list table inet adk_egress > /dev/null'" ]
}

@test "runner unit: a run ends a little after the job timeout (wipe via ExecStopPost)" {
  run adk_runner_unit 1001
  grep -qx "RuntimeMaxSec=$ADK_RUNNER_MAX_RUNTIME" <<< "$output"
  # runner.yaml has the same job timeout, and the unit limit lies above it
  grep -qx "  timeout: $ADK_RUNNER_JOB_TIMEOUT" < <(grep -A3 '^runner:' "$ROOT/agent/render-services.sh")
  job_min=$(( ${ADK_RUNNER_JOB_TIMEOUT%h} * 60 ))
  max_min=${ADK_RUNNER_MAX_RUNTIME%min}
  [ "$max_min" -gt "$job_min" ] && [ "$max_min" -le $((job_min + 30)) ]
}

@test "ci-reset.sh drops the unit's ci environment before acting as root" {
  # The runner unit sets DOCKER_HOST/XDG_RUNTIME_DIR/HOME of user ci; ExecStartPre=+ inherits them.
  run grep -nE '^unset DOCKER_HOST DOCKER_CONTEXT DOCKER_CONFIG XDG_RUNTIME_DIR$' "$BATS_TEST_DIRNAME/../agent/ci-reset.sh"
  [ "$status" -eq 0 ]
  grep -qx 'export HOME=/root' "$BATS_TEST_DIRNAME/../agent/ci-reset.sh"
  grep -qE '^cd /( |$)' "$BATS_TEST_DIRNAME/../agent/ci-reset.sh"
  # the env reset happens before the first action (load_config / wipe / prepare)
  first_action="$(grep -nE '^(load_config|adk_ci_wipe|adk_ci_unlock|adk_ensure_rootless_docker)' "$BATS_TEST_DIRNAME/../agent/ci-reset.sh" | head -1 | cut -d: -f1)"
  unset_line="$(grep -n '^unset DOCKER_HOST' "$BATS_TEST_DIRNAME/../agent/ci-reset.sh" | cut -d: -f1)"
  [ "$unset_line" -lt "$first_action" ]
  # the job image is pulled through ci's own socket, explicitly
  grep -q 'DOCKER_HOST="unix:///run/user/$(id -u "$ADK_CI_USER")/docker.sock"' "$BATS_TEST_DIRNAME/../agent/ci-reset.sh"
}

@test "ci-reset.sh prepare re-enables the account (after the wipe, before rootless Docker)" {
  f="$BATS_TEST_DIRNAME/../agent/ci-reset.sh"
  wipe="$(grep -n '^adk_ci_wipe' "$f" | cut -d: -f1)"
  unlock="$(grep -n '^adk_ci_unlock "$ADK_CI_USER"' "$f" | cut -d: -f1)"
  docker="$(grep -n '^adk_ensure_rootless_docker' "$f" | cut -d: -f1)"
  [ "$wipe" -lt "$unlock" ] && [ "$unlock" -lt "$docker" ]
}
