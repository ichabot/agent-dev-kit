#!/usr/bin/env bash
# Create (or bring in line) the TEST VM: agent/provision.sh --role test (see there).
#
# Usage: test/provision.sh [--pubkey FILE] [--admin-source CIDR]... [--config FILE] [--dry-run]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$HERE/../agent/provision.sh" --role test "$@"
