# Hermes Desktop → agent VPS: connection mode

Result of the PR 1 spike. Decides how the customer's Hermes Desktop app reaches the
Hermes instance on the agent VPS.

## Options (Hermes Desktop: Settings → Gateways → Add)

| Mode | How | Open port on VPS | Login |
|---|---|---|---|
| **SSH** (chosen) | Desktop opens an SSH tunnel and starts `hermes serve` on the VPS itself | none besides SSH | SSH key |
| Remote gateway | `hermes serve --host <ip> --port 9119` runs permanently | 9119 | username/password (VPN/LAN only) or Nous Portal OAuth |
| Hermes Cloud | hosted by Nous | n/a | not applicable (self-hosted VPS) |

## Why SSH

- No extra listening service: `hermes serve` binds to `127.0.0.1` with a random port; it is
  only reachable through the tunnel. The firewall stays at SSH + Gitea + VPN.
- No shared dashboard password; access = an SSH key of the employee (revocable per key).
- The username/password provider is documented by Hermes as "trusted network only";
  OAuth would tie the customer to a Nous Portal account.

## Verified on a test container (Debian 13, Hermes v0.23.1)

1. Non-interactive key login works with `BatchMode=yes` (Desktop uses BatchMode, so a key
   with passphrase must be loaded into the SSH agent).
2. `hermes serve --isolated --port 0` prints `HERMES_DASHBOARD_READY port=<n>` and listens on
   `127.0.0.1:<n>` only.
3. Through `ssh -N -L` the API answers (`/api/status` → version 0.23.1).
4. The same port is **not** reachable directly from the LAN.
5. Protected endpoints return **401** without the session token that Desktop adopts over the tunnel.

## Requirements for the VPS (input for PR 2)

- `libatomic1` installed **before** the Hermes installer (Debian 13 minimal lacks it; the
  bundled Node fails with `libatomic.so.1: cannot open shared object file`).
- `python3` present (Desktop's remote probes use it).
- `hermes` resolvable in a login shell (`~/.local/bin` via `~/.profile`); otherwise set
  **Hermes path** in the Desktop connection to `/home/<user>/.local/bin/hermes`.
- sshd: `PasswordAuthentication no`, `PermitRootLogin no`, `AllowTcpForwarding local`
  (Desktop needs local forwarding only), `AllowUsers <hermes-user> <admin-user>`.
- Employee's public key in `~/.ssh/authorized_keys` of the Hermes user.
- No systemd unit for `hermes serve` needed; Desktop starts and stops it.

## Desktop side (customer workstation)

Settings → Gateways → Add → **SSH**: host `<user>@<vps-or-vpn-ip>:22`, test, save.
On Windows Desktop uses OpenSSH (or Git for Windows' ssh); the key must work with
`ssh -o BatchMode=yes <user>@<host> true` from a terminal.

## Open

- End-to-end test with the real Desktop app on Windows (planned in the E2E run, PR 6).
