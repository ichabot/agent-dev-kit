#!/usr/bin/env bash
# Idempotent host helpers for agent/setup.sh and later setup scripts (run as root).
# Every helper reports "ok: ..." (nothing to do) or "changed: ..." and counts changes in
# ADK_CHANGES, so a second run of a setup script can prove it changed nothing.

ADK_CHANGES=${ADK_CHANGES:-0}

adk_ok() { echo "ok: $*"; }
adk_changed() { echo "changed: $*"; ADK_CHANGES=$((ADK_CHANGES + 1)); }
adk_die() { echo "ERROR: $*" >&2; exit 1; }

# adk_put_file PATH MODE OWNER[:GROUP] < content
# Write stdin to PATH if the content differs; always enforce mode and owner.
# Returns 0 if the file changed, 1 if it was already up to date.
adk_put_file() {
  local path="$1" mode="$2" owner="$3" tmp changed=1
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

# adk_user_env USER CMD...: run CMD as USER with the environment of its systemd user
# session (needed for systemctl --user and rootless Docker without a login).
adk_user_env() {
  local user="$1" uid home
  shift
  uid="$(id -u "$user")"
  home="$(getent passwd "$user" | cut -d: -f6)"
  # Subshell in the user's home: the caller's cwd may be unreadable for the user.
  (cd "$home" && runuser -u "$user" -- env -i HOME="$home" USER="$user" LOGNAME="$user" SHELL=/bin/bash \
    PATH="$home/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    XDG_RUNTIME_DIR="/run/user/$uid" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
    "$@")
}

# adk_put_block FILE OWNER[:GROUP] MARKER top|bottom < block
# Keep exactly one current copy of the block, framed by "# >>> MARKER" / "# <<< MARKER".
# top: needed in ~/.bashrc, whose Debian default returns early for non-interactive shells.
adk_put_block() {
  local file="$1" owner="$2" marker="$3" pos="$4" block existing rest tmp
  block="$(printf '# >>> %s\n%s\n# <<< %s' "$marker" "$(cat)" "$marker")"
  existing="" rest=""
  if [[ -f "$file" ]]; then
    existing="$(awk -v b="# >>> $marker" -v e="# <<< $marker" '$0 == b {p = 1} p {print} $0 == e {p = 0}' "$file")"
    rest="$(awk -v b="# >>> $marker" -v e="# <<< $marker" '$0 == b {s = 1; next} $0 == e {s = 0; next} !s' "$file")"
  fi
  if [[ "$existing" == "$block" ]]; then
    adk_ok "$file ($marker)"
    return 0
  fi
  tmp="$(mktemp)"
  if [[ "$pos" == top ]]; then
    printf '%s\n%s\n' "$block" "$rest" > "$tmp"
  else
    printf '%s\n%s\n' "$rest" "$block" > "$tmp"
  fi
  adk_put_file "$file" 0644 "$owner" < "$tmp" || true   # not in a pipe: keeps ADK_CHANGES
  rm -f "$tmp"
}
