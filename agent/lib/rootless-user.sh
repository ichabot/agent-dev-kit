#!/usr/bin/env bash
# Reusable: an unprivileged login user with its own rootless Docker (run as root).
#
#   adk_setup_rootless_user NAME
#
# Result: user NAME (bash, home 0700, no sudo, not in the docker group, lingering so its
# systemd user services run without a login), rootless dockerd as a systemd --user unit
# (enabled), DOCKER_HOST in ~/.profile and ~/.bashrc, log limits in
# ~/.config/docker/daemon.json. Idempotent. Used for "hermes" (agent) and later "ci"
# (CI runner): neither can reach the root Docker socket, so container access never means
# root on the host.
# Requires: host.sh sourced, packages uidmap dbus-user-session slirp4netns
# docker-ce-rootless-extras installed.

# Groups that would hand out root (directly, via a root daemon, a device, a writable
# directory early in root's PATH such as /usr/local for staff) or secrets (shadow, logs).
ADK_PRIVILEGED_GROUPS=(root sudo staff shadow adm systemd-journal disk kvm docker lxd incus-admin libvirt)

adk_ensure_unprivileged_user() {
  local name="$1" g home
  if ! id "$name" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash --user-group "$name"
    adk_changed "user $name created"
  else
    adk_ok "user $name exists"
  fi
  if [[ "$(getent passwd "$name" | cut -d: -f7)" != "/bin/bash" ]]; then
    usermod --shell /bin/bash "$name"
    adk_changed "user $name: shell /bin/bash"
  fi
  for g in "${ADK_PRIVILEGED_GROUPS[@]}"; do
    if id -nG "$name" | tr ' ' '\n' | grep -qx "$g"; then
      gpasswd -d "$name" "$g" >/dev/null
      adk_changed "user $name removed from group $g"
    fi
  done
  if grep -rqsE "^[^#]*\b$name\b" /etc/sudoers /etc/sudoers.d; then
    adk_die "sudoers mentions $name; remove that entry (the user must not have sudo)"
  fi
  home="$(adk_user_home "$name")"
  [[ -d "$home" && ! -L "$home" ]] || adk_die "home of $name ($home) is missing or a symlink"
  if [[ "$(stat -c %a "$home")" != "700" ]]; then
    chmod 0700 "$home"
    adk_changed "$home: mode 0700"
  fi
  if ! grep -q "^$name:" /etc/subuid || ! grep -q "^$name:" /etc/subgid; then
    adk_die "$name has no /etc/subuid or /etc/subgid range (needed for rootless Docker)"
  fi
  if [[ "$(loginctl show-user "$name" -p Linger --value 2>/dev/null)" != "yes" ]]; then
    loginctl enable-linger "$name"
    adk_changed "user $name: linger enabled"
  else
    adk_ok "user $name: linger"
  fi
}

# Wait for the user's systemd instance and its D-Bus socket (linger starts them).
adk_wait_user_bus() {
  local name="$1" uid i
  uid="$(id -u "$name")"
  systemctl start "user@$uid.service"
  for ((i = 0; i < 30; i++)); do
    [[ -S "/run/user/$uid/bus" ]] && return 0
    # dbus-user-session installed after the user manager started: restart it once.
    ((i == 10)) && systemctl restart "user@$uid.service"
    sleep 1
  done
  adk_die "no D-Bus session socket for $name (/run/user/$uid/bus)"
}

adk_ensure_rootless_docker() {
  local name="$1" uid home
  uid="$(id -u "$name")"
  home="$(adk_user_home "$name")"
  adk_wait_user_bus "$name"

  # Everything inside the home is done as the user (adk_user_*), never as root.
  if adk_user_test "$name" "$home" -f "$home/.config/systemd/user/docker.service"; then
    adk_ok "rootless docker for $name installed"
  else
    adk_user_env "$name" dockerd-rootless-setuptool.sh install
    adk_changed "rootless docker for $name installed"
  fi

  adk_user_mkdir "$name" "$home" "$home/.config" 0700 || true
  adk_user_mkdir "$name" "$home" "$home/.config/docker" 0700 || true
  if adk_user_put_file "$name" "$home" "$home/.config/docker/daemon.json" 0644 <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "5" }
}
EOF
  then
    adk_user_env "$name" systemctl --user restart docker.service
  fi

  if [[ "$(adk_user_env "$name" systemctl --user is-enabled docker.service 2>/dev/null)" != "enabled" ]]; then
    adk_user_env "$name" systemctl --user enable docker.service
    adk_changed "rootless docker for $name enabled"
  fi
  if [[ "$(adk_user_env "$name" systemctl --user is-active docker.service 2>/dev/null)" != "active" ]]; then
    adk_user_env "$name" systemctl --user start docker.service
    adk_changed "rootless docker for $name started"
  else
    adk_ok "rootless docker for $name running"
  fi

  adk_user_put_block "$name" "$home" "$home/.profile" "adk rootless docker" bottom <<EOF
export DOCKER_HOST=unix:///run/user/$uid/docker.sock
EOF
  adk_user_put_block "$name" "$home" "$home/.bashrc" "adk rootless docker" top <<EOF
export DOCKER_HOST=unix:///run/user/$uid/docker.sock
EOF
}

adk_setup_rootless_user() {
  adk_ensure_unprivileged_user "$1"
  adk_ensure_rootless_docker "$1"
}
