# Agent-VPS: Basis (PR 2a)

Ein Hetzner-Cloud-Server (Debian 13) pro Kunde. Darauf arbeitet Hermes Agent als
Entwickler; der Mitarbeiter des Kunden verbindet sich mit Hermes Desktop per SSH
(siehe `docs/hermes-remote.md`). Gitea, Runner, Caddy und Backup folgen in PR 2b.

## Was läuft wo

| Wo | Was |
|---|---|
| Rechner des Einrichters | `agent/provision.sh` (Hetzner API), `agent/bootstrap.sh` (SSH) |
| Hetzner Cloud | Firewall `adk-<kunde>-agent`, Server `adk-<kunde>-agent`, SSH-Key `adk-<kunde>-installer`, Backups an |
| VPS, als root | `/opt/adk` (Kit, root-eigen, `kit.env` 0600), Docker CE (für die Kit-Dienste ab PR 2b), sshd-Härtung, nftables-Tabelle `adk_egress`, unattended-upgrades |
| VPS, User `adk-admin` | Admin mit sudo, Login nur per Key |
| VPS, User `hermes` | Hermes Agent, eigenes rootless Docker; kein sudo, nicht in der Gruppe `docker` |

SSH-Keys liegen in `/etc/ssh/authorized_keys/<user>` (root-eigen). Ein Key, den der Agent
in `~/.ssh/authorized_keys` schreibt, wirkt nicht. sshd erlaubt `hermes` nur lokale Tunnel
zu `127.0.0.1` (Desktop); Agent-, Unix-Socket- und X11-Forwarding sowie `PermitTunnel` sind
für alle Benutzer aus.

`PermitOpen` ist nur zusätzliche Absicherung (Defense in Depth), keine Grenze: Wer eine
Shell als `hermes` hat (Mitarbeiter, Agent), hat ausgehend offenes Netz. Die Grenze zum
Cloud-Metadaten-Dienst (`169.254.169.254`, `fd00:ec2::254`) ist die nftables-Tabelle
`inet adk_egress` (`adk-egress.service`, Regeln in `/etc/adk/egress.nft`): Pakete von uid
`hermes` dorthin werden abgewiesen (`reject`, Verbindungsaufbau scheitert sofort), auch aus
seinen rootless Containern (deren Verkehr läuft über `slirp4netns` als `hermes`). Trotzdem gilt: keine Secrets in user_data oder Metadaten.

`setup.sh` liest und schreibt im Home von `hermes` nur als `hermes` selbst (`runuser`) und
bricht ab, wenn dort ein Symlink im Pfad liegt (`~/.bashrc`, `~/.config/docker` …). So kann
der Agent root nicht über einen Symlink auf Dateien wie `/etc/docker/daemon.json` oder
`/etc/shadow` umlenken. Meldung `refused … symlink`: den Symlink prüfen und entfernen, dann
`setup.sh` erneut ausführen.

## Firewall (Hetzner Cloud, nur eingehend)

| Port | Quelle |
|---|---|
| tcp 22, tcp 443, VPN (`VPN_PORT`/`VPN_PROTO`), ICMP | `CUSTOMER_IPS` |
| tcp 22 (Einrichter) | nur mit `--admin-source`, bei Übergabe entfernen |
| tcp 80 | weltweit, nur bei `ACME_MODE=http01` (ACME-Challenge + Redirect) |

Vorschau: `agent/firewall-rules.sh [--admin-source CIDR]`. Weitere Firewalls am Server
lehnt `provision.sh` ab: Hetzner addiert die Freigaben aller Firewalls eines Servers.

## Ablauf

Voraussetzung: `kit.env` ausgefüllt (`scripts/check-config.sh`), Hetzner-API-Token des
Kundenprojekts in `~/.config/hcloud-token` (eigene Datei, Modus 0600, oder
`HCLOUD_TOKEN_FILE`).

```bash
# 1. Plan ansehen (kein API-Aufruf, kein Token nötig)
agent/provision.sh --pubkey ~/.ssh/id_ed25519.pub --admin-source <eigene-IP> --dry-run
# 2. Firewall, Server, Backups anlegen (idempotent, erneut ausführbar)
agent/provision.sh --pubkey ~/.ssh/id_ed25519.pub --admin-source <eigene-IP>
# 3. Kit kopieren und setup.sh ausführen (wartet auf SSH und cloud-init)
agent/bootstrap.sh --identity ~/.ssh/id_ed25519 <IPv4>
# 4. Key des Mitarbeiters für Hermes Desktop eintragen (über stdin)
ssh adk-admin@<IPv4> sudo /opt/adk/agent/add-key.sh hermes < mitarbeiter.pub
```

- `--pubkey` braucht `provision.sh` nur zum Anlegen des Servers. Existiert er, wird kein
  SSH-Key gesucht oder hochgeladen.
- `bootstrap.sh` kopiert nur von git verwaltete Dateien und bricht ab, wenn unter
  `scripts/` oder `agent/` ungetrackte oder ignorierte Dateien liegen (z. B. ein Token).
  `setup.sh` prüft vorher, dass `/opt/adk` root gehört, für niemand sonst schreibbar ist und
  `kit.env` Modus 0600 hat.
- `add-key.sh` liest den Key von stdin. Eine Datei als Argument nimmt es nur, wenn sie root
  oder dem aufrufenden Admin gehört und weder sie noch ihr Verzeichnis für andere
  schreibbar ist. Keys also nie über `/tmp` übergeben: Dort könnte der Agent eine eigene
  Datei unterschieben.

Der LLM-API-Key wird nicht vom Kit gesetzt; das macht der Kunde in Hermes.

## Hermes-Installer und Updates

`setup.sh` lädt den offiziellen Hermes-Installer als `hermes` (nie als root) und schreibt
seine sha256 ins Log. Mit `sudo HERMES_INSTALLER_SHA256=<sha256> /opt/adk/agent/setup.sh`
läuft nur ein Installer mit genau dieser Prüfsumme. Abwägung: Ohne Pin bekommt jede
Installation den aktuellen Installer, ein kompromittierter Download träfe aber den Account
`hermes` (nicht root). Mit Pin muss die Prüfsumme bei jedem Hermes-Release nachgezogen
werden.

unattended-upgrades installiert Debian-Sicherheitsupdates und Docker CE
(`origin=Docker,label=Docker CE`) und startet bei Bedarf um 04:30 neu. Der apt-Key von
Docker ist auf den Fingerprint `9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88`
festgelegt und wird nur geladen, wenn er fehlt oder nicht passt.

## Key entfernen

```bash
sudo /opt/adk/agent/remove-key.sh --terminate hermes SHA256:…   # Fingerprint: ssh-keygen -l -f key.pub
```

Ohne `--terminate` kann sich der Key nicht mehr anmelden, offene Sitzungen und Tunnel
laufen aber weiter. `--terminate` beendet sie (`loginctl terminate-user hermes`); die
User-Dienste von `hermes` (Linger, rootless Docker) laufen weiter bzw. werden wieder
gestartet. Genau dort kann der Key-Inhaber etwas hinterlassen haben; das Skript gibt die
Prüfbefehle aus:

- Crontab: `sudo crontab -l -u hermes`
- systemd-User-Units: `~hermes/.config/systemd/user/`, `systemctl --user list-units` als `hermes`
- Container und Images im rootless Docker von `hermes` (`docker ps -a`)

Den letzten `adk-admin`-Key entfernt das Skript nur mit `--force`.

## Übergabe

Danach hat der Einrichter keinen Zugang mehr. Reihenfolge einhalten: Schritte 1–4 brauchen
noch seinen SSH-Zugang, Schritte 5–6 noch das API-Token.

1. **Admin-Key des Kunden eintragen:**
   `ssh adk-admin@<IP> sudo /opt/adk/agent/add-key.sh adk-admin < kunde-admin.pub`.
   Der Kunde prüft Login und `sudo -v` aus einem Kundennetz.
2. **`/root/.ssh/authorized_keys` leeren:** `sudo sh -c ': > /root/.ssh/authorized_keys'`.
   Cloud-Init legt dort den Hetzner-Key des Einrichters ab. Er wirkt nicht (`PermitRootLogin
   no`, root-eigene Key-Dateien), soll aber nicht bleiben.
3. **Installer-Key aus `/etc/ssh/authorized_keys/adk-admin` entfernen** (erst jetzt, der
   Kunden-Key ist eingetragen):
   `sudo /opt/adk/agent/remove-key.sh adk-admin SHA256:<installer>`.
4. **Sitzungen des Einrichters beenden:** abmelden; der Kunde prüft mit
   `loginctl list-sessions`, dass keine mehr besteht, sonst
   `sudo loginctl terminate-session <ID>`.
5. **Installer-Firewallregel entfernen:** vom Rechner des Einrichters
   `agent/provision.sh` ohne `--admin-source` und ohne `--pubkey` (ersetzt die Regeln,
   lädt keinen Key hoch).
6. **SSH-Key-Objekt `adk-<kunde>-installer` im Hetzner-Projekt löschen** (Konsole oder API).
   Sonst bleibt es für Rescue-Modus und Neuinstallation nutzbar.
7. **Der Kunde widerruft das API-Token des Einrichters und entfernt dessen
   Projekt-Mitgliedschaft.**
8. **Kontrolle durch den Kunden:** `/etc/ssh/authorized_keys/adk-admin` enthält nur
   Kunden-Keys, die Hetzner-Firewall hat keine Installer-Regel, im Projekt gibt es keine
   SSH-Keys, Tokens oder Mitglieder des Einrichters mehr.

## Was geprüft ist

- `make check`: Firewall-Regeln (nur `CUSTOMER_IPS`, Port 80 nur bei http01,
  `--admin-source` mit denselben Regeln), Cloud-Init (YAML, Key-Datei root-eigen,
  sshd-Drop-in, `restart` statt `reload`), effektive sshd-Werte (`sshd -T` gegen eine
  Debian-artige Hauptkonfiguration), `provision.sh` als Dry-Run und gegen eine simulierte
  API (Firewall beim Anlegen, Labels inkl. Kunde, fremde Firewalls, Idempotenz, ohne
  `--pubkey`, Fehler/Timeout von Actions, Nicht-JSON-Antworten, Token nie in argv/Ausgabe),
  `bootstrap.sh` (nur getrackte Dateien, `kit.env` 0600, Host-Key-Wechsel),
  Key-Verwaltung (stdin, unsichere Key-Dateien, Lock, fehlender Zeilenumbruch,
  `--terminate`), Dateizugriffe im Home nur als Benutzer und Symlink-Abwehr,
  `/opt/adk`-Prüfung, Docker-Key-Fingerprint, nftables-Regeln.
- Integrationstest auf einer Test-VM (Debian-13-Cloud-Image mit genau diesem
  Cloud-Init, ohne Hetzner-Firewall): `bootstrap.sh` zweimal, zweiter Lauf ohne
  Änderungen; `sshd -T`-Werte; root- und Passwort-Login abgelehnt; Agent- und
  Unix-Socket-Forwarding abgelehnt; `adk-admin` hat sudo, `hermes` nicht und ist nicht in
  `docker`; rootless `docker run hello-world` als `hermes`; `hermes --version`;
  Desktop-Tunnel zu `hermes serve` funktioniert, Tunnel zu anderen Zielen abgelehnt;
  selbst geschriebene `~/.ssh/authorized_keys` wirkt nicht; Symlink-Angriffe als `hermes`
  (`~/.config/docker` → `/etc/docker`, `~/.bashrc` → `/etc/shadow`) abgewiesen;
  Metadaten-Adresse für `hermes` gesperrt (sofort `EHOSTUNREACH` statt Timeout,
  Regelzähler steigt), ebenso aus seinen rootless Containern (Zähler steigt), für root
  nicht (Timeout, Zähler unverändert); `add-key.sh` über stdin; unattended-upgrades
  aktiv; Swap aktiv.
- Noch nicht geprüft (PR 6, E2E): echter Hetzner-API-Lauf, Port-Scan von außen.
