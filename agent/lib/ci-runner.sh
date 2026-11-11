#!/usr/bin/env bash
# CI runner of the agent VPS: every job runs in a FRESH environment of user ci.
#
# adk-act-runner.service (system unit, User=ci) runs `gitea-runner daemon --once` with an
# ephemeral registration: exactly one job per process. Root steps of the same unit run around
# it (ExecStartPre=+ / ExecStopPost=+, agent/ci-reset.sh), never anything user ci controls:
#
#   wipe     stop ci's user manager (rootless Docker, user units), end its sessions, kill
#            every process of ci and of its subordinate uids, delete ci's home (rootless
#            Docker data, ~/.config/systemd/user, caches), the runner state directory with
#            the registration, and files of ci / its subuids in /tmp, /var/tmp, /dev/shm, /run,
#            cron spools etc.; recreate home and state directory empty
#   prepare  wipe, set up rootless Docker for ci again (files in the home written AS ci),
#            pull the pinned job image, register a new ephemeral runner with a NEW
#            registration token (Gitea CLI -> pipe -> environment of the register process;
#            the token is invalidated right after)
#
# So a job cannot leave anything behind for a later job: no images or build cache, no planted
# user units or processes, no reusable registration. Price: base images are pulled per job.
# Requires host.sh, rootless-user.sh, gitea-admin.sh and versions.sh sourced.

ADK_CI_USER=ci
ADK_RUNNER_CONFIG="${ADK_RUNNER_CONFIG:-/etc/adk/runner.yaml}"
ADK_RUNNER_STATE="${ADK_RUNNER_STATE:-/var/lib/adk-runner}"
ADK_RUNNER_BIN="${ADK_RUNNER_BIN:-/usr/local/bin/gitea-runner}"
ADK_SUBUID_FILE=/etc/subuid
# Directories (one file system each, -xdev) searched for files of ci and its subuids.
ADK_CI_SCAN_DIRS=(/ /tmp /var/tmp /dev/shm /run)
# Never searched: not writable for ci (other homes are 0700, the kit's directories root-only),
# large, or not real files. ci's own home and the state directory are deleted as a whole.
ADK_CI_SCAN_PRUNE=(/proc /sys /dev/pts /home /root /opt/adk /var/lib/adk /var/backups /var/lib/docker /var/lib/containerd)

# _adk_pids_in_ranges RANGES...: pids whose real or effective uid lies in one of the ranges
_adk_pids_in_ranges() {
  ps -eo pid=,ruid=,euid= | awk -v r="$*" '
    BEGIN { n = split(r, a, " "); for (i = 1; i <= n; i++) { split(a[i], b, "-"); lo[i] = b[1]; hi[i] = b[2] } }
    { for (i = 1; i <= n; i++) if (($2 >= lo[i] && $2 <= hi[i]) || ($3 >= lo[i] && $3 <= hi[i])) { print $1; next } }'
}

# adk_ci_kill USER: stop USER's user manager and sessions, kill all processes of USER and of
# its subordinate uids (rootless containers). Returns 1 if processes survive.
adk_ci_kill() {
  local user="$1" uid ranges pids i
  uid="$(id -u "$user")"
  [[ "$uid" != "$(id -u)" && "$uid" != 0 ]] || adk_die "refusing to kill the processes of $user (the caller or root)"
  ranges="$uid-$uid $(adk_subid_ranges "$ADK_SUBUID_FILE" "$user" "$uid" | tr '\n' ' ')"
  systemctl stop "user@$uid.service" > /dev/null 2>&1 || true
  loginctl terminate-user "$user" > /dev/null 2>&1 || true
  # shellcheck disable=SC2086  # one range per word
  for ((i = 0; i < 20; i++)); do
    pids="$(_adk_pids_in_ranges $ranges)"
    [[ -n "$pids" ]] || break
    # shellcheck disable=SC2086  # one pid per word
    kill -KILL $pids 2> /dev/null || true
    sleep 0.5
  done
  systemctl stop "user-runtime-dir@$uid.service" > /dev/null 2>&1 || true
  # shellcheck disable=SC2086  # one range per word
  [[ -z "$(_adk_pids_in_ranges $ranges)" ]] || { echo "ERROR: processes of $user survive: $(_adk_pids_in_ranges $ranges | tr '\n' ' ')" >&2; return 1; }
}

# _adk_rm_tree PATH: remove PATH (a directory tree of an unprivileged user that has no running
# processes any more) without following symlinks or crossing into other file systems
_adk_rm_tree() {
  [[ -e "$1" || -L "$1" ]] || return 0
  rm -rf --one-file-system -- "$1"
}

# adk_ci_wipe USER STATE_DIR: kill (adk_ci_kill), delete USER's home, STATE_DIR and every file
# of USER or its subuids in ADK_CI_SCAN_DIRS, recreate home and STATE_DIR empty (USER, 0700).
adk_ci_wipe() {
  local user="$1" state="$2" uid home parent tmp find_expr=() prune=() r p
  uid="$(id -u "$user")"
  home="$(adk_user_home "$user")"
  [[ "$home" == /?*/?* && "$home" != *//* && "$home" != */./* && "$home" != */../* ]] || adk_die "unexpected home of $user: $home"
  [[ "$state" == /?*/?* ]] || adk_die "unexpected state directory: $state"
  adk_ci_kill "$user" || adk_die "cannot stop all processes of $user"
  # No process of the user is left, so nothing can swap paths under the deletions below.
  parent="$(dirname "$home")"
  [[ ! -L "$parent" && "$(stat -c %u "$parent")" == "$(id -u)" ]] || adk_die "$parent must be a directory owned by $(id -un)"
  if [[ -e "$home" || -L "$home" ]]; then
    tmp="$parent/.adk-wipe-$user-$$"
    mv -T -- "$home" "$tmp"
    _adk_rm_tree "$tmp"
  fi
  [[ ! -L "$state" ]] || rm -f -- "$state"
  _adk_rm_tree "$state"
  # files of the user and its subuids anywhere else (tmp dirs, cron spool, mail, /run)
  find_expr=(-uid "$uid")
  while IFS=- read -r lo hi; do
    [[ -n "$lo" ]] || continue
    find_expr+=(-o \( -uid "+$((lo - 1))" -uid "-$((hi + 1))" \))
  done < <(adk_subid_ranges "$ADK_SUBUID_FILE" "$user" "$uid")
  for p in "${ADK_CI_SCAN_PRUNE[@]}"; do prune+=(-path "$p" -o); done
  prune+=(-path "$parent" -o -path "$home" -o -path "$state")
  while IFS= read -r -d '' r; do
    _adk_rm_tree "$r"
  done < <(find "${ADK_CI_SCAN_DIRS[@]}" -xdev \( "${prune[@]}" \) -prune -o \( "${find_expr[@]}" \) -print0 2> /dev/null)
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

# adk_runner_unit UID: the systemd unit of the runner (stdout)
adk_runner_unit() {
  local uid="$1"
  cat <<EOF
[Unit]
Description=agent-dev-kit CI runner (one job per run, fresh rootless Docker of user ci)
Documentation=file:///opt/adk/docs/agent-vps.md
After=network-online.target docker.service adk-egress.service
Wants=network-online.target
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
# "+": as root, outside the sandbox below. Fresh environment before, wipe after every job.
ExecStartPre=+/opt/adk/agent/ci-reset.sh prepare
ExecStart=$ADK_RUNNER_BIN --config $ADK_RUNNER_CONFIG daemon --once
ExecStopPost=+/opt/adk/agent/ci-reset.sh wipe
Restart=always
RestartSec=10
TimeoutStartSec=30min
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
