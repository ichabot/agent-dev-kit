#!/usr/bin/env bash
# Set up the agent VPS. Runs ON the VPS as root, from /opt/adk (copied by bootstrap.sh).
# Idempotent: a second run reports only "ok:" lines and "0 changes".
#
# Usage: sudo [HERMES_INSTALLER_SHA256=<sha256>] /opt/adk/agent/setup.sh
#
#   HERMES_INSTALLER_SHA256  optional: the Hermes installer must have this sha256
#                            (its sha256 is always printed to the log)
#
# Steps: check /opt/adk (root-owned, not writable for others, kit.env 0600), validate
# kit.env, base packages + unattended-upgrades (reboot 04:30, Debian and Docker CE), swap,
# Docker CE (pinned apt key, root daemon for the kit's own services, log limits), sshd
# drop-in, user hermes with rootless Docker, egress limits (nftables: no cloud metadata for
# hermes), Hermes Agent for hermes. No LLM key is configured: the customer does that.
# Root never reads or writes inside hermes's home; that is done as hermes (lib/host.sh).
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
HERMES_INSTALLER_SHA256="${HERMES_INSTALLER_SHA256:-}"
DOCKER_KEY=/etc/apt/keyrings/docker.asc
DOCKER_KEY_FPR=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
EGRESS_RULES=/etc/adk/egress.nft
EGRESS_UNIT=/etc/systemd/system/adk-egress.service
SWAP_FILE=/swapfile
SWAP_SIZE=2G

[[ "$(id -u)" -eq 0 ]] || adk_die "run as root (sudo $0)"

# The kit runs as root: nobody else may be able to change it, and kit.env stays private.
adk_check_kit_tree "$ROOT" root || exit 1
d="$(dirname "$ROOT")"
while [[ "$d" != / ]]; do
  read -r d_owner d_mode < <(stat -c '%U %a' "$d")
  if [[ "$d_owner" != root || -L "$d" ]] || (((8#$d_mode & 8#022) != 0)); then
    adk_die "$d must be root-owned and not group/other-writable"
  fi
  d="$(dirname "$d")"
done
HERMES_INSTALLER_SHA256="${HERMES_INSTALLER_SHA256,,}"
[[ -z "$HERMES_INSTALLER_SHA256" || "$HERMES_INSTALLER_SHA256" =~ ^[0-9a-f]{64}$ ]] \
  || adk_die "HERMES_INSTALLER_SHA256 must be 64 hex characters"
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "debian" ]] || adk_die "Debian required (found ${ID:-unknown})"

echo "== config"
"$ROOT/scripts/check-config.sh" "$ROOT/kit.env"

echo "== base packages"
adk_apt_install python3 libatomic1 curl ca-certificates git rsync uidmap \
  dbus-user-session slirp4netns unattended-upgrades gpg nftables

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
# Pinned key: fetched only if missing or not exactly Docker's release key.
if adk_gpg_key_fpr_is "$DOCKER_KEY" "$DOCKER_KEY_FPR"; then
  if [[ "$(stat -c '%a %U:%G' "$DOCKER_KEY")" != "644 root:root" ]]; then
    chown root:root "$DOCKER_KEY"
    chmod 0644 "$DOCKER_KEY"
    adk_changed "$DOCKER_KEY (mode/owner)"
  fi
  adk_ok "$DOCKER_KEY (fingerprint $DOCKER_KEY_FPR)"
else
  keyring_tmp="$(mktemp)"
  curl -q -fsSL --proto '=https' https://download.docker.com/linux/debian/gpg -o "$keyring_tmp"
  if ! adk_gpg_key_fpr_is "$keyring_tmp" "$DOCKER_KEY_FPR"; then
    rm -f "$keyring_tmp"
    adk_die "downloaded Docker apt key is not $DOCKER_KEY_FPR; not trusting it"
  fi
  adk_put_file "$DOCKER_KEY" 0644 root:root < "$keyring_tmp" || true
  rm -f "$keyring_tmp"
fi
if adk_put_file /etc/apt/sources.list.d/docker.sources 0644 root:root <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $VERSION_CODENAME
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: $DOCKER_KEY
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

echo "== egress limits (nftables)"
# sshd's PermitOpen only limits tunnels; a shell as hermes has open outbound. This table is
# the boundary for the cloud metadata service (uids: hermes; PR 2b adds ci).
egress_rules="$(adk_egress_rules "$(id -u "$AGENT_USER")")"
egress_reload=false
adk_put_file "$EGRESS_RULES" 0644 root:root <<< "$egress_rules" && egress_reload=true
if adk_put_file "$EGRESS_UNIT" 0644 root:root <<EOF
[Unit]
Description=agent-dev-kit egress limits (nftables table inet adk_egress)
Documentation=file:///opt/adk/docs/agent-vps.md
DefaultDependencies=no
After=local-fs.target nftables.service
Before=network-pre.target shutdown.target
Wants=network-pre.target
Conflicts=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f $EGRESS_RULES
ExecReload=/usr/sbin/nft -f $EGRESS_RULES
ExecStop=/usr/sbin/nft delete table inet adk_egress

[Install]
WantedBy=sysinit.target
EOF
then
  systemctl daemon-reload
  egress_reload=true
fi
if [[ "$(systemctl is-enabled adk-egress.service 2>/dev/null)" != "enabled" ]]; then
  systemctl enable adk-egress.service
  adk_changed "adk-egress.service enabled"
fi
if [[ "$egress_reload" == true ]] || ! systemctl is-active --quiet adk-egress.service \
    || ! nft list table inet adk_egress >/dev/null 2>&1; then
  systemctl restart adk-egress.service
  adk_changed "egress limits loaded"
else
  adk_ok "egress limits active"
fi

echo "== hermes agent"
agent_home="$(adk_user_home "$AGENT_USER")"
# Top of ~/.bashrc so non-interactive SSH commands (ssh hermes@vps hermes ...) find it too;
# the installer's own PATH line sits below Debian's early return for non-interactive shells.
adk_user_put_block "$AGENT_USER" "$agent_home" "$agent_home/.bashrc" "adk hermes path" top <<'EOF'
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac
EOF
if adk_user_test "$AGENT_USER" "$agent_home" -x "$agent_home/.local/bin/hermes"; then
  adk_ok "hermes installed ($(adk_user_env "$AGENT_USER" hermes --version 2>/dev/null | head -n1))"
else
  # Official installer as the user itself (never as root). The browser stays: the agent
  # tests web UIs. No LLM key is set here. Its sha256 goes to the log; with
  # HERMES_INSTALLER_SHA256 a different installer is not run.
  # shellcheck disable=SC2016  # expanded by the inner bash
  adk_user_env "$AGENT_USER" bash -c '
    set -euo pipefail
    f="$(mktemp)"
    trap "rm -f \"$f\"" EXIT
    curl -q -fsSL --proto "=https" "$1" -o "$f"
    sum="$(sha256sum "$f" | cut -d" " -f1)"
    echo "hermes installer: $1 sha256 $sum"
    if [[ -n "$2" && "$sum" != "$2" ]]; then
      echo "ERROR: installer sha256 differs from HERMES_INSTALLER_SHA256 ($2); not running it" >&2
      exit 1
    fi
    bash "$f" --non-interactive --skip-computer-use
  ' _ "$HERMES_INSTALLER" "$HERMES_INSTALLER_SHA256" < /dev/null
  adk_user_test "$AGENT_USER" "$agent_home" -x "$agent_home/.local/bin/hermes" \
    || adk_die "hermes installer finished but $agent_home/.local/bin/hermes is missing"
  adk_changed "hermes installed"
fi

echo
echo "setup done: $ADK_CHANGES change(s)"
echo "Next: add the employee's key (from stdin):  sudo $HERE/add-key.sh $AGENT_USER < key.pub"
