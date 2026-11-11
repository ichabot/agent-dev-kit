#!/usr/bin/env bash
# Set up the agent VPS. Runs ON the VPS as root, from /opt/adk (copied by bootstrap.sh).
# Idempotent: a second run reports only "ok:" lines and "0 changes".
#
# Usage: sudo /opt/adk/agent/setup.sh
#
# Steps: validate kit.env, base packages + unattended-upgrades (reboot 04:30), swap,
# Docker CE (root daemon for the kit's own services, log limits), sshd drop-in, user
# hermes with rootless Docker, Hermes Agent for hermes. No LLM key is configured: the
# customer does that.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib/host.sh
source "$HERE/lib/host.sh"
# shellcheck source-path=SCRIPTDIR source=lib/rootless-user.sh
source "$HERE/lib/rootless-user.sh"

AGENT_USER=hermes
AUTH_KEYS_DIR=/etc/ssh/authorized_keys
HERMES_INSTALLER=https://hermes-agent.nousresearch.com/install.sh
SWAP_FILE=/swapfile
SWAP_SIZE=2G

[[ "$(id -u)" -eq 0 ]] || adk_die "run as root (sudo $0)"
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "debian" ]] || adk_die "Debian required (found ${ID:-unknown})"

echo "== config"
"$ROOT/scripts/check-config.sh" "$ROOT/kit.env"

echo "== base packages"
adk_apt_install python3 libatomic1 curl ca-certificates git rsync uidmap \
  dbus-user-session slirp4netns unattended-upgrades

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
for unit in apt-daily.timer apt-daily-upgrade.timer; do
  if [[ "$(systemctl is-enabled "$unit" 2>/dev/null)" != "enabled" ]]; then
    systemctl enable --now "$unit"
    adk_changed "$unit enabled"
  fi
done

echo "== swap"
if [[ -n "$(swapon --show --noheadings)" ]]; then
  adk_ok "swap active"
else
  if [[ ! -f "$SWAP_FILE" ]]; then
    fallocate -l "$SWAP_SIZE" "$SWAP_FILE"
    chmod 0600 "$SWAP_FILE"
    mkswap "$SWAP_FILE" >/dev/null
  fi
  swapon "$SWAP_FILE"
  adk_changed "swap $SWAP_FILE ($SWAP_SIZE) on"
fi
if [[ -f "$SWAP_FILE" ]] && ! grep -qE "^${SWAP_FILE}[[:space:]]" /etc/fstab; then
  echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
  adk_changed "/etc/fstab: $SWAP_FILE"
fi

echo "== docker"
install -d -m 0755 /etc/apt/keyrings
keyring_tmp="$(mktemp)"
curl -fsSL --proto '=https' https://download.docker.com/linux/debian/gpg -o "$keyring_tmp"
adk_put_file /etc/apt/keyrings/docker.asc 0644 root:root < "$keyring_tmp" || true
rm -f "$keyring_tmp"
if adk_put_file /etc/apt/sources.list.d/docker.sources 0644 root:root <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $VERSION_CODENAME
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
then
  apt-get update -q
fi
adk_apt_install docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-ce-rootless-extras
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

echo "== sshd"
if [[ "$(stat -c '%a %U:%G' "$AUTH_KEYS_DIR" 2>/dev/null)" != "755 root:root" ]]; then
  install -d -m 0755 -o root -g root "$AUTH_KEYS_DIR"
  adk_changed "$AUTH_KEYS_DIR"
fi
for user in adk-admin "$AGENT_USER"; do
  f="$AUTH_KEYS_DIR/$user"
  if [[ ! -f "$f" ]]; then
    install -m 0644 -o root -g root /dev/null "$f"
    adk_changed "$f created (empty)"
  elif [[ "$(stat -c '%a %U:%G' "$f")" != "644 root:root" ]]; then
    chown root:root "$f"
    chmod 0644 "$f"
    adk_changed "$f mode/owner"
  fi
done
dropin=/etc/ssh/sshd_config.d/10-adk.conf
old_dropin="$(mktemp)"
[[ -f "$dropin" ]] && cp -p "$dropin" "$old_dropin"
if adk_put_file "$dropin" 0644 root:root < "$HERE/sshd-adk.conf"; then
  if ! sshd -t; then
    if [[ -s "$old_dropin" ]]; then cp -p "$old_dropin" "$dropin"; else rm -f "$dropin"; fi
    adk_die "sshd -t failed with the new drop-in; old file restored"
  fi
  # Debian 13: reload does not apply drop-in changes reliably, restart does.
  systemctl restart ssh
fi
rm -f "$old_dropin"

echo "== user $AGENT_USER"
adk_setup_rootless_user "$AGENT_USER"

echo "== hermes agent"
agent_home="$(getent passwd "$AGENT_USER" | cut -d: -f6)"
if [[ -x "$agent_home/.local/bin/hermes" ]]; then
  adk_ok "hermes installed ($(adk_user_env "$AGENT_USER" hermes --version 2>/dev/null | head -n1))"
else
  # Official installer as the user itself (never as root). The browser stays: the agent
  # tests web UIs. No LLM key is set here.
  # shellcheck disable=SC2016  # expanded by the inner bash
  adk_user_env "$AGENT_USER" bash -c '
    set -euo pipefail
    f="$(mktemp)"
    trap "rm -f \"$f\"" EXIT
    curl -fsSL --proto "=https" "$1" -o "$f"
    bash "$f" --non-interactive --skip-computer-use
  ' _ "$HERMES_INSTALLER" < /dev/null
  [[ -x "$agent_home/.local/bin/hermes" ]] || adk_die "hermes installer finished but $agent_home/.local/bin/hermes is missing"
  adk_changed "hermes installed"
fi

echo
echo "setup done: $ADK_CHANGES change(s)"
echo "Next: add the employee's key:  sudo $HERE/add-key.sh $AGENT_USER <key.pub>"
