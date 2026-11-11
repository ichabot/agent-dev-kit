#!/usr/bin/env bash
# Root steps of adk-act-runner.service around each CI job (lib/ci-runner.sh). Runs as root
# from the unit (ExecStartPre=+ prepare, ExecStopPost=+ wipe); by hand only for debugging.
#
# Usage: /opt/adk/agent/ci-reset.sh wipe|prepare [--config FILE]   (default: /opt/adk/kit.env)
#
#   wipe     stop and kill everything of user ci, delete its home, the runner state and its
#            files elsewhere, recreate home and state empty
#   prepare  wipe, rootless Docker for ci, pinned job image, new ephemeral registration
# Exit codes: 0 = done, 1 = failure, 2 = usage.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib/host.sh
source "$HERE/lib/host.sh"
# shellcheck source-path=SCRIPTDIR source=lib/rootless-user.sh
source "$HERE/lib/rootless-user.sh"
# shellcheck source-path=SCRIPTDIR source=lib/versions.sh
source "$HERE/lib/versions.sh"
# shellcheck source-path=SCRIPTDIR source=lib/gitea-admin.sh
source "$HERE/lib/gitea-admin.sh"
# shellcheck source-path=SCRIPTDIR source=lib/ci-runner.sh
source "$HERE/lib/ci-runner.sh"
# shellcheck source-path=SCRIPTDIR source=../scripts/lib/config.sh
source "$ROOT/scripts/lib/config.sh"

usage() { echo "usage: $0 wipe|prepare [--config FILE]" >&2; exit 2; }
(($# >= 1)) || usage
MODE="$1"
shift
CONFIG="$ROOT/kit.env"
while (($#)); do
  case "$1" in
    --config) (($# >= 2)) || usage; CONFIG="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$MODE" == wipe || "$MODE" == prepare ]] || usage
[[ "$(id -u)" -eq 0 ]] || { echo "ERROR: run as root" >&2; exit 2; }
id "$ADK_CI_USER" > /dev/null 2>&1 || adk_die "user $ADK_CI_USER does not exist (run setup.sh)"

adk_ci_wipe "$ADK_CI_USER" "$ADK_RUNNER_STATE"
echo "wiped: user $ADK_CI_USER (processes, home, rootless Docker, user units, runner state)"
[[ "$MODE" == prepare ]] || exit 0

load_config "$CONFIG"
((${#CFG_ERRORS[@]} == 0)) || adk_die "invalid $CONFIG (run scripts/check-config.sh)"
adk_ensure_rootless_docker "$ADK_CI_USER" > /dev/null
echo "prepared: rootless Docker for $ADK_CI_USER"
adk_user_env "$ADK_CI_USER" docker pull -q "$ADK_RUNNER_JOB_IMAGE" > /dev/null \
  || adk_die "cannot pull the job image $ADK_RUNNER_JOB_IMAGE"
echo "pulled: job image (pinned digest)"
adk_runner_register "${CFG[GITEA_DOMAIN]}" "${CFG[CUSTOMER_NAME]}"
