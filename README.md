# agent-dev-kit

Setup kit for running [Hermes Agent](https://github.com/NousResearch/hermes-agent) as the
full-stack developer for a single customer:

- **Agent VPS** (Hetzner Cloud): Hermes Agent + Gitea (repos, CI, container registry),
  reachable only from the customer's static IPs and VPN.
- **TEST VM** (Hetzner Cloud): Caddy with HTTPS, automatic deploys from CI, test data only.
- **PROD** (customer LAN): pulls tagged releases from Gitea and updates with
  `update.sh` — plan shown first, explicit approval for data-changing migrations,
  verified backup before every update, automatic rollback on failure.

The customer's staff reviews and approves; the agent never touches PROD.

## Status

Planning. See [docs/plan.md](docs/plan.md) (German) and the issues for the PR sequence.

## Contents

| Path | Purpose |
|---|---|
| `kit.env.example` | All placeholders (IPs, domains, VPN, DNS provider) |
| `scripts/check-config.sh` | Validates `kit.env` |
| `scripts/lib/config.sh` | Shared loader: every script reads `kit.env` through it, never `source`s it |
| `docs/plan.md` | Rollout plan |
| `docs/hermes-remote.md` | How Hermes Desktop connects to the VPS (SSH mode) |
| `docs/hermes-tuning.md` | Skills and toolsets to disable on a dev server (token savings) |

## Usage

```bash
cp kit.env.example kit.env    # fill in
scripts/check-config.sh       # validates kit.env
make check                    # shellcheck + bats (development)
```

## Requirements

- Hetzner Cloud project of the customer, `hcloud` CLI
- An LLM provider API key of the customer (subscription logins are not meant for
  third-party agents)
- Domain with DNS at a provider supported by a Caddy DNS module (or port 80 open for HTTP-01)

## License

MIT
