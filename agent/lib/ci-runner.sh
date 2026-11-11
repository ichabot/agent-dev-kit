#!/usr/bin/env bash
# CI runner of the agent VPS: every job runs in a FRESH environment of user ci.
#
# adk-act-runner.service (system unit, User=ci) runs `gitea-runner daemon --once` with an
# ephemeral registration: exactly one job per process. Root steps of the same unit run around
# it (ExecStartPre=+ / ExecStopPost=+, agent/ci-reset.sh), never anything user ci controls:
#
#   wipe     expire ci's account and drop its linger (cron, at and the user manager refuse it
#            from now on), delete ci's cron/at/mail spool entries, kill every process of ci
#            and of its subordinate uids (cgroup.kill of user-<uid>.slice, kill -1 as ci and
#            as each subordinate uid that still has processes), delete the spool entries again,
#            remove its SysV IPC objects, delete its files in the world-writable trees (/tmp,
#            /var/tmp, /dev/shm, /dev/mqueue, /run/lock) AS ci inside its own user namespace
#            (time limit, fails closed), delete ci's home and the runner state directory,
#            recreate both empty
#   prepare  wipe, re-enable the account and linger, set up rootless Docker for ci again
#            (files in the home written AS ci), pull the pinned job image, register a new
#            ephemeral runner with a NEW registration token (Gitea CLI -> pipe -> environment
#            of the register process; the token is invalidated right after)
#
# Rule for the wipe: root never acts on a path name inside a tree that ci or hermes can change
# (a directory swapped for a symlink between "find" printing a name and "rm" using it would
# redirect root). World-writable trees are cleaned by ci itself (find -delete works relative to
# directory file descriptors and never follows symlinks; even a race only gets ci's rights);
# root deletes only in spool directories that no unprivileged user can change, and removes the
# home and state directory after moving them into a root-only directory.
#
# So a job cannot leave anything behind for a later job: no images or build cache, no planted
# user units, cron or at jobs, processes or IPC objects, no reusable registration. Price: base
# images are pulled per job. Not cleaned: the kernel keyrings of ci (Docker's default seccomp
# profile denies keyctl/add_key in job containers; see docs/agent-vps.md).
# Requires host.sh, rootless-user.sh, gitea-admin.sh and versions.sh sourced.

ADK_CI_USER=ci
ADK_RUNNER_CONFIG="${ADK_RUNNER_CONFIG:-/etc/adk/runner.yaml}"
ADK_RUNNER_STATE="${ADK_RUNNER_STATE:-/var/lib/adk-runner}"
ADK_RUNNER_BIN="${ADK_RUNNER_BIN:-/usr/local/bin/gitea-runner}"
ADK_SUBUID_FILE=/etc/subuid
ADK_SUBGID_FILE=/etc/subgid
# Job timeout of the runner (runner.yaml, agent/render-services.sh) and the hard limit of one
# runner run (RuntimeMaxSec of the unit, measured from the registration): a little above the
# job timeout, so a job or runner that hangs still ends in a wipe.
ADK_RUNNER_JOB_TIMEOUT=3h
ADK_RUNNER_MAX_RUNTIME=190min
# World-writable trees: files of ci and its subuids are deleted AS ci in its own namespace.
ADK_CI_TMP_DIRS=(/tmp /var/tmp /dev/shm /dev/mqueue /run/lock)
# Spools only setgid helpers or root write (crontab, at, mail): root deletes ci's entries, one
# level deep, only if no unprivileged user can change the directory or a parent of it.
ADK_CI_SPOOL_DIRS=(/var/spool/cron/crontabs /var/spool/cron/atjobs /var/spool/cron/atspool /var/mail)
# Searched afterwards (one file system each, -xdev) for anything of ci that survived: reported,
# never acted on by root.
ADK_CI_SCAN_DIRS=(/ /tmp /var/tmp /dev/shm /run)
# Never searched: not writable for ci (other homes are 0700, the kit's directories root-only),
# large, or not real files.
ADK_CI_SCAN_PRUNE=(/proc /sys /dev/pts /home /root /opt/adk /var/lib/adk /var/backups /var/lib/docker /var/lib/containerd)
ADK_CGROUP_ROOT="${ADK_CGROUP_ROOT:-/sys/fs/cgroup}"
ADK_SYSVIPC_DIR="${ADK_SYSVIPC_DIR:-/proc/sysvipc}"
ADK_RUN_USER_DIR="${ADK_RUN_USER_DIR:-/run/user}"
# Time limit (seconds) of each search in the wipe: a flooded /tmp must not stall it for ever.
# The cleanup of the world-writable trees fails closed (no next job) when it is reached.
ADK_CI_WIPE_TIMEOUT="${ADK_CI_WIPE_TIMEOUT:-300}"
# The overrides above are for tests (non-root) only: as root the defaults always apply.
if [[ "$(id -u)" -eq 0 ]]; then
  ADK_RUNNER_CONFIG=/etc/adk/runner.yaml ADK_RUNNER_STATE=/var/lib/adk-runner
  ADK_RUNNER_BIN=/usr/local/bin/gitea-runner ADK_CGROUP_ROOT=/sys/fs/cgroup
  ADK_SYSVIPC_DIR=/proc/sysvipc ADK_RUN_USER_DIR=/run/user ADK_CI_WIPE_TIMEOUT=300
fi

# _adk_pids_in_ranges RANGES...: pids whose real or effective uid lies in one of the ranges
_adk_pids_in_ranges() {
  ps -eo pid=,ruid=,euid= | awk -v r="$*" '
    BEGIN { n = split(r, a, " "); for (i = 1; i <= n; i++) { split(a[i], b, "-"); lo[i] = b[1]; hi[i] = b[2] } }
    { for (i = 1; i <= n; i++) if (($2 >= lo[i] && $2 <= hi[i]) || ($3 >= lo[i] && $3 <= hi[i])) { print $1; next } }'
}

# _adk_uids_in_ranges RANGES...: distinct real or effective uids inside the ranges of all
# processes (one per line, sorted)
_adk_uids_in_ranges() {
  ps -eo ruid=,euid= | awk -v r="$*" '
    BEGIN { n = split(r, a, " "); for (i = 1; i <= n; i++) { split(a[i], b, "-"); lo[i] = b[1]; hi[i] = b[2] } }
    { for (j = 1; j <= 2; j++) for (i = 1; i <= n; i++) if ($j >= lo[i] && $j <= hi[i]) { print $j; break } }' | sort -un
}

# _adk_ci_ranges_exclusive USER UID: USER's /etc/subuid and /etc/subgid ranges overlap no range
# of another entry, and no account (uid) or group (gid) lies inside them. The kill and the wipe
# act on every id in these ranges; an overlap would let them hit another user. Dies otherwise.
_adk_ci_ranges_exclusive() {
  local user="$1" uid="$2" kind file mine others ids r o
  for kind in uid gid; do
    if [[ "$kind" == uid ]]; then file="$ADK_SUBUID_FILE"; else file="$ADK_SUBGID_FILE"; fi
    [[ -r "$file" ]] || continue
    mine="$(adk_subid_ranges "$file" "$user" "$uid")"
    [[ -n "$mine" ]] || continue
    others="$(awk -F: -v u="$user" -v id="$uid" '!($1 == u || $1 == id) && $2 ~ /^[0-9]+$/ && $3 ~ /^[1-9][0-9]*$/ {printf "%d-%d\n", $2, $2 + $3 - 1}' "$file")"
    for r in $mine; do
      for o in $others; do
        ((${r%-*} > ${o#*-} || ${o%-*} > ${r#*-})) \
          || adk_die "the sub${kind} range $r of $user overlaps $o of another entry in $file"
      done
    done
    if [[ "$kind" == uid ]]; then ids="$(getent passwd | cut -d: -f3)"; else ids="$(getent group | cut -d: -f3)"; fi
    for o in $ids; do
      [[ "$o" =~ ^[0-9]+$ ]] || continue
      for r in $mine; do
        ((o < ${r%-*} || o > ${r#*-})) || adk_die "${kind} $o (an existing account or group) lies inside the sub${kind} range $r of $user"
      done
    done
  done
}

# _adk_as_uid USER|UID CMD...: run CMD with USER's uid and gid (a bare number: that uid and the
# same number as gid, e.g. a subordinate uid), no supplementary groups, a minimal environment,
# cwd / (setpriv: no PAM, so it also works while the account is expired). The Gitea admin lock
# is never inherited. ADK_AS_UID_HOOK replaces the switch for tests; ignored as root.
_adk_as_uid() {
  local user="$1" uid gid
  shift
  if [[ -n "${ADK_AS_UID_HOOK:-}" && "$(id -u)" -ne 0 ]]; then
    (_adk_close_private_fds && exec "$ADK_AS_UID_HOOK" "$user" "$@")
    return
  fi
  if [[ "$user" =~ ^[1-9][0-9]*$ ]]; then
    uid="$user" gid="$user"
  else
    uid="$(id -u "$user")" gid="$(id -g "$user")"
  fi
  [[ "$uid" != 0 ]] || adk_die "refusing to run a command as root through _adk_as_uid"
  (cd / && _adk_close_private_fds && env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C \
    setpriv --reuid="$uid" --regid="$gid" --clear-groups -- "$@")
}

# _adk_cgroup_kill DIR: kill every process in cgroup DIR and below at once (cgroup.kill: the
# kernel also catches processes forked meanwhile); no-op if the cgroup does not exist
_adk_cgroup_kill() {
  [[ -f "$1/cgroup.kill" ]] || return 0
  echo 1 > "$1/cgroup.kill" 2> /dev/null || true
}

# _adk_user_cgroups_kill UID: cgroup.kill of everything below user-UID.slice (user manager with
# rootless Docker and containers, session scopes) except user-runtime-dir@UID.service: that is
# root's own helper that unmounts /run/user/UID, it must finish its stop
_adk_user_cgroups_kill() {
  local cg
  for cg in "$ADK_CGROUP_ROOT/user.slice/user-$1.slice"/*/; do
    [[ -d "$cg" && "$(basename "$cg")" != user-runtime-dir@* ]] || continue
    _adk_cgroup_kill "${cg%/}"
  done
}

# _adk_runtime_dir_gone UID: /run/user/UID (a tmpfs of the user, with whatever a job put there)
# is unmounted and removed: stop user-runtime-dir@UID, and if it still exists unmount it and
# remove it (its parent /run/user belongs to root, nobody else can swap the path). Only after
# adk_ci_kill verified that no process of the user is left.
_adk_runtime_dir_gone() {
  local uid="$1" dir="$ADK_RUN_USER_DIR/$1"
  systemctl reset-failed "user-runtime-dir@$uid.service" > /dev/null 2>&1 || true
  systemctl stop "user-runtime-dir@$uid.service" > /dev/null 2>&1 || true
  [[ -e "$dir" || -L "$dir" ]] || return 0
  adk_dir_chain_trusted "$ADK_RUN_USER_DIR" || adk_die "$ADK_RUN_USER_DIR (or a parent) can be changed by an unprivileged user"
  if mountpoint -q "$dir"; then umount --lazy "$dir" || adk_die "cannot unmount $dir"; fi
  rm -rf --one-file-system -- "$dir"
  [[ ! -e "$dir" ]] || adk_die "cannot remove $dir"
}

# adk_ci_lock USER: from now on nothing of USER starts again by itself: account expired (cron,
# at and systemd's user manager check it through PAM and refuse), password locked, no linger
adk_ci_lock() {
  usermod -L -e 1 "$1" > /dev/null 2>&1 || adk_die "cannot expire the account of $1"
  loginctl disable-linger "$1" > /dev/null 2>&1 || true
}

# adk_ci_unlock USER: account valid again (no expiry date) and lingering, for the next job.
# The password stays locked: USER never had one and never logs in with one.
adk_ci_unlock() {
  usermod -e '' "$1" > /dev/null 2>&1 || adk_die "cannot re-enable the account of $1"
  loginctl enable-linger "$1" > /dev/null 2>&1 || adk_die "cannot enable linger for $1"
}

# adk_ci_kill USER: stop USER's user manager and sessions, kill all processes of USER and of
# its subordinate uids (rootless containers). Returns 1 if processes survive; /run/user/<uid> is
# touched only when none is left.
adk_ci_kill() {
  local user="$1" uid ranges uids u i
  uid="$(id -u "$user")"
  [[ "$uid" != "$(id -u)" && "$uid" != 0 ]] || adk_die "refusing to kill the processes of $user (the caller or root)"
  _adk_ci_ranges_exclusive "$user" "$uid"
  ranges="$uid-$uid $(adk_subid_ranges "$ADK_SUBUID_FILE" "$user" "$uid" | tr '\n' ' ')"
  systemctl stop "user@$uid.service" > /dev/null 2>&1 || true
  loginctl terminate-user "$user" > /dev/null 2>&1 || true
  for ((i = 0; i < 20; i++)); do
    # everything under the user's slice (user manager, rootless Docker, containers) at once,
    # then every process with USER's uid anywhere (kill -1 as USER: the kernel walks all
    # processes in one pass), then the same as each subordinate uid that still has processes
    # (never by pid: a pid can be reused between listing and kill)
    _adk_user_cgroups_kill "$uid"
    _adk_as_uid "$user" kill -s KILL -- -1 > /dev/null 2>&1 || true
    # shellcheck disable=SC2086  # one range per word
    uids="$(_adk_uids_in_ranges $ranges)"
    [[ -n "$uids" ]] || break
    for u in $uids; do
      _adk_as_uid "$u" kill -s KILL -- -1 > /dev/null 2>&1 || true
    done
    sleep 0.5
  done
  # shellcheck disable=SC2086  # one range per word
  [[ -z "$(_adk_pids_in_ranges $ranges)" ]] || { echo "ERROR: processes of $user survive: $(_adk_pids_in_ranges $ranges | tr '\n' ' ')" >&2; return 1; }
  _adk_runtime_dir_gone "$uid"
}

# _adk_ci_owner_expr UID RANGES...: find expression "owned by UID or a uid in RANGES" (array
# ADK_OWNER_EXPR)
_adk_ci_owner_expr() {
  local uid="$1" r
  shift
  ADK_OWNER_EXPR=(\( -uid "$uid")
  for r in "$@"; do
    ADK_OWNER_EXPR+=(-o \( -uid "+$((${r%-*} - 1))" -uid "-$((${r#*-} + 1))" \))
  done
  ADK_OWNER_EXPR+=(\))
}

# _adk_ci_clean_spools UID RANGES...: as root, delete the entries of UID / RANGES directly in
# ADK_CI_SPOOL_DIRS (find -delete, no names passed around); refuses directories an
# unprivileged user could change
_adk_ci_clean_spools() {
  local uid="$1" d left
  shift
  _adk_ci_owner_expr "$uid" "$@"
  for d in "${ADK_CI_SPOOL_DIRS[@]}"; do
    [[ -e "$d" || -L "$d" ]] || continue
    adk_dir_chain_trusted "$d" || adk_die "$d (or a parent) can be changed by an unprivileged user; not cleaning it as root"
    find "$d" -xdev -mindepth 1 -maxdepth 1 ! -type d "${ADK_OWNER_EXPR[@]}" -delete 2> /dev/null || true
    left="$(find "$d" -xdev -mindepth 1 -maxdepth 1 ! -type d "${ADK_OWNER_EXPR[@]}" -print -quit 2> /dev/null || true)"
    [[ -z "$left" ]] || adk_die "cannot delete $(printf '%q' "$left")"
  done
}

# _adk_ipc_clean RANGES...: remove SysV shared memory, semaphores and message queues owned or
# created by a uid in RANGES. By id, as root: only the owner, the creator or root can remove an
# object, and no process of those uids is left, so an id cannot change hands meanwhile.
_adk_ipc_clean() {
  local kind file flag id
  for kind in shm:m sem:s msg:q; do
    file="$ADK_SYSVIPC_DIR/${kind%%:*}" flag="${kind#*:}"
    [[ -r "$file" ]] || continue
    while read -r id; do
      [[ "$id" =~ ^[0-9]+$ ]] || continue
      ipcrm "-$flag" "$id" > /dev/null 2>&1 || true
    done < <(awk -v r="$*" '
      BEGIN { n = split(r, a, " "); for (i = 1; i <= n; i++) { split(a[i], b, "-"); lo[i] = b[1]; hi[i] = b[2] } }
      NR == 1 { for (i = 1; i <= NF; i++) col[$i] = i; next }
      { for (i = 1; i <= n; i++) {
          u = $col["uid"]; c = $col["cuid"]
          if ((u >= lo[i] && u <= hi[i]) || (c >= lo[i] && c <= hi[i])) { print $2; next } } }' "$file")
  done
}

# _adk_ci_ns_prefix USER: command prefix (array ADK_NS_PREFIX) that runs a command as USER in a
# new user namespace in which USER is root (0) and its subordinate uids/gids keep their
# numbers; all other ids appear as the overflow id 65534. Needs exactly one /etc/subuid and
# /etc/subgid range starting above 65535 (useradd's default), so no id is ambiguous inside.
_adk_ci_ns_prefix() {
  local user="$1" uid ur gr
  uid="$(id -u "$user")"
  ur="$(adk_subid_ranges "$ADK_SUBUID_FILE" "$user" "$uid")"
  gr="$(adk_subid_ranges "$ADK_SUBGID_FILE" "$user" "$uid")"
  [[ "$ur" =~ ^[0-9]+-[0-9]+$ && "$gr" =~ ^[0-9]+-[0-9]+$ ]] \
    || adk_die "$user needs exactly one range in $ADK_SUBUID_FILE and $ADK_SUBGID_FILE"
  ((${ur%-*} > 65535 && ${gr%-*} > 65535)) || adk_die "the subordinate ids of $user must start above 65535"
  ADK_NS_PREFIX=(unshare --user --map-root-user
    "--map-users=${ur%-*}:${ur%-*}:$((${ur#*-} - ${ur%-*} + 1))"
    "--map-groups=${gr%-*}:${gr%-*}:$((${gr#*-} - ${gr%-*} + 1))" --)
  ADK_NS_RANGE="$ur"
}

# _adk_ci_ns_delete USER DIR...: delete every file and directory of USER or its subordinate
# uids below each DIR - as USER, inside its own user namespace (there USER may delete files of
# its subuids). find -delete works relative to directory file descriptors and never follows a
# symlink; a directory swapped for a symlink meanwhile is at most removed as a link, and
# whatever happens, it happens with the rights of USER only. Each search ends after
# ADK_CI_WIPE_TIMEOUT seconds (e.g. /tmp flooded by another user); then the wipe dies: no next
# job on a state that may not be clean.
_adk_ci_ns_delete() {
  local user="$1" self=0 d rc
  shift
  _adk_ci_ns_prefix "$user"
  if [[ -n "${ADK_AS_UID_HOOK:-}" && "$(id -u)" -ne 0 ]]; then
    ADK_NS_PREFIX=()   # tests: no namespace, the test user plays USER
    self="$(id -u)"
  fi
  _adk_ci_owner_expr "$self" "$ADK_NS_RANGE"
  for d in "$@"; do
    [[ -d "$d" && ! -L "$d" ]] || continue
    rc=0
    _adk_as_uid "$user" timeout --kill-after=10s "$ADK_CI_WIPE_TIMEOUT" "${ADK_NS_PREFIX[@]}" \
      find "$d" -xdev -mindepth 1 "${ADK_OWNER_EXPR[@]}" -delete 2> /dev/null || rc=$?
    ((rc != 124 && rc != 137)) || adk_die "the cleanup of $d did not finish within ${ADK_CI_WIPE_TIMEOUT}s; not starting another job"
  done
}

# _adk_rm_quarantined PATH: move PATH (a home or state directory of the user) into a root-only
# directory next to it, so no unprivileged user can reach the tree by path any more, then
# remove it with rm -rf (works through directory file descriptors, never follows symlinks,
# stays on the file system)
_adk_rm_quarantined() {
  local path="$1" parent q
  [[ -e "$path" || -L "$path" ]] || return 0
  parent="$(dirname "$path")"
  adk_dir_chain_trusted "$parent" || adk_die "$parent (or a parent of it) can be changed by an unprivileged user"
  q="$parent/.adk-wipe"
  [[ ! -L "$q" ]] || adk_die "$q is a symlink"
  install -d -m 0700 "$q"
  [[ "$(stat -c '%u %a' "$q")" == "$(id -u) 700" ]] || adk_die "$q must be a directory of $(id -un) with mode 0700"
  # leftovers of a crashed run (only root can reach them: the directory is root-only)
  find "$q" -mindepth 1 -maxdepth 1 -exec rm -rf --one-file-system -- {} + 2> /dev/null || true
  [[ -z "$(ls -A "$q")" ]] || adk_die "cannot empty $q"
  mv -T -- "$path" "$q/$(basename "$path").$$"
  rm -rf --one-file-system -- "${q:?}/$(basename "$path").$$"
}

# adk_ci_wipe USER STATE_DIR: lock USER (adk_ci_lock), clean its spool entries, kill
# (adk_ci_kill), remove its IPC objects and its files in ADK_CI_TMP_DIRS (as USER), delete its
# home and STATE_DIR, report any file of USER that survived elsewhere, recreate home and
# STATE_DIR empty (USER, 0700).
adk_ci_wipe() {
  local user="$1" state="$2" uid home ranges=() prune=() p left rc
  uid="$(id -u "$user")"
  home="$(adk_user_home "$user")"
  [[ "$home" == /?*/?* && "$home" != *//* && "$home" != */./* && "$home" != */../* ]] || adk_die "unexpected home of $user: $home"
  [[ "$state" == /?*/?* && "$state" != *//* && "$state" != */./* && "$state" != */../* ]] || adk_die "unexpected state directory: $state"
  _adk_ci_ranges_exclusive "$user" "$uid"
  mapfile -t ranges < <(adk_subid_ranges "$ADK_SUBUID_FILE" "$user" "$uid")
  # nothing of the user may start by itself any more (cron, at, linger), then the spools; again
  # after the kill (a process still running meanwhile could have added an entry)
  adk_ci_lock "$user"
  _adk_ci_clean_spools "$uid" "${ranges[@]}"
  adk_ci_kill "$user" || adk_die "cannot stop all processes of $user"
  _adk_ci_clean_spools "$uid" "${ranges[@]}"
  _adk_ipc_clean "$uid-$uid" "${ranges[@]}"
  _adk_ci_ns_delete "$user" "${ADK_CI_TMP_DIRS[@]}"
  _adk_rm_quarantined "$home"
  _adk_rm_quarantined "$state"
  # the deletion above ran as the user: nothing of it may still run
  # shellcheck disable=SC2046  # one range per word
  [[ -z "$(_adk_pids_in_ranges "$uid-$uid" "${ranges[@]}")" ]] || adk_die "a process of $user appeared during the wipe"
  # report (never act on) files of the user anywhere else
  _adk_ci_owner_expr "$uid" "${ranges[@]}"
  for p in "${ADK_CI_SCAN_PRUNE[@]}"; do prune+=(-path "$p" -o); done
  prune+=(-path "$(dirname "$home")" -o -path "$(dirname "$state")/.adk-wipe")
  rc=0
  left="$(timeout --kill-after=10s "$ADK_CI_WIPE_TIMEOUT" find "${ADK_CI_SCAN_DIRS[@]}" -mindepth 1 -xdev \( "${prune[@]}" \) -prune -o "${ADK_OWNER_EXPR[@]}" -print -quit 2> /dev/null)" || rc=$?
  ((rc != 124 && rc != 137)) || echo "WARNING: the search for files of $user that survived the wipe did not finish within ${ADK_CI_WIPE_TIMEOUT}s" >&2
  [[ -z "$left" ]] || echo "WARNING: a file of $user survived the wipe (not removed by root on purpose): $(printf '%q' "$left")" >&2
  install -d -m 0700 -o "$user" -g "$user" "$home"
  install -d -m 0700 -o "$user" -g "$user" "$state"
}

# adk_runner_register DOMAIN ORG: register a new ephemeral runner "adk-ORG" at organization
# scope with a fresh registration token; older registrations of that name are removed in
# Gitea and the token is invalidated again afterwards (a leaked token is useless).
adk_runner_register() {
  local domain="$1" org="$2" org_id
  org_id="$(sql "SELECT id FROM \"user\" WHERE lower_name = '$org' AND type = 1;")"
  [[ "$org_id" =~ ^[0-9]+$ ]] || adk_die "organization $org not found in Gitea (run gitea-init.sh)"
  sql "UPDATE action_runner SET deleted = $(date +%s) WHERE name = 'adk-$org' AND (deleted IS NULL OR deleted = 0);" \
    || adk_die "cannot remove old runner registrations"
  sql "UPDATE action_runner_token SET is_active = 0 WHERE repo_id = 0 AND owner_id IN (0, $org_id);" \
    || adk_die "cannot invalidate old runner registration tokens"
  # Token: Gitea CLI -> pipe -> environment of the register process (only ci and root can
  # read it there), never argv, a file or the output.
  # shellcheck disable=SC2016  # expanded by the inner sh
  if ! gitea_cli actions generate-runner-token --scope "$org" < /dev/null 2> /dev/null \
      | tail -n 1 \
      | adk_as_user "$ADK_CI_USER" env HOME="$ADK_RUNNER_STATE" sh -c 'cd "$1" && IFS= read -r GITEA_RUNNER_REGISTRATION_TOKEN && export GITEA_RUNNER_REGISTRATION_TOKEN && exec "$2" -c "$3" register --no-interactive --ephemeral --instance "$4" --name "$5"' \
        sh "$ADK_RUNNER_STATE" "$ADK_RUNNER_BIN" "$ADK_RUNNER_CONFIG" "https://$domain" "adk-$org"; then
    sql "UPDATE action_runner_token SET is_active = 0 WHERE repo_id = 0 AND owner_id IN (0, $org_id);" || true
    adk_die "runner registration failed"
  fi
  sql "UPDATE action_runner_token SET is_active = 0 WHERE repo_id = 0 AND owner_id IN (0, $org_id);" \
    || adk_die "cannot invalidate the used registration token"
  echo "registered: ephemeral runner adk-$org at https://$domain (one job)"
}

# adk_runner_unit UID: the systemd unit of the runner (stdout). It runs only together with the
# egress limits: BindsTo stops it (and wipes) when adk-egress.service stops or restarts, and
# the first step refuses to start when the table is not loaded. RuntimeMaxSec ends a run that
# outlives the job timeout; the wipe (ExecStopPost) runs then too.
adk_runner_unit() {
  local uid="$1"
  cat <<EOF
[Unit]
Description=agent-dev-kit CI runner (one job per run, fresh rootless Docker of user ci)
Documentation=file:///opt/adk/docs/agent-vps.md
After=network-online.target docker.service adk-egress.service
Wants=network-online.target
Requires=adk-egress.service
BindsTo=adk-egress.service
# prepare can fail while Gitea starts: retry forever
StartLimitIntervalSec=0

[Service]
Type=simple
User=ci
Group=ci
WorkingDirectory=-$ADK_RUNNER_STATE
Environment=HOME=$ADK_RUNNER_STATE
Environment=XDG_RUNTIME_DIR=/run/user/$uid
Environment=DOCKER_HOST=unix:///run/user/$uid/docker.sock
# "+": as root, outside the sandbox below. No job without the egress limits; fresh environment
# before, wipe after every job (also after RuntimeMaxSec or a failed start).
ExecStartPre=+/bin/sh -c '/usr/sbin/nft list table inet adk_egress > /dev/null'
ExecStartPre=+/opt/adk/agent/ci-reset.sh prepare
ExecStart=$ADK_RUNNER_BIN --config $ADK_RUNNER_CONFIG daemon --once
ExecStopPost=+/opt/adk/agent/ci-reset.sh wipe
Restart=always
RestartSec=10
TimeoutStartSec=30min
# job timeout $ADK_RUNNER_JOB_TIMEOUT (runner.yaml) plus a margin; counted from the registration
RuntimeMaxSec=$ADK_RUNNER_MAX_RUNTIME
TimeoutStopSec=60s
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes

[Install]
WantedBy=multi-user.target
EOF
}
