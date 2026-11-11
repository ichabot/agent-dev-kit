#!/usr/bin/env bash
# Set up the TEST VM. Runs ON the TEST VM as root, from /opt/adk (copied by
# agent/bootstrap.sh --role test). Idempotent: a second run reports "0 changes".
#
# Usage: sudo /opt/adk/test/setup.sh
#
# Steps: check /opt/adk (root-owned, not writable for others, kit.env 0600), validate kit.env,
# base packages + unattended-upgrades, swap, Docker CE (root daemon: TEST is a normal app host),
# sshd drop-in (test/sshd-adk-test.conf: adk-admin and deploy only; deploy gets nothing but the
# deploy gate), users deploy (forced-command key, one sudo rule for test/deploy.sh, not in
# docker) and adk-app (runs the projects' update.sh, member of docker), sudoers rule, Caddy
# (root Docker Compose in /opt/adk/test-services, admin API on a unix socket inside the
# container only, DNS-01 wildcard or HTTP-01 per site), /srv/test for the projects.
# The keys and the Gitea pull token come later from the agent VPS (printed at the end).
#
# Lab/test only (environment, not kit.env): ADK_TLS_INTERNAL=1 (Caddy's internal CA).
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=../agent/lib/host.sh
source "$ROOT/agent/lib/host.sh"
# shellcheck source-path=SCRIPTDIR source=../agent/lib/base.sh
source "$ROOT/agent/lib/base.sh"
# shellcheck source-path=SCRIPTDIR source=../agent/lib/rootless-user.sh
source "$ROOT/agent/lib/rootless-user.sh"
# shellcheck source-path=SCRIPTDIR source=../agent/lib/versions.sh
source "$ROOT/agent/lib/versions.sh"
# shellcheck source-path=SCRIPTDIR source=../agent/lib/services.sh
source "$ROOT/agent/lib/services.sh"
# shellcheck source-path=SCRIPTDIR source=lib/test-host.sh
source "$HERE/lib/test-host.sh"
# shellcheck source-path=SCRIPTDIR source=../scripts/lib/config.sh
source "$ROOT/scripts/lib/config.sh"

(($# == 0)) || { echo "usage: $0" >&2; exit 2; }
[[ "$(id -u)" -eq 0 ]] || adk_die "run as root (sudo $0)"

# The kit runs as root: nobody else may be able to change it, and kit.env stays private.
adk_check_install_tree "$ROOT"
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "debian" ]] || adk_die "Debian required (found ${ID:-unknown})"

echo "== config"
"$ROOT/scripts/check-config.sh" "$ROOT/kit.env"
load_config "$ROOT/kit.env"
[[ -z "${ADK_TLS_INTERNAL:-}" ]] || echo "WARNING: ADK_TLS_INTERNAL=${ADK_TLS_INTERNAL} (lab/test mode, no ACME)"

echo "== base packages"
adk_apt_install python3 curl ca-certificates rsync unattended-upgrades gpg sudo
adk_base_host
adk_sshd_setup "$HERE/sshd-adk-test.conf" adk-admin "$ADK_DEPLOY_USER"

echo "== users $ADK_DEPLOY_USER and $ADK_APP_USER"
adk_test_users
adk_test_sudoers

echo "== caddy"
adk_secrets_dir
adk_caddy_env "${CFG[ACME_MODE]}"
adk_test_services "$ROOT/kit.env"

echo "== keys and token from the agent VPS"
deploy_keys="$(grep -c '^restrict,command="/opt/adk/test/deploy-gate.sh" ' "$ADK_AUTH_KEYS_DIR/$ADK_DEPLOY_USER" || true)"
if ((deploy_keys > 0)); then adk_ok "$deploy_keys CI deploy key(s) for $ADK_DEPLOY_USER"
else echo "WARNING: no CI deploy key for $ADK_DEPLOY_USER yet (see below)"; fi
if [[ -s "$ADK_SECRETS_DIR/gitea-pull-token" ]]; then adk_ok "Gitea pull token (test-pull)"
else echo "WARNING: no Gitea pull token yet (see below)"; fi

echo
echo "setup done: $ADK_CHANGES change(s)"
echo "SSH host keys of this server (the agent VPS pins them for the CI deploy job):"
for f in /etc/ssh/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_ecdsa_key.pub /etc/ssh/ssh_host_rsa_key.pub; do
  [[ -f "$f" ]] && ssh-keygen -l -f "$f"
done
cat <<EOF
Next (from the installer's machine; docs/test-vm.md):
  ssh adk-admin@<test> cat /etc/ssh/ssh_host_ed25519_key.pub \\
    | ssh adk-admin@<agent> sudo /opt/adk/agent/test-deploy-key.sh --host <test address> \\
    | ssh adk-admin@<test> sudo /opt/adk/agent/add-key.sh --forced-command deploy
  ssh adk-admin@<agent> sudo /opt/adk/agent/test-pull-token.sh \\
    | ssh adk-admin@<test> sudo /opt/adk/agent/set-secret.sh gitea-pull-token
EOF
