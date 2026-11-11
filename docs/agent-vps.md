# Agent-VPS

Ein Hetzner-Cloud-Server (Debian 13) pro Kunde. Darauf arbeitet Hermes Agent als
Entwickler; der Mitarbeiter des Kunden verbindet sich mit Hermes Desktop per SSH
(siehe `docs/hermes-remote.md`). Auf demselben Server laufen Gitea (Repos, CI, Container-
Registry), der CI-Runner, Caddy (HTTPS) und das nächtliche Backup (Abschnitt
[Dienste](#dienste-gitea-caddy-ci-runner-backup)).

## Was läuft wo

| Wo | Was |
|---|---|
| Rechner des Einrichters | `agent/provision.sh` (Hetzner API), `agent/bootstrap.sh` (SSH) |
| Hetzner Cloud | Firewall `adk-<kunde>-agent`, Server `adk-<kunde>-agent`, SSH-Key `adk-<kunde>-installer`, Backups an |
| VPS, als root | `/opt/adk` (Kit, root-eigen, `kit.env` 0600), Docker CE mit Gitea + Caddy (`/opt/adk/services`), sshd-Härtung, nftables-Tabelle `adk_egress`, unattended-upgrades, Backup-Timer |
| VPS, User `adk-admin` | Admin mit sudo, Login nur per Key |
| VPS, User `hermes` | Hermes Agent, eigenes rootless Docker; kein sudo, nicht in der Gruppe `docker` |
| VPS, User `ci` | Gitea-Runner (`adk-act-runner.service`) mit eigenem rootless Docker; kein sudo, kein SSH-Login |
| VPS, Systemuser `adk-gitea` | Besitzer der Gitea-Daten in `/var/lib/adk/gitea` (kein Login) |

SSH-Keys liegen in `/etc/ssh/authorized_keys/<user>` (root-eigen). Ein Key, den der Agent
in `~/.ssh/authorized_keys` schreibt, wirkt nicht. sshd erlaubt `hermes` nur lokale Tunnel
zu `127.0.0.1` (Desktop); Agent-, Unix-Socket- und X11-Forwarding sowie `PermitTunnel` sind
für alle Benutzer aus.

`PermitOpen` ist nur zusätzliche Absicherung (Defense in Depth), keine Grenze: Wer eine
Shell als `hermes` hat (Mitarbeiter, Agent), hat ausgehend offenes Netz. Die Grenze zum
Cloud-Metadaten-Dienst (`169.254.169.254`, `fd00:ec2::254`) ist die nftables-Tabelle
`inet adk_egress` (`adk-egress.service`, Regeln in `/etc/adk/egress.nft`): Pakete von uid
`hermes` und `ci` dorthin werden abgewiesen (`reject`, Verbindungsaufbau scheitert sofort),
auch aus ihren rootless Containern bzw. CI-Jobs (deren Verkehr läuft über `slirp4netns` als
`hermes` bzw. `ci`). Dieselbe Tabelle sperrt für beide die Container des root-Dockers außer
auf Port 80/443 (Caddy): Gitea ist nur über Caddy erreichbar, nicht direkt über seine
Container-IP. Trotzdem gilt: keine Secrets in user_data oder Metadaten.

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

Auf dem Server selbst lauschen nur sshd (22) und Caddy (443, bei `http01` auch 80). Gitea
hat keinen Host-Port, Caddys Admin-API (`:2019`) ist abgeschaltet (`admin off`), HTTP/3
(udp/443) ebenfalls. Gitea-SSH ist aus: Git läuft nur über HTTPS, die Firewall bleibt gleich.

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

Vor dem Bootstrap muss der DNS-Eintrag `GITEA_DOMAIN` → öffentliche IPv4 (und ggf. IPv6) des
Servers existieren: Der Runner spricht Gitea unter `https://GITEA_DOMAIN` an, und bei
`ACME_MODE=http01` braucht Let's Encrypt ihn ohnehin.

Bei `ACME_MODE=dns01` braucht Caddy das API-Token des DNS-Anbieters. Der erste
`setup.sh`-Lauf bricht an dieser Stelle mit einer Anleitung ab; dann:

```bash
ssh adk-admin@<IPv4> sudo /opt/adk/agent/set-secret.sh dns-api-token < dns-token.txt
ssh adk-admin@<IPv4> sudo /opt/adk/agent/setup.sh
```

`set-secret.sh` liest nur von stdin (nie als Argument, das sähe jeder in `ps`), nimmt nur
Namen aus seiner Liste an, schreibt `/opt/adk/secrets/<name>` mit 0600 und gibt den Wert nie
aus.

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

## Dienste (Gitea, Caddy, CI-Runner, Backup)

`setup.sh` richtet nach der Basis die Dienste ein (idempotent, zweiter Lauf: 0 Änderungen):

| Dienst | Wie | Wo |
|---|---|---|
| Gitea | Docker Compose (root), Image mit Version und Digest festgelegt, SQLite | `/opt/adk/services/compose.yaml`, Daten `/var/lib/adk/gitea` (root 0700 darüber) |
| Caddy | Docker Compose (root), TLS über ACME DNS-01 (eigenes Image mit `caddy-dns`-Modul) oder HTTP-01 | `/opt/adk/services/Caddyfile`, Zertifikate im Volume `adk_caddy_data` |
| CI-Runner | Gitea-Runner (Binary mit sha256 geprüft) als Systemdienst `adk-act-runner.service`, User `ci`, dessen rootless Docker | Konfiguration `/etc/adk/runner.yaml` (root-eigen), Zustand `/var/lib/adk-runner` (`ci`, 0700) |
| Backup | `adk-backup.timer` täglich 03:30 (vor dem Neustart um 04:30) → `agent/backup.sh` | `/var/backups/adk/<Zeit>/` (root 0700), 7 Tage |

Gitea-Einstellungen: Registrierung aus, Anmeldung für alles nötig (`REQUIRE_SIGNIN_VIEW`),
Actions und Packages (Container-Registry) an, `ROOT_URL https://GITEA_DOMAIN/`, kein SSH.
Caddy setzt HSTS, `nosniff`, `X-Frame-Options DENY`, `Referrer-Policy` und entfernt den
`Server`-Header; eine Größenbeschränkung für Uploads gibt es nicht (Registry-Layer über
100 MB sind getestet).

### Konten in Gitea (`agent/gitea-init.sh`)

| Konto | Rechte | Anmeldung |
|---|---|---|
| `GITEA_ADMIN_USER` (Mitarbeiter) | Site-Admin, Eigentümer der Organisation `CUSTOMER_NAME` | Startpasswort in `/root/adk-gitea-initial-password` (nur root), muss bei der ersten Anmeldung geändert werden |
| `agent-bot` | Bot-Konto, Team `developers`: Schreiben in allen Repos der Organisation, kein Admin, darf keine Repos anlegen | kein Passwort, nur Token (bei `hermes`) |
| `prod-pull` | Bot-Konto, Team `readers`: Lesen von Code, Releases, Packages | Token wird pro PROD-Server später angelegt |

`agent-bot` darf keine Repos anlegen, weil Gitea den Ersteller eines Repos zu dessen Admin
macht – damit könnte der Agent den Branch-Schutz seines Repos abschalten. Neue Repos legt
der Mitarbeiter an; `agent-bot` hat über das Team sofort Schreibrechte. Branch-Schutz für
`main` richtet der Mitarbeiter pro Repo ein (Einstellungen → Branches); `agent-bot` kann ihn
nicht ändern, nicht mergen (bei Merge-Whitelist) und keine Organisations- oder
Repo-Einstellungen ändern (im Integrationstest jeweils HTTP 403).

Das Token von `agent-bot` (Scopes `write:repository`, `write:issue`, `read:user`,
`write:package`, `read:organization`) liegt in `~hermes/.config/gitea/token` (0600, als
`hermes` geschrieben). Ein Git-Credential-Helper (`~hermes/.config/gitea/git-credential`,
eingetragen in `~hermes/.gitconfig`) gibt es für `https://GITEA_DOMAIN` an Git weiter. Fehlt
die Datei oder ist das Token ungültig, erzeugt `gitea-init.sh` ein neues und widerruft die
alten.

`gitea-init.sh` braucht für Organisation und Teams kurz ein Admin-Token des Mitarbeiters: Es
wird über stdin in den Container gereicht (nie als Argument), am Ende gelöscht und geprüft,
dass es nicht mehr gilt. Hat der Mitarbeiter sein Passwort noch nicht geändert, wird das
Kennzeichen „muss Passwort ändern“ dafür kurz aufgehoben und danach wieder gesetzt.

### Erste Anmeldung des Mitarbeiters

1. Einrichter liest das Startpasswort aus (`ssh adk-admin@<IP> sudo cat /root/adk-gitea-initial-password`)
   und gibt es persönlich weiter, dann `sudo rm /root/adk-gitea-initial-password`.
2. Mitarbeiter öffnet `https://GITEA_DOMAIN/`, meldet sich an und muss sofort ein eigenes
   Passwort setzen; danach 2FA einrichten (Einstellungen → Sicherheit).
3. Mitarbeiter legt das erste Repo in der Organisation an und schützt `main` (Push nur über
   Pull Request, Merge nur durch ihn).

### CI-Runner

Jobs laufen in Containern des rootless Dockers von `ci` (Label `ubuntu-latest`, Image mit
Digest festgelegt). Der Runner reicht diesen Socket in die Jobs durch (`docker_host: ""`),
damit Jobs `docker build` und `docker push` in die Gitea-Registry ausführen können. Folgen:

- Ein Job hat höchstens die Rechte des Users `ci`: kein root, kein Zugriff auf den
  root-Docker-Socket (getestet: verbunden wird nicht), keine fremden Homes, kein
  Metadaten-Dienst.
- Jobs untereinander sind nicht getrennt: Ein Job kann Container anderer Jobs sehen und die
  Runner-Registrierung (`/var/lib/adk-runner/.runner`) lesen. Das ist hinnehmbar, weil alle
  Repos demselben Kunden gehören und `agent-bot` Workflows ohnehin selbst schreiben kann.
- `privileged: false`, `valid_volumes: []` (Workflows dürfen keine Host-Pfade einbinden),
  eigenes Netz pro Job (`network: ""`), 2 Jobs gleichzeitig. Der eingebaute Cache-Server ist
  aus (er hätte keinen Zugriffsschutz).

Der Runner erreicht Gitea über `https://GITEA_DOMAIN`, also über die öffentliche IP des
Servers. Das funktioniert auf demselben Server ohne Umweg über die Hetzner-Firewall
(Verbindungen an die eigene IP bleiben lokal, Docker leitet Port 443 an Caddy weiter).

### Wo liegen Secrets

| Datei | Inhalt |
|---|---|
| `/opt/adk/secrets/gitea-*` (root, 0600, Verzeichnis 0700) | Gitea `SECRET_KEY`, `INTERNAL_TOKEN`, JWT-Secrets – einmal erzeugt, nie ausgegeben; im Container als Docker-Secret |
| `/opt/adk/secrets/dns-api-token`, `caddy.env` | DNS-API-Token für Caddy (nur `dns01`) |
| `/root/adk-gitea-initial-password` | Startpasswort des Mitarbeiters, nach Übergabe löschen |
| `~hermes/.config/gitea/token` | Token von `agent-bot` |
| `/var/lib/adk-runner/.runner` | Registrierung des Runners (User `ci`) |
| `/root/.ssh/adk-backup` | SSH-Key für das Off-Site-Backup (nur mit `BACKUP_TARGET`) |

### Backup und Restore

Täglich um 03:30 schreibt `agent/backup.sh` nach `/var/backups/adk/<UTC-Zeit>/`:
`gitea-dump.tar.gz` (`gitea dump` als Container-User), `adk-secrets.tar`
(`/opt/adk/secrets` + `kit.env`), `hermes-home.tar` (Home von `hermes`, als `hermes`
gepackt, Symlinks werden nicht verfolgt; ohne Caches, `node_modules`, rootless-Docker-Daten
und die von `setup.sh` neu installierbare Hermes-Software) und `MANIFEST` (sha256). Aufbewahrt
werden 7 Tage, das neueste vollständige Backup nie gelöscht. Schlägt ein Teil fehl, laufen
die anderen trotzdem, das Verzeichnis bekommt eine Datei `FAILED` und der Dienst endet mit
Fehler (`systemctl status adk-backup.service`, `journalctl -u adk-backup`).

```bash
sudo systemctl start adk-backup.service          # Backup sofort
systemctl list-timers adk-backup.timer           # nächster Lauf
sudo ls /var/backups/adk/
# Gitea zurückspielen (stoppt Gitea, alte Daten bleiben als /var/lib/adk/gitea.before-restore-<Zeit>)
sudo /opt/adk/agent/restore.sh --yes /var/backups/adk/<Zeit>
# zusätzlich: --secrets (neuer Server) und/oder --hermes-home (als hermes entpackt)
sudo /opt/adk/agent/restore.sh --gitea --hermes-home --yes /var/backups/adk/<Zeit>
```

`restore.sh` prüft zuerst die sha256-Summen und verweigert Teile, die in `FAILED` stehen.
Ohne `--yes` prüft es nur. Nach dem Gitea-Restore läuft Gitea wieder und `/api/healthz`
antwortet; danach `/var/lib/adk/gitea.before-restore-<Zeit>` löschen.

Neuer Server nach Totalausfall: `provision.sh` + `bootstrap.sh` mit derselben `kit.env`,
Backup-Verzeichnis nach `/var/backups/adk/` kopieren, dann
`restore.sh --secrets --gitea --hermes-home --yes <dir>`, `sudo rm /var/lib/adk-runner/.runner`
(die neue Runner-Registrierung steht nicht im alten Stand) und `setup.sh` erneut.

**Off-Site:** Mit `BACKUP_TARGET=sftp://user@host[:port]/pfad` (z. B. Hetzner Storage Box,
Port 23) erzeugt `setup.sh` einmal den Key `/root/.ssh/adk-backup` und zeigt nur dessen
öffentlichen Teil – der kommt in die `authorized_keys` des Ziels. `backup.sh` kopiert jedes
neue Verzeichnis per `rsync` über SSH dorthin; die Aufbewahrung am Ziel regelt der Kunde
(z. B. Snapshots der Storage Box). Ein Backup auf demselben Server ersetzt kein Off-Site-Backup;
die Hetzner-Backups des Servers sind zusätzlich an.

### Versionen aktualisieren

Alle Versionen stehen in `agent/lib/versions.sh` (Gitea, Caddy, Caddy-Builder,
`caddy-dns`-Module, Gitea-Runner mit sha256 je Architektur, Job-Image). Digests holen
(`https://hub.docker.com/v2/repositories/<image>/tags/<tag>` → `digest`), sha256 des Runners
von `https://dl.gitea.com/gitea-runner/<version>/`; dann Kit committen, `bootstrap.sh` erneut.
Vorher Backup, bei Gitea Release-Notes auf Breaking Changes prüfen.

### Labor-Modus (nur Test)

Ohne öffentliches DNS (Test-VM) gibt es zwei Umgebungsvariablen, bewusst keine
`kit.env`-Schlüssel: `ADK_TLS_INTERNAL=1` (Caddy nutzt seine interne CA statt ACME; die CA
wird auf dem Server als vertrauenswürdig eingetragen und in Jobs eingebunden) und
`ADK_RUNNER_ADD_HOST=<ip>` (Jobs lösen `GITEA_DOMAIN` auf diese IP auf). `bootstrap.sh` reicht
beide an `setup.sh` weiter; auf dem Server muss `GITEA_DOMAIN` dann per `/etc/hosts` auflösen.

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
8. **Gitea:** Startpasswort persönlich übergeben, `sudo rm /root/adk-gitea-initial-password`;
   der Mitarbeiter hat sein Passwort geändert und 2FA eingerichtet.
9. **Kontrolle durch den Kunden:** `/etc/ssh/authorized_keys/adk-admin` enthält nur
   Kunden-Keys, die Hetzner-Firewall hat keine Installer-Regel, im Projekt gibt es keine
   SSH-Keys, Tokens oder Mitglieder des Einrichters mehr.

## Was geprüft ist

- `make check`: Firewall-Regeln (nur `CUSTOMER_IPS`, Port 80 nur bei http01,
  `--admin-source` mit denselben Regeln), Cloud-Init (YAML, Key-Datei root-eigen,
  sshd-Drop-in, `restart` statt `reload`), effektive sshd-Werte (`sshd -T` gegen eine
  Debian-artige Hauptkonfiguration), `provision.sh` als Dry-Run und gegen eine simulierte
  API (Firewall beim Anlegen, Labels inkl. Kunde, fremde Firewalls, Idempotenz, ohne
  `--pubkey`, Fehler/Timeout von Actions, Nicht-JSON-Antworten, Token nie in argv/Ausgabe),
  `bootstrap.sh` (nur getrackte Dateien, `kit.env` 0600, Host-Key-Wechsel, Labor-Variablen),
  Key-Verwaltung (stdin, unsichere Key-Dateien, Lock, fehlender Zeilenumbruch,
  `--terminate`), Dateizugriffe im Home nur als Benutzer und Symlink-Abwehr,
  `/opt/adk`-Prüfung, Docker-Key-Fingerprint, nftables-Regeln.
- `make check`, Dienste: neue `kit.env`-Schlüssel (Gitea-Namensregeln, reservierte Namen),
  Caddyfile je Modus (`admin off`, `tls internal` nur mit Labor-Variable, Header, kein
  Body-Limit), Compose (kein Gitea-Host-Port, Images mit Digest, Secrets nur als Dateien,
  Gitea-uid), Runner-Konfiguration, `set-secret.sh` (Liste, 0600, kein Echo, Symlinks),
  `gitea-init.sh` gegen ein simuliertes Gitea (Konten, Teams, Passwort nur in der Datei,
  Token nur bei `hermes`, temporäres Token gelöscht, Idempotenz, abweichende Teams,
  Bot als Admin/Owner), `backup.sh` (Inhalt, Ausschlüsse, Symlinks, Aufbewahrung, Fehler),
  `restore.sh` (Argumente, Prüfsummen, `FAILED`).
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
- Integrationstest Dienste (Test-VM mit `ADK_TLS_INTERNAL=1`): Gitea über Caddy per HTTPS,
  Header gesetzt; offen nur 22 und 443, Gitea auf keinem Host-Port, `:2019` zu (auch im
  Container); `hermes`/`ci` erreichen Gitea nicht direkt über die Container-IP;
  Mitarbeiter-Login führt zur Passwortänderung, API mit Startpasswort 403; `agent-bot` (Token
  aus der Datei von `hermes`, als `hermes`) klont und pusht per Credential-Helper, Push auf
  geschütztes `main`, Repo anlegen, Branch-Schutz/Repo-/Org-Einstellungen ändern, Merge und
  Owner-Beitritt abgelehnt; Workflow im rootless Runner: `docker build` + Push in die
  Registry und ein Layer über 100 MB grün, root-Docker-Socket im Job nicht nutzbar,
  Metadaten-Dienst für `ci` gesperrt (Zähler steigt); Backup per systemd → Repo löschen →
  `restore.sh` → Repo, Commits und Registry-Paket wieder da; Restore des Homes als `hermes`;
  Timer gelistet.
- Noch nicht geprüft (PR 6, E2E): echter Hetzner-API-Lauf, ACME mit echtem DNS-Anbieter,
  Off-Site-Backup auf eine Storage Box, Port-Scan von außen.
