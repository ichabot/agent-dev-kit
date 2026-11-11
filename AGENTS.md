# AGENTS.md – conventions for agent-dev-kit

## Gate

`make check` = shellcheck (scripts + bats files) + `bats tests/`. Must be green before every
commit; runs in GitHub Actions on every push / PR.

## Rules

- Public repo: no real customer names, IPs, hostnames, internal servers or paths.
  Use placeholders from `kit.env.example` and documentation ranges
  (203.0.113.0/24, 198.51.100.0/24, 2001:db8::/32, example.com) in tests.
- `kit.env` is read through `scripts/lib/config.sh` (`load_config`), never `source`d.
  Every new key goes into `ADK_KEYS` there and into `kit.env.example` (a test keeps both in sync).
- No secrets in the repo, in logs or on stdout. Generated secrets go to files with mode 0600.
- Shell: bash, `set -euo pipefail`, `LC_ALL=C` where regexes validate input, shellcheck-clean,
  tests first (bats).
- Code, comments, README: English. Plan and customer-facing docs: German.
- One PR per section of `docs/plan.md`, squash merge, close its issue with a comment.
