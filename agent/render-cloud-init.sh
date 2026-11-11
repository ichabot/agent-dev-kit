#!/usr/bin/env bash
# Render the first-boot cloud-config of the agent VPS to stdout.
#
# Usage: agent/render-cloud-init.sh --pubkey FILE [--role agent|test]
#
#   --pubkey FILE     installer's SSH public key; installed for adk-admin in the root-owned
#                     /etc/ssh/authorized_keys/adk-admin
#   --role agent|test which server (default agent): selects the sshd drop-in
#                     (agent/sshd-adk.conf or test/sshd-adk-test.conf)
#
# Exit codes: 0 = rendered, 1 = invalid key / output too large, 2 = usage.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=../scripts/lib/pubkey.sh
source "$ROOT/scripts/lib/pubkey.sh"

TEMPLATE="$HERE/cloud-init.yaml.tmpl"
MAX_BYTES=32768   # Hetzner Cloud user_data limit

usage() { echo "usage: $0 --pubkey FILE [--role agent|test]" >&2; exit 2; }

PUBKEY="" ROLE=agent
while (($#)); do
  case "$1" in
    --pubkey) (($# >= 2)) || usage; PUBKEY="$2"; shift 2 ;;
    --role) (($# >= 2)) || usage; ROLE="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$PUBKEY" ]] || usage
case "$ROLE" in
  agent) DROPIN="$HERE/sshd-adk.conf" ;;
  test) DROPIN="$ROOT/test/sshd-adk-test.conf" ;;
  *) usage ;;
esac

rc=0
key="$(adk_read_pubkey "$PUBKEY")" || rc=$?
((rc == 0)) || exit "$rc"

# Indent the drop-in into the YAML block scalar of its write_files entry.
dropin="$(sed 's/^/      /; s/^ *$//' "$DROPIN")"

out="$(cat "$TEMPLATE")"
# Quoted replacements: '&' and '\' in the key comment stay literal.
out="${out//"@@ADMIN_PUBKEY@@"/"$key"}"
out="${out//"@@SSHD_DROPIN@@"/"$dropin"}"

if [[ "$out" == *"@@"* ]]; then
  echo "ERROR: unreplaced placeholder in $TEMPLATE" >&2
  exit 1
fi
if ((${#out} >= MAX_BYTES)); then
  echo "ERROR: rendered user_data is ${#out} bytes (limit $MAX_BYTES)" >&2
  exit 1
fi
printf '%s\n' "$out"
