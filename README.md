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

In progress: agent VPS base (PR 2a). See [docs/plan.md](docs/plan.md) (German) and the
issues for the PR sequence.

## Contents

| Path | Purpose |
|---|---|
| `kit.env.example` | All placeholders (IPs, domains, VPN, DNS provider) |
| `scripts/check-config.sh` | Validates `kit.env` |
| `scripts/lib/config.sh` | Shared loader: every script reads `kit.env` through it, never `source`s it |
| `scripts/lib/cidr.py` | Firewall source rules (public only, minimum prefix), shared by all scripts |
| `scripts/lib/pubkey.sh` | SSH public key validation |
| `agent/firewall-rules.sh` | Hetzner Cloud firewall rules of the agent VPS from `kit.env` |
| `agent/render-cloud-init.sh` | First-boot cloud-config (admin user, root-owned keys, sshd hardening) |
| `agent/provision.sh` | Creates firewall, server and backups via the Hetzner Cloud API (`--dry-run`) |
| `agent/bootstrap.sh` | Copies the kit to the VPS and runs `agent/setup.sh` there |
| `agent/setup.sh` | On the VPS: packages, swap, Docker, user `hermes` with rootless Docker, egress limits (nftables), Hermes Agent |
| `agent/add-key.sh`, `agent/remove-key.sh` | Manage SSH keys in the root-owned key files (key from stdin; `--terminate` ends sessions) |
| `agent/sshd-adk.conf` | sshd drop-in (key-only, no forwarding except Desktop's loopback tunnel) |
| `agent/lib/` | Setup helpers; `user-file.sh` does every file operation in a user's home as that user |
| `docs/agent-vps.md` | Agent VPS: what runs where, commands in order (German) |
| `docs/plan.md` | Rollout plan |
| `docs/hermes-remote.md` | How Hermes Desktop connects to the VPS (SSH mode) |
| `docs/hermes-tuning.md` | Skills and toolsets to disable on a dev server (token savings) |

## Usage

```bash
cp kit.env.example kit.env    # fill in
scripts/check-config.sh       # validates kit.env
agent/provision.sh --pubkey ~/.ssh/id_ed25519.pub --dry-run   # see docs/agent-vps.md
make check                    # shellcheck + bats (development)
```

## Requirements

- Hetzner Cloud project of the customer and an API token (no `hcloud` CLI needed)
- On the installer's machine: bash, curl, ssh, rsync, python3
- An LLM provider API key of the customer (subscription logins are not meant for
  third-party agents)
- Domain with DNS at a provider supported by a Caddy DNS module (or port 80 open for HTTP-01)

## License

MIT
