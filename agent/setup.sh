#!/usr/bin/env bash
# Set up the agent VPS. Runs ON the VPS as root, from /opt/adk (copied by bootstrap.sh).
# Idempotent: a second run reports only "ok:" lines and "0 changes".
#
# Usage: sudo [HERMES_INSTALLER_SHA256=<sha256>] /opt/adk/agent/setup.sh [--accept-backup-hostkey FP]
#
#   HERMES_INSTALLER_SHA256  optional: the Hermes installer must have this sha256
#                            (its sha256 is always printed to the log)
#   --accept-backup-hostkey  pin the SSH host key of BACKUP_TARGET with this SHA256
#                            fingerprint (from the provider, not from a scan alone)
#
# Steps: check /opt/adk (root-owned, not writable for others, kit.env 0600), validate
# kit.env, base packages + unattended-upgrades (reboot 04:30, Debian and Docker CE), swap,
# Docker CE (pinned apt key, root daemon for the kit's own services, log limits), sshd
# drop-in, user hermes with rootless Docker, egress limits (nftables: no cloud metadata for
# hermes and ci), Hermes Agent for hermes, then the services: Gitea + Caddy (root Docker
# Compose, /opt/adk/services), Gitea accounts (gitea-init.sh), CI runner as user ci (one job
# per run, fresh rootless Docker per job, lib/ci-runner.sh), backup timer. No LLM key is configured: the customer does that.
# Root never reads or writes inside hermes's home; that is done as hermes (lib/host.sh).
#
# Lab/test only (environment, not kit.env): ADK_TLS_INTERNAL=1, ADK_RUNNER_ADD_HOST=<ip>,
# see agent/render-services.sh.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib/host.sh
source "$HERE/lib/host.sh"
# shellcheck source-path=SCRIPTDIR source=lib/base.sh
source "$HERE/lib/base.sh"
# shellcheck source-path=SCRIPTDIR source=lib/rootless-user.sh
source "$HERE/lib/rootless-user.sh"
# shellcheck source-path=SCRIPTDIR source=lib/versions.sh
source "$HERE/lib/versions.sh"
# shellcheck source-path=SCRIPTDIR source=lib/gitea-admin.sh
source "$HERE/lib/gitea-admin.sh"
# shellcheck source-path=SCRIPTDIR source=lib/ci-runner.sh
source "$HERE/lib/ci-runner.sh"
# shellcheck source-path=SCRIPTDIR source=lib/services.sh
source "$HERE/lib/services.sh"
# shellcheck source-path=SCRIPTDIR source=../scripts/lib/config.sh
source "$ROOT/scripts/lib/config.sh"

AGENT_USER=hermes
CI_USER=ci
HERMES_INSTALLER=https://hermes-agent.nousresearch.com/install.sh
HERMES_INSTALLER_SHA256="${HERMES_INSTALLER_SHA256:-}"
EGRESS_RULES=/etc/adk/egress.nft
EGRESS_UNIT=/etc/systemd/system/adk-egress.service
NFTABLES_DROPIN=/etc/systemd/system/nftables.service.d/50-adk-egress.conf

ACCEPT_BACKUP_HOSTKEY=""
while (($#)); do
  case "$1" in
    --accept-backup-hostkey) (($# >= 2)) || adk_die "usage: $0 [--accept-backup-hostkey SHA256:...]"; ACCEPT_BACKUP_HOSTKEY="$2"; shift 2 ;;
    *) echo "usage: $0 [--accept-backup-hostkey SHA256:...]" >&2; exit 2 ;;
  esac
done
[[ "$(id -u)" -eq 0 ]] || adk_die "run as root (sudo $0)"

# The kit runs as root: nobody else may be able to change it, and kit.env stays private.
adk_check_install_tree "$ROOT"
HERMES_INSTALLER_SHA256="${HERMES_INSTALLER_SHA256,,}"
[[ -z "$HERMES_INSTALLER_SHA256" || "$HERMES_INSTALLER_SHA256" =~ ^[0-9a-f]{64}$ ]] \
  || adk_die "HERMES_INSTALLER_SHA256 must be 64 hex characters"
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "debian" ]] || adk_die "Debian required (found ${ID:-unknown})"

echo "== config"
"$ROOT/scripts/check-config.sh" "$ROOT/kit.env"
load_config "$ROOT/kit.env"
[[ -z "${ADK_TLS_INTERNAL:-}" ]] || echo "WARNING: ADK_TLS_INTERNAL=${ADK_TLS_INTERNAL} (lab/test mode, no ACME)"
[[ -z "${ADK_RUNNER_ADD_HOST:-}" ]] || echo "WARNING: ADK_RUNNER_ADD_HOST=${ADK_RUNNER_ADD_HOST} (lab/test mode)"

echo "== base packages"
adk_apt_install python3 libatomic1 curl ca-certificates git rsync uidmap \
  dbus-user-session slirp4netns unattended-upgrades gpg nftables age

adk_base_host

adk_sshd_setup "$HERE/sshd-adk.conf" adk-admin "$AGENT_USER"

echo "== user $AGENT_USER"
adk_setup_rootless_user "$AGENT_USER"

echo "== user $CI_USER (CI runner)"
# Only the account here: its rootless Docker is set up fresh before every CI job by the
# runner unit (agent/ci-reset.sh prepare) and wiped after it; ci-reset.sh also switches its
# linger and account expiry (off/expired between jobs). No cron or at jobs, ever: they would
# outlive the wipe.
adk_ensure_unprivileged_user "$CI_USER" no-linger
adk_deny_cron_at "$CI_USER"

echo "== egress limits (nftables)"
# sshd's PermitOpen only limits tunnels; a shell as hermes has open outbound. This table is
# the boundary for the cloud metadata service (uids: hermes and ci, incl. CI job containers).
# uids/gids incl. the subordinate ranges (user namespaces can switch to those), plus all of
# user.slice as a second layer (adk_egress_rules in lib/host.sh).
egress_uids="" egress_gids=""
for u in "$AGENT_USER" "$CI_USER"; do
  egress_uids+=" $(id -u "$u") $(adk_subid_ranges /etc/subuid "$u" "$(id -u "$u")" | tr '\n' ' ')"
  egress_gids+=" $(id -g "$u") $(adk_subid_ranges /etc/subgid "$u" "$(id -u "$u")" | tr '\n' ' ')"
done
egress_rules="$(adk_egress_rules "$egress_uids" "$egress_gids")"
egress_reload=false
adk_put_file "$EGRESS_RULES" 0644 root:root <<< "$egress_rules" && egress_reload=true
egress_units=false
adk_put_file "$EGRESS_UNIT" 0644 root:root < <(adk_egress_unit "$EGRESS_RULES") && egress_units=true
# nftables.service flushes the whole ruleset on start/reload: load table adk_egress again then
adk_put_file "$NFTABLES_DROPIN" 0644 root:root < <(adk_nftables_dropin "$EGRESS_RULES") && egress_units=true
if [[ "$egress_units" == true ]]; then
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

echo "== services (gitea, caddy)"
adk_secrets_dir
adk_gitea_secrets
adk_caddy_env "${CFG[ACME_MODE]}"
adk_gitea_user
adk_render_services "$ROOT/kit.env"
adk_services_up
adk_lab_ca "$AGENT_USER"
adk_wait_https "${CFG[GITEA_DOMAIN]}"

init_out="$("$HERE/gitea-init.sh" --config "$ROOT/kit.env")" || { printf '%s\n' "$init_out"; adk_die "gitea-init.sh failed"; }
printf '%s\n' "$init_out"
ADK_CHANGES=$((ADK_CHANGES + $(grep -c '^changed:' <<< "$init_out" || true)))

echo "== ci runner"
adk_runner_binary
adk_runner_service "${CFG[GITEA_DOMAIN]}"

echo "== backup"
adk_backup_setup "${CFG[BACKUP_TARGET]}" "${CFG[CUSTOMER_NAME]}" "$ACCEPT_BACKUP_HOSTKEY"

echo
echo "setup done: $ADK_CHANGES change(s)"
echo "Next: add the employee's key (from stdin):  sudo $HERE/add-key.sh $AGENT_USER < key.pub"
echo "Gitea: https://${CFG[GITEA_DOMAIN]}/ - initial password of ${CFG[GITEA_ADMIN_USER]}: /root/adk-gitea-initial-password (if not handed over yet)"
echo "New repositories: the employee creates them, then: sudo $HERE/protect-repo.sh ${CFG[CUSTOMER_NAME]}/<repo>"
