#!/bin/sh
# Stub of deploy/update.sh for the TEST deploy contract (docs/test-vm.md). The real one (PR 4)
# adds plan, backup, migrations and rollback; this stub only starts the compose project.
# Called by test/deploy.sh in /srv/test/<project> as user adk-app:
#   deploy/update.sh --non-interactive --additive-only --version <ref>
set -eu
if [ "$#" -ne 4 ] || [ "$1" != --non-interactive ] || [ "$2" != --additive-only ] || [ "$3" != --version ]; then
  echo "usage: deploy/update.sh --non-interactive --additive-only --version <ref>" >&2
  exit 2
fi
echo "update.sh (stub): $ADK_PROJECT -> $4"
docker compose -f deploy/compose.yaml --env-file .env up -d --remove-orphans --wait
printf '%s\n' "$4" > "$ADK_STATE_DIR/version"
