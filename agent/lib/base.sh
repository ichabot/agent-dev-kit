#!/usr/bin/env bash
# Base host setup shared by agent/setup.sh (agent VPS) and test/setup.sh (TEST VM), run as root.
# Requires host.sh sourced and /etc/os-release read (VERSION_CODENAME). Every step reports
# ok/changed (ADK_CHANGES).

ADK_DOCKER_KEY=/etc/apt/keyrings/docker.asc
ADK_DOCKER_KEY_FPR=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
ADK_AUTH_KEYS_DIR=/etc/ssh/authorized_keys
ADK_SWAP_FILE=/swapfile
ADK_SWAP_SIZE=2G

# adk_check_install_tree ROOT: the installed kit (ROOT, e.g. /opt/adk) is root-owned, nothing in
# it is group/other-writable, kit.env is 0600, and every parent directory is root-owned and
# not group/other-writable. Ends the script otherwise.
adk_check_install_tree() {
  local root="$1" d d_owner d_mode
  adk_check_kit_tree "$root" root || exit 1
  d="$(dirname "$root")"
  while [[ "$d" != / ]]; do
    read -r d_owner d_mode < <(stat -c '%U %a' "$d")
    if [[ "$d_owner" != root || -L "$d" ]] || (((8#$d_mode & 8#022) != 0)); then
      adk_die "$d must be root-owned and not group/other-writable"
    fi
    d="$(dirname "$d")"
  done
}

# adk_base_host: unattended-upgrades (Debian + Docker CE, reboot 04:30), resolver without
# LLMNR/mDNS, swap, Docker CE (pinned apt key, root daemon, log limits)
adk_base_host() {
  local unit keyring_tmp
  echo "== unattended-upgrades"
  # Own files instead of editing package-managed ones; later apt.conf.d files win.
  adk_put_file /etc/apt/apt.conf.d/21adk-auto-upgrades 0644 root:root <<'EOF' || true
// agent-dev-kit: daily package lists + unattended security upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  adk_put_file /etc/apt/apt.conf.d/52adk-auto-reboot 0644 root:root <<'EOF' || true
// agent-dev-kit: kernel and libc fixes only take effect after a reboot
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:30";
EOF
  # Lists add up across apt.conf.d files: Debian's own origins stay, Docker CE joins them.
  adk_put_file /etc/apt/apt.conf.d/52adk-docker-upgrades 0644 root:root <<'EOF' || true
// agent-dev-kit: Docker CE from download.docker.com gets unattended upgrades too
Unattended-Upgrade::Origins-Pattern {
        "origin=Docker,label=Docker CE";
};
EOF
  for unit in apt-daily.timer apt-daily-upgrade.timer; do
    if [[ "$(systemctl is-enabled "$unit" 2>/dev/null)" != "enabled" ]]; then
      systemctl enable --now "$unit"
      adk_changed "$unit enabled"
    fi
  done

  echo "== resolver"
  if systemctl is-enabled --quiet systemd-resolved 2>/dev/null; then
    if adk_put_file /etc/systemd/resolved.conf.d/50-adk.conf 0644 root:root < <(adk_resolved_conf); then
      systemctl restart systemd-resolved
    fi
  else
    adk_ok "systemd-resolved not in use (no LLMNR listener)"
  fi

  echo "== swap"
  if [[ -n "$(swapon --show --noheadings)" ]]; then
    adk_ok "swap active"
  else
    if [[ ! -f "$ADK_SWAP_FILE" ]]; then
      fallocate -l "$ADK_SWAP_SIZE" "$ADK_SWAP_FILE"
      chmod 0600 "$ADK_SWAP_FILE"
      mkswap "$ADK_SWAP_FILE" >/dev/null
    fi
    swapon "$ADK_SWAP_FILE"
    adk_changed "swap $ADK_SWAP_FILE ($ADK_SWAP_SIZE) on"
  fi
  if [[ -f "$ADK_SWAP_FILE" ]] && ! grep -qE "^${ADK_SWAP_FILE}[[:space:]]" /etc/fstab; then
    echo "$ADK_SWAP_FILE none swap sw 0 0" >> /etc/fstab
    adk_changed "/etc/fstab: $ADK_SWAP_FILE"
  fi

  echo "== docker"
  install -d -m 0755 /etc/apt/keyrings
  # Pinned key: fetched only if missing or not exactly Docker's release key.
  if adk_gpg_key_fpr_is "$ADK_DOCKER_KEY" "$ADK_DOCKER_KEY_FPR"; then
    if [[ "$(stat -c '%a %U:%G' "$ADK_DOCKER_KEY")" != "644 root:root" ]]; then
      chown root:root "$ADK_DOCKER_KEY"
      chmod 0644 "$ADK_DOCKER_KEY"
      adk_changed "$ADK_DOCKER_KEY (mode/owner)"
    fi
    adk_ok "$ADK_DOCKER_KEY (fingerprint $ADK_DOCKER_KEY_FPR)"
  else
    keyring_tmp="$(mktemp)"
    curl -q -fsSL --proto '=https' https://download.docker.com/linux/debian/gpg -o "$keyring_tmp"
    if ! adk_gpg_key_fpr_is "$keyring_tmp" "$ADK_DOCKER_KEY_FPR"; then
      rm -f "$keyring_tmp"
      adk_die "downloaded Docker apt key is not $ADK_DOCKER_KEY_FPR; not trusting it"
    fi
    adk_put_file "$ADK_DOCKER_KEY" 0644 root:root < "$keyring_tmp" || true
    rm -f "$keyring_tmp"
  fi
  if adk_put_file /etc/apt/sources.list.d/docker.sources 0644 root:root <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $VERSION_CODENAME
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: $ADK_DOCKER_KEY
EOF
  then
    apt-get update -q
  fi
  adk_apt_install docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin \
    docker-ce-rootless-extras
  # Written after the install (not a package conffile, but the daemon must exist first).
  if adk_put_file /etc/docker/daemon.json 0644 root:root <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "5" }
}
EOF
  then
    systemctl restart docker
  fi
  if [[ "$(systemctl is-enabled docker 2>/dev/null)" != "enabled" ]]; then
    systemctl enable --now docker
    adk_changed "docker enabled"
  fi
}

# adk_sshd_setup DROPIN USER...: root-owned key files for USER... (created empty), DROPIN
# installed as /etc/ssh/sshd_config.d/10-adk.conf (checked with sshd -t; the old file is
# restored if the new one fails), sshd restarted on change
adk_sshd_setup() {
  local src="$1" user f dropin=/etc/ssh/sshd_config.d/10-adk.conf old_dropin
  shift
  echo "== sshd"
  if [[ "$(stat -c '%a %U:%G' "$ADK_AUTH_KEYS_DIR" 2>/dev/null)" != "755 root:root" ]]; then
    install -d -m 0755 -o root -g root "$ADK_AUTH_KEYS_DIR"
    adk_changed "$ADK_AUTH_KEYS_DIR"
  fi
  for user in "$@"; do
    f="$ADK_AUTH_KEYS_DIR/$user"
    if [[ ! -f "$f" ]]; then
      install -m 0644 -o root -g root /dev/null "$f"
      adk_changed "$f created (empty)"
    elif [[ "$(stat -c '%a %U:%G' "$f")" != "644 root:root" ]]; then
      chown root:root "$f"
      chmod 0644 "$f"
      adk_changed "$f mode/owner"
    fi
  done
  old_dropin="$(mktemp)"
  [[ -f "$dropin" ]] && cp -p "$dropin" "$old_dropin"
  if adk_put_file "$dropin" 0644 root:root < "$src"; then
    if ! sshd -t; then
      if [[ -s "$old_dropin" ]]; then cp -p "$old_dropin" "$dropin"; else rm -f "$dropin"; fi
      rm -f "$old_dropin"
      adk_die "sshd -t failed with the new drop-in; old file restored"
    fi
    # Debian 13: reload does not apply drop-in changes reliably, restart does.
    systemctl restart ssh
  fi
  rm -f "$old_dropin"
}
