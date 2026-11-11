#!/usr/bin/env bash
# Idempotent host helpers for agent/setup.sh and later setup scripts (run as root).
# Every helper reports "ok: ..." (nothing to do) or "changed: ..." and counts changes in
# ADK_CHANGES, so a second run of a setup script can prove it changed nothing.
#
# Rule: root never reads or writes inside an unprivileged user's home. Those operations go
# through adk_user_* (agent/lib/user-file.sh, run as the user via runuser), so a symlink the
# user plants cannot redirect root to a system file.

ADK_CHANGES=${ADK_CHANGES:-0}
_ADK_HOST_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

adk_ok() { echo "ok: $*"; }
adk_changed() { echo "changed: $*"; ADK_CHANGES=$((ADK_CHANGES + 1)); }
adk_die() { echo "ERROR: $*" >&2; exit 1; }

# adk_put_file PATH MODE OWNER[:GROUP] < content
# Root-owned system files only (never inside a user's home: use adk_user_put_file).
# Write stdin to PATH if the content differs; always enforce mode and owner.
# Returns 0 if the file changed, 1 if it was already up to date.
adk_put_file() {
  local path="$1" mode="$2" owner="$3" tmp changed=1
  [[ ! -L "$path" ]] || adk_die "$path is a symlink; not following it"
  tmp="$(mktemp)"
  cat > "$tmp"
  if [[ ! -f "$path" ]] || ! cmp -s "$tmp" "$path"; then
    install -D -m "$mode" -o "${owner%%:*}" -g "${owner#*:}" "$tmp" "$path" \
      || adk_die "cannot write $path"   # errexit is off when called in an if condition
    adk_changed "$path"
    changed=0
  else
    if [[ "$(stat -c '%a %U:%G' "$path")" != "${mode#0} ${owner%%:*}:${owner#*:}" ]]; then
      chmod "$mode" "$path"
      chown "$owner" "$path"
      adk_changed "$path (mode/owner)"
    fi
    adk_ok "$path"
  fi
  rm -f "$tmp"
  return "$changed"
}

# adk_resolved_conf: systemd-resolved drop-in. Debian's cloud images answer LLMNR on
# 0.0.0.0:5355 (and could do mDNS); nothing on this server needs either.
adk_resolved_conf() {
  cat <<'EOF'
# agent-dev-kit: no LLMNR/mDNS listeners (only ssh and https are open)
[Resolve]
LLMNR=no
MulticastDNS=no
EOF
}

# adk_apt_install PKG...: install the packages that are missing (apt-get update only then)
adk_apt_install() {
  local missing=() p
  for p in "$@"; do
    if [[ "$(dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null)" != "installed" ]]; then
      missing+=("$p")
    fi
  done
  if ((${#missing[@]} == 0)); then
    adk_ok "packages: $*"
    return 0
  fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get install -yq --no-install-recommends -o Dpkg::Options::=--force-confold "${missing[@]}"
  adk_changed "installed: ${missing[*]}"
}

# adk_user_home USER: home directory from the passwd database
adk_user_home() { getent passwd "$1" | cut -d: -f6; }

# adk_as_user USER CMD...: run CMD as USER with a minimal environment, cwd = the user's home
# (the caller's cwd may be unreadable for the user). ADK_AS_USER_HOOK replaces the switch
# for tests; it is ignored when running as root.
adk_as_user() {
  local user="$1" home
  shift
  if [[ -n "${ADK_AS_USER_HOOK:-}" && "$(id -u)" -ne 0 ]]; then
    "$ADK_AS_USER_HOOK" "$user" "$@"
    return
  fi
  home="$(adk_user_home "$user")"
  [[ -n "$home" ]] || adk_die "no home directory for $user"
  # The cd into the home happens as the user, not as root.
  # shellcheck disable=SC2016  # expanded by the inner sh
  (cd / && runuser -u "$user" -- env -i HOME="$home" USER="$user" LOGNAME="$user" \
    PATH=/usr/bin:/bin LC_ALL=C sh -c 'cd "$HOME" 2>/dev/null || cd /; exec "$@"' sh "$@")
}

# adk_user_env USER CMD...: run CMD as USER with the environment of its systemd user
# session (needed for systemctl --user and rootless Docker without a login).
adk_user_env() {
  local user="$1" uid home
  shift
  uid="$(id -u "$user")"
  home="$(adk_user_home "$user")"
  # shellcheck disable=SC2016  # expanded by the inner sh
  (cd / && runuser -u "$user" -- env -i HOME="$home" USER="$user" LOGNAME="$user" SHELL=/bin/bash \
    PATH="$home/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    XDG_RUNTIME_DIR="/run/user/$uid" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
    sh -c 'cd "$HOME" 2>/dev/null || cd /; exec "$@"' sh "$@")
}

# _adk_user_file USER HOME OP ARGS... (stdin passed on): run user-file.sh as USER.
# Returns 0 = changed, 1 = unchanged; a refusal ends the script with exit code 3.
_adk_user_file() {
  local user="$1" home="$2" op="$3" out rc=0
  shift 3
  out="$(adk_as_user "$user" bash "$_ADK_HOST_LIB/user-file.sh" "$op" "$home" "$@")" || rc=$?
  case "$rc" in
    0) [[ "$op" == test ]] || adk_changed "${out#changed: }"; return 0 ;;
    1) [[ "$op" == test ]] || adk_ok "${out#ok: }"; return 1 ;;
    *)
      [[ -z "$out" ]] || printf '%s\n' "$out"
      echo "ERROR: refused to $op ${1:-} in the home of $user (see above); fix it and re-run" >&2
      exit 3
      ;;
  esac
}

# adk_user_mkdir USER HOME DIR MODE: 0 = changed, 1 = unchanged
adk_user_mkdir() { _adk_user_file "$1" "$2" mkdir "$3" "$4"; }
# adk_user_put_file USER HOME FILE MODE < content: 0 = changed, 1 = unchanged
adk_user_put_file() { _adk_user_file "$1" "$2" put "$3" "$4"; }
# adk_user_test USER HOME -e|-f|-d|-x PATH: test as USER, symlinks refused
adk_user_test() { _adk_user_file "$1" "$2" test "$3" "$4"; }

# adk_user_put_block USER HOME FILE MARKER top|bottom < block
# Keep exactly one current copy of the block, framed by "# >>> MARKER" / "# <<< MARKER".
# top: needed in ~/.bashrc, whose Debian default returns early for non-interactive shells.
adk_user_put_block() { _adk_user_file "$1" "$2" block "$3" "$4" "$5" || true; }

# adk_check_kit_tree DIR OWNER: DIR (the installed kit) belongs to OWNER and nothing in it is
# group/other-writable (incl. symlinks); DIR/kit.env is 0600. Prints the reason, returns 1.
adk_check_kit_tree() {
  local dir="$1" owner="$2" bad
  if ! bad="$(find "$dir" \( ! -user "$owner" -o -perm /022 \) -print -quit 2>&1)"; then
    echo "ERROR: cannot check $dir: $bad" >&2
    return 1
  fi
  if [[ -n "$bad" ]]; then
    echo "ERROR: $bad is not owned by $owner or is group/other-writable (or a symlink); re-run bootstrap.sh" >&2
    return 1
  fi
  if [[ "$(stat -c '%a %U' "$dir/kit.env" 2>/dev/null)" != "600 $owner" ]]; then
    echo "ERROR: $dir/kit.env must exist with mode 0600 and owner $owner" >&2
    return 1
  fi
}

# adk_gpg_key_fpr_is FILE FINGERPRINT: FILE holds exactly one OpenPGP public key whose
# primary fingerprint is FINGERPRINT (apt would trust every key in the file).
adk_gpg_key_fpr_is() {
  local file="$1" want="$2" gh out rc=0
  [[ -f "$file" && ! -L "$file" ]] || return 1
  gh="$(mktemp -d)"
  out="$(GNUPGHOME="$gh" gpg --batch --no-tty --with-colons --show-keys "$file" 2>/dev/null)" || rc=$?
  rm -rf "$gh"
  ((rc == 0)) || return 1
  [[ "$(awk -F: '$1 == "pub"' <<< "$out" | wc -l)" -eq 1 ]] || return 1
  [[ "$(awk -F: '$1 == "pub" {p = 1; next} p && $1 == "fpr" {print $10; exit}' <<< "$out")" == "$want" ]]
}

# adk_subid_ranges FILE USER UID: "start-end" for each line of /etc/subuid or /etc/subgid that
# belongs to USER (by name or numeric id)
adk_subid_ranges() {
  awk -F: -v u="$2" -v id="$3" '($1 == u || $1 == id) && $2 ~ /^[0-9]+$/ && $3 ~ /^[1-9][0-9]*$/ {printf "%d-%d\n", $2, $2 + $3 - 1}' "$1"
}

# adk_egress_rules "UID|RANGE..." "GID|RANGE...": nftables ruleset (table inet adk_egress)
# that rejects traffic of the restricted users to the cloud metadata service and to
# containers of the ROOT Docker daemon other than their ports 80/443 (Caddy; also reached
# there after Docker's DNAT of the host address), so Gitea is reachable only through Caddy
# (reject, not drop: connect() fails at once with EHOSTUNREACH instead of a timeout).
# Restricted are sockets of
#   - the given uids and gids, incl. ranges "lo-hi" for the users' /etc/subuid and
#     /etc/subgid ranges: a user namespace (unshare --map-auto, rootless containers on the
#     host network) can switch to those ids but never to others;
#   - every process in the cgroup user.slice (all user sessions and user managers, so also
#     rootless Docker and its containers, whatever their ids) as a second layer. The path is
#     resolved when the table is loaded; user.slice is static, adk-egress.service creates it.
# Loaded by adk-egress.service with nft -f; replaces the table as a whole (idempotent). Root
# (0) is refused as an id: a typo must not cut root off.
adk_egress_rules() {
  local kind list e lo hi out joined_uids="" joined_gids=""
  local -A seen
  (($# == 2)) || { echo "ERROR: adk_egress_rules: need a uid list and a gid list" >&2; return 1; }
  for kind in uid gid; do
    if [[ "$kind" == uid ]]; then list="$1"; else list="$2"; fi
    seen=() out=""
    for e in ${list//,/ }; do
      if [[ "$e" =~ ^([1-9][0-9]*)-([1-9][0-9]*)$ ]]; then
        lo="${BASH_REMATCH[1]}" hi="${BASH_REMATCH[2]}"
        ((lo <= hi)) || { echo "ERROR: adk_egress_rules: reversed range: $e" >&2; return 1; }
      elif [[ ! "$e" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: adk_egress_rules: not a non-root $kind or range: $e" >&2
        return 1
      fi
      [[ -z "${seen[$e]:-}" ]] || continue
      seen[$e]=1
      out+="${out:+, }$e"
    done
    [[ -n "$out" ]] || { echo "ERROR: adk_egress_rules: no $kind given" >&2; return 1; }
    if [[ "$kind" == uid ]]; then joined_uids="$out"; else joined_gids="$out"; fi
  done
  cat <<EOF
# agent-dev-kit: egress limits for unprivileged users (agent/setup.sh, adk-egress.service).
# Real boundary behind sshd's PermitOpen: these uids/gids (incl. their subordinate ranges) and
# everything in user.slice (sessions, user managers, rootless Docker and its containers,
# whose traffic leaves through slirp4netns) cannot reach the cloud metadata service, nor root
# Docker containers except on ports 80/443 (Gitea only through Caddy).
table inet adk_egress {}
delete table inet adk_egress
table inet adk_egress {
  set restricted_uids {
    type uid
    flags interval
    elements = { $joined_uids }
  }
  set restricted_gids {
    type gid
    flags interval
    elements = { $joined_gids }
  }
  set metadata_v4 {
    type ipv4_addr
    elements = { 169.254.169.254 }
  }
  set metadata_v6 {
    type ipv6_addr
    elements = { fd00:ec2::254 }
  }
  chain restricted {
    ip daddr @metadata_v4 counter reject with icmpx admin-prohibited comment "cloud metadata"
    ip6 daddr @metadata_v6 counter reject with icmpx admin-prohibited comment "cloud metadata"
    oifname "br-*" tcp dport { 80, 443 } accept
    oifname "br-*" counter reject with icmpx admin-prohibited comment "root docker networks"
    oifname "docker0" tcp dport { 80, 443 } accept
    oifname "docker0" counter reject with icmpx admin-prohibited comment "root docker networks"
  }
  chain output {
    type filter hook output priority filter; policy accept;
    meta skuid @restricted_uids jump restricted
    meta skgid @restricted_gids jump restricted
    socket cgroupv2 level 1 "user.slice" jump restricted
  }
}
EOF
}
