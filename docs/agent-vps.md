# Agent-VPS: Basis (PR 2a)

Ein Hetzner-Cloud-Server (Debian 13) pro Kunde. Darauf arbeitet Hermes Agent als
Entwickler; der Mitarbeiter des Kunden verbindet sich mit Hermes Desktop per SSH
(siehe `docs/hermes-remote.md`). Gitea, Runner, Caddy und Backup folgen in PR 2b.

## Was läuft wo

| Wo | Was |
|---|---|
| Rechner des Einrichters | `agent/provision.sh` (Hetzner API), `agent/bootstrap.sh` (SSH) |
| Hetzner Cloud | Firewall `adk-<kunde>-agent`, Server `adk-<kunde>-agent`, SSH-Key `adk-<kunde>-installer`, Backups an |
| VPS, als root | `/opt/adk` (Kit, root-eigen, `kit.env` 0600), Docker CE (für die Kit-Dienste ab PR 2b), sshd-Härtung, unattended-upgrades |
| VPS, User `adk-admin` | Admin mit sudo, Login nur per Key |
| VPS, User `hermes` | Hermes Agent, eigenes rootless Docker; kein sudo, nicht in der Gruppe `docker` |

SSH-Keys liegen in `/etc/ssh/authorized_keys/<user>` (root-eigen). Ein Key, den der Agent
in `~/.ssh/authorized_keys` schreibt, wirkt nicht. `hermes` darf nur zu `127.0.0.1`
tunneln (Desktop), keine Tunnel ins Docker-Netz oder zum Metadaten-Dienst.

## Firewall (Hetzner Cloud, nur eingehend)

| Port | Quelle |
|---|---|
| tcp 22, tcp 443, VPN (`VPN_PORT`/`VPN_PROTO`), ICMP | `CUSTOMER_IPS` |
| tcp 22 (Einrichter) | nur mit `--admin-source`, bei Übergabe entfernen |
| tcp 80 | weltweit, nur bei `ACME_MODE=http01` (ACME-Challenge + Redirect) |

Vorschau: `agent/firewall-rules.sh [--admin-source CIDR]`.

## Ablauf

Voraussetzung: `kit.env` ausgefüllt (`scripts/check-config.sh`), Hetzner-API-Token des
Kundenprojekts in `~/.config/hcloud-token` (Modus 0600, oder `HCLOUD_TOKEN_FILE`).

```bash
# 1. Plan ansehen (kein API-Aufruf, kein Token nötig)
agent/provision.sh --pubkey ~/.ssh/id_ed25519.pub --admin-source <eigene-IP> --dry-run
# 2. Firewall, Server, Backups anlegen (idempotent, erneut ausführbar)
agent/provision.sh --pubkey ~/.ssh/id_ed25519.pub --admin-source <eigene-IP>
# 3. Kit kopieren und setup.sh ausführen (wartet auf SSH und cloud-init)
agent/bootstrap.sh --identity ~/.ssh/id_ed25519 <IPv4>
# 4. Key des Mitarbeiters für Hermes Desktop eintragen
scp mitarbeiter.pub adk-admin@<IPv4>:/tmp/
ssh adk-admin@<IPv4> sudo /opt/adk/agent/add-key.sh hermes /tmp/mitarbeiter.pub
```

Key entfernen: `sudo /opt/adk/agent/remove-key.sh hermes SHA256:…` (Fingerprint aus
`ssh-keygen -l -f key.pub`). Den letzten `adk-admin`-Key entfernt das Skript nur mit
`--force`.

Bei der Übergabe: Admin-Key des Kunden eintragen (`add-key.sh adk-admin …`), eigenen Key
entfernen, `provision.sh` ohne `--admin-source` erneut ausführen (ersetzt die
Firewall-Regeln).

Der LLM-API-Key wird nicht vom Kit gesetzt; das macht der Kunde in Hermes.

## Was geprüft ist

- `make check`: Firewall-Regeln (nur `CUSTOMER_IPS`, Port 80 nur bei http01,
  `--admin-source` mit denselben Regeln), Cloud-Init (YAML, Key-Datei root-eigen,
  sshd-Drop-in, `restart` statt `reload`), `provision.sh` als Dry-Run und gegen eine
  simulierte API (Firewall beim Anlegen, Labels, Idempotenz, fremde Objekte unberührt,
  Token nie in argv/Ausgabe), Key-Verwaltung.
- Integrationstest auf einer Test-VM (Debian-13-Cloud-Image mit genau diesem
  Cloud-Init, ohne Hetzner-Firewall): `bootstrap.sh` und zweiter `setup.sh`-Lauf ohne
  Änderungen; `sshd -T`-Werte; root- und Passwort-Login abgelehnt; `adk-admin` hat sudo,
  `hermes` nicht und ist nicht in `docker`; rootless `docker run hello-world` als
  `hermes`; `hermes --version`; Desktop-Tunnel zu `hermes serve` funktioniert, Tunnel zu
  anderen Zielen abgelehnt; selbst geschriebene `~/.ssh/authorized_keys` wirkt nicht;
  unattended-upgrades aktiv; Swap aktiv.
- Noch nicht geprüft (PR 6, E2E): echter Hetzner-API-Lauf, Port-Scan von außen.
