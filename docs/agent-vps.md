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
`inet adk_egress` (`adk-egress.service`, Regeln in `/etc/adk/egress.nft`). Abgewiesen
(`reject`, Verbindungsaufbau scheitert sofort) werden Pakete

- von uid und gid `hermes` und `ci` **und ihren Sub-IDs** aus `/etc/subuid`/`/etc/subgid`:
  In einem eigenen User-Namespace (`unshare --map-auto`, rootless Container mit `--user`)
  kann ein Benutzer nur zu diesen IDs wechseln (getestet mit `unshare --user --map-auto
  --map-root-user` + `setpriv --reuid=1`: ohne Sub-IDs in den Regeln war Gitea direkt
  erreichbar, jetzt nicht; `DOCKERD_ROOTLESS_ROOTLESSKIT_NET=host` lehnt das installierte
  rootless Docker ab);
- als zweite Schicht von **allen Prozessen in der cgroup `user.slice`**: alle Sitzungen und
  User-Manager, also auch rootless Docker samt Containern, egal mit welcher ID. Das betrifft
  auch Admin-Sitzungen (`sudo curl 169.254.169.254` aus einer SSH-Sitzung von `adk-admin`
  wird ebenfalls abgewiesen); Systemdienste (Docker, Caddy, Backup) liegen in `system.slice`
  und sind nicht betroffen.

Dieselbe Tabelle sperrt für diese Prozesse die Container des root-Dockers außer auf Port
80/443 (Caddy): Gitea ist nur über Caddy erreichbar, nicht direkt über seine Container-IP.
Trotzdem gilt: keine Secrets in user_data oder Metadaten.

Die Tabelle bleibt geladen, auch wenn jemand nftables neu lädt: Debians
`/etc/nftables.conf` beginnt mit `flush ruleset` und würde sie mitlöschen. Deshalb lädt ein
Drop-in (`/etc/systemd/system/nftables.service.d/50-adk-egress.conf`) sie nach jedem Start
und Reload von `nftables.service` sofort wieder, und `adk-egress.service` hängt per `PartOf=`
an `nftables.service` (Stop/Neustart wirken mit). Der CI-Runner läuft nur zusammen mit den
Regeln (`Requires=`/`BindsTo=adk-egress.service`) und startet nicht, wenn die Tabelle fehlt;
ein Neustart der Regeln beendet einen laufenden Job (mit Wipe). Nicht abgedeckt ist ein
`nft flush ruleset` oder `nft -f /etc/nftables.conf` von Hand (an systemd vorbei): Dann fehlt
die Tabelle, bis `sudo systemctl restart adk-egress` läuft (der Runner startet so lange keinen
neuen Job). Debians `flush ruleset` entfernt außerdem die Regeln von Docker (Port 443 zu
Caddy); nach einem Neustart von nftables daher `sudo systemctl restart docker`.

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
aus. Ein neues Token (Rotation) gilt nach dem nächsten `setup.sh`-Lauf: Caddy wird dann neu
erzeugt (ein Neustart allein läse die Umgebung nicht neu).

**`DNS_PROVIDER=hetzner`: Das Token ist ein Hetzner-Cloud-API-Token** (caddy-dns/hetzner v2
nutzt die Cloud-API). Es hat Lese- und Schreibrechte auf das **ganze Projekt**: Server
löschen, Rescue-Modus mit eigenem Key (= root auf dem Server), Firewalls ändern. Das Token
liegt in der Umgebung des aus dem Internet erreichbaren Caddy und in den Backups. Deshalb:

- Die DNS-Zone liegt in einem **eigenen Hetzner-Projekt, das sonst nichts enthält** (keine
  Server, keine Firewalls, keine weiteren Zonen); das Token stammt aus diesem Projekt.
- Alternative: `_acme-challenge.<GITEA_DOMAIN>` per CNAME an eine eigene, nur dafür genutzte
  Zone delegieren und das Token nur für diese Zone ausstellen.
- Nie das Token des Projekts verwenden, in dem der Agent-VPS liegt.

`scripts/check-config.sh` erinnert bei `hetzner` mit einer Warnung daran. Andere Anbieter
(cloudflare, ionos, desec) erlauben Tokens nur für eine Zone; auch dort das Token so eng wie
möglich ausstellen.

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
| `agent-bot` | Bot-Konto, Team `developers`: Code, Issues, Pull Requests, Wiki schreiben; Releases, Packages (Registry) und Actions nur lesen; kein Admin, darf keine Repos anlegen (weder in der Organisation noch im eigenen Namensraum) | kein Passwort, nur Token (bei `hermes`) |
| `prod-pull` | Bot-Konto, Team `readers`: Lesen von Code, Releases, Packages; darf keine Repos anlegen | Token wird pro PROD-Server später angelegt |

`agent-bot` darf keine Repos anlegen, weil Gitea den Ersteller eines Repos zu dessen Admin
macht – damit könnte der Agent den Branch-Schutz seines Repos abschalten (in der
Organisation: Team ohne „Repos anlegen“; im eigenen Namensraum: `max_repo_creation 0`, dort
wäre er Admin mit eigenem Runner, Secrets und Webhooks).

Die Teams `developers` und `readers` gelten **nicht** für alle Repos der Organisation. Ein
neues Repo ist für `agent-bot` (und `prod-pull`) zunächst unsichtbar; Zugriff bekommen die
Teams erst durch `protect-repo.sh`, und zwar erst, nachdem der Schutz eingerichtet und
geprüft ist. Ablauf für jedes neue Repo:

1. Der Mitarbeiter legt das Repo in der Organisation an.
2. `protect-repo.sh` schützt es (siehe unten) und gibt danach den Teams Zugriff.
3. Erst jetzt kann der Agent (`agent-bot`) dort Branches pushen und Pull Requests öffnen.

**Schutz und Zugriff** (Gitea kennt keinen Organisations-Standard):

```bash
ssh adk-admin@<IP> sudo /opt/adk/agent/protect-repo.sh <CUSTOMER_NAME>/<repo>
# mit CI-Pflicht: --status-check "<workflow> / <job> (pull_request)" (genauer Kontext aus einem Commit)
```

`protect-repo.sh` (idempotent, setzt Abweichungen zurück) richtet ein:

- Standard-Branch: kein direkter Push für niemanden (nur über Pull Request), kein Force-Push,
  Merge nur durch `GITEA_ADMIN_USER`, 1 Freigabe, die nur von `GITEA_ADMIN_USER` zählt,
  veraltete Freigaben werden bei neuen Commits verworfen, abgelehnte Reviews und offene
  Review-Anfragen blockieren, keine Bypass-Liste; optional Pflicht-Statusprüfungen.
- Tags: Regel `*`, nur `GITEA_ADMIN_USER` darf Tags anlegen oder löschen (Releases/Tags
  von `agent-bot` und CI-Jobs werden abgelehnt). Weitere Tag-Regeln, die mehr Benutzer
  erlauben, meldet das Skript als Fehler.
- Danach (nur wenn die Prüfung des Schutzes bestanden ist): Teams `developers` und `readers`
  bekommen Zugriff auf das Repo.

Der Mitarbeiter legt das Repo an und führt das Skript aus bzw. bittet den Einrichter/Admin
darum (der Skill „Projekt anlegen“ aus PR 5 verweist darauf). `gitea-init.sh` (und damit jeder
`setup.sh`-Lauf) listet Repos der Organisation ohne diesen Schutz als `WARNING` und **nimmt
dem Team `developers` dort den Zugriff** (z. B. wenn der Schutz später entfernt wurde);
geschützte Repos ohne Team-Zugriff meldet es ebenfalls. `agent-bot` kann den Schutz nicht
ändern, nicht mergen, keine Tags pushen und keine Organisations- oder Repo-Einstellungen
ändern (im Integrationstest jeweils abgelehnt).

Das Token von `agent-bot` (Scopes `write:repository`, `write:issue`, `read:user`,
`read:organization`, `read:package` – kein `write:package`: Images in der Registry sind das,
was PROD zieht) liegt in `~hermes/.config/gitea/token` (0600, als `hermes` geschrieben).
Ein vorhandenes Token mit anderen Scopes (ältere Kit-Version) wird ersetzt. Ein Git-Credential-Helper (`~hermes/.config/gitea/git-credential`,
eingetragen in `~hermes/.gitconfig`) gibt es für `https://GITEA_DOMAIN` an Git weiter. Fehlt
die Datei oder ist das Token ungültig, erzeugt `gitea-init.sh` ein neues und widerruft die
alten.

`gitea-init.sh` und `protect-repo.sh` brauchen kurz ein Admin-Token des Mitarbeiters: Es
wird über stdin in den Container gereicht (nie als Argument), am Ende gelöscht und geprüft,
dass es nicht mehr gilt. Hat der Mitarbeiter sein Passwort noch nicht geändert (Kennzeichen
gesetzt oder Startpasswort-Datei noch vorhanden), wird das Kennzeichen „muss Passwort
ändern“ dafür kurz aufgehoben und am Ende **zuerst** wieder gesetzt – auch wenn der Lauf
scheitert. Eine Markierungsdatei (`/root/.adk-gitea-must-change-pending`) sorgt dafür, dass
nach einem abgebrochenen Lauf der nächste das Kennzeichen wieder setzt. Es läuft immer nur
eines der beiden Skripte (Sperre `/run/adk-gitea-admin.lock`, ein zweiter Lauf wartet); jeder
Lauf hat einen eigenen Token-Namen, löscht am Anfang übrig gebliebene `adk-init-*`-Tokens
abgebrochener Läufe und am Ende sein eigenes.

### Erste Anmeldung des Mitarbeiters

1. Einrichter liest das Startpasswort aus (`ssh adk-admin@<IP> sudo cat /root/adk-gitea-initial-password`)
   und gibt es persönlich weiter, dann `sudo rm /root/adk-gitea-initial-password`.
2. Mitarbeiter öffnet `https://GITEA_DOMAIN/`, meldet sich an und muss sofort ein eigenes
   Passwort setzen; danach 2FA einrichten (Einstellungen → Sicherheit).
3. Mitarbeiter legt das erste Repo in der Organisation an; danach
   `sudo /opt/adk/agent/protect-repo.sh <CUSTOMER_NAME>/<repo>` (siehe oben) – erst dann hat
   der Agent Zugriff darauf.

### CI-Runner

Jobs laufen in Containern des rootless Dockers von `ci` (Label `ubuntu-latest`, Image mit
Digest festgelegt). Der Runner reicht diesen Socket in die Jobs durch (`docker_host: ""`),
damit Jobs `docker build` und `docker push` in die Gitea-Registry ausführen können. Mit dem
Socket kann ein Job alles, was `ci` kann: andere Container starten, Pfade einbinden, auf die
`ci` Zugriff hat (`valid_volumes: []` gilt nur für `volumes:` im Workflow, nicht für
`docker run -v` über den Socket), Images ersetzen, User-Units anlegen. Deshalb gilt:

**Jeder Job läuft in einer frisch angelegten Umgebung und hinterlässt nichts.**

- `adk-act-runner.service` startet `gitea-runner daemon --once` mit einer **ephemeren
  Registrierung** (Kapazität 1): genau ein Job pro Runner-Prozess; Gitea löscht die
  Registrierung nach dem Job.
- Nach jedem Job (`ExecStopPost`) und vor dem nächsten (`ExecStartPre`) läuft als **root**
  `agent/ci-reset.sh` – ein Schritt der System-Unit, nichts, was `ci` beeinflussen kann:
  1. Konto von `ci` abgelaufen setzen (`usermod -L -e 1`) und Linger aus: Cron, `at` und der
     User-Manager von systemd starten für `ci` nichts mehr. Einträge von `ci` in den Spools
     von Cron, `at` und Mail löscht root direkt (`find … -delete`, nur in Verzeichnissen, die
     kein normaler Benutzer ändern kann). `ci` steht außerdem seit dem Setup in
     `/etc/cron.deny` und `/etc/at.deny`.
  2. User-Manager stoppen, Sitzungen beenden, dann alle Prozesse beenden: `cgroup.kill` der
     `user-<uid>.slice` (rootless Docker, Container, User-Units – der Kernel erwischt auch
     gerade geforkte Prozesse), `kill -KILL -1` als `ci` (alle Prozesse mit dessen uid in einem
     Durchgang), Reste der Sub-UIDs per PID; danach wird geprüft, dass nichts übrig ist.
     SysV-IPC-Objekte (Shared Memory, Semaphoren, Message Queues) von `ci`/Sub-UIDs werden
     per ID entfernt.
  3. Dateien von `ci`/Sub-UIDs in `/tmp`, `/var/tmp`, `/dev/shm`, `/dev/mqueue`, `/run/lock`
     löscht **`ci` selbst** in einem eigenen User-Namespace (dort darf es auch Dateien seiner
     Sub-UIDs löschen), mit `find -delete`: root handelt nie auf Pfadnamen in Verzeichnissen,
     die `ci` oder `hermes` ändern können. Ein Verzeichnis, das währenddessen gegen einen
     Symlink getauscht wird, wird höchstens als Link entfernt – und auch dann nur mit den
     Rechten von `ci` (im Integrationstest mit einem Tausch-Angriff geprüft).
  4. Home von `ci` (Docker-Daten, Images, Build-Cache, `~/.config/systemd/user`, Caches) und
     `/var/lib/adk-runner` (mit der Registrierungsdatei) werden erst in ein root-eigenes
     Verzeichnis (0700) verschoben und dann gelöscht; beide leer neu anlegen. Übrige Dateien
     von `ci` irgendwo sonst meldet der Schritt als `WARNING` im Journal, ohne sie anzufassen.
- Vor dem nächsten Job: Konto wieder gültig und Linger an, rootless Docker für `ci` neu
  einrichten (Dateien im Home schreibt `ci` selbst), Job-Image per Digest ziehen, neu
  registrieren: Registrierungstoken frisch aus
  der Gitea-CLI (alte Tokens vorher ungültig), per Pipe in die Umgebung des
  `register`-Prozesses (nie argv, Datei oder Ausgabe), danach sofort wieder ungültig.
  Registrierung auf Organisationsebene (`CUSTOMER_NAME`), alte Einträge werden entfernt.

Ein Job kann damit keinen späteren beeinflussen: keine gemeinsamen Images oder Caches, keine
untergeschobenen Units, Cron-/`at`-Jobs, Prozesse oder IPC-Objekte, keine wiederverwendbare
Registrierung (die Datei ist während des Jobs lesbar, gilt aber nur für genau diesen Job).
Nicht gelöscht werden die Kernel-Keyrings von `ci` (`keyctl`); in Job-Containern verbietet
Dockers Standard-Seccomp-Profil `keyctl`/`add_key`, ein Job kommt also nur über einen
Umweg (User-Unit auf dem Host) daran, und Schlüssel dort laufen nach einigen Tagen ab.

**Laufzeitgrenze:** Ein Runner-Lauf endet spätestens nach `RuntimeMaxSec=190min` (Job-Timeout
3 h plus Reserve), auch wenn Job oder Runner hängen; der Wipe läuft dann trotzdem
(`ExecStopPost`). Die Zeit zählt ab der Registrierung, also inklusive Warten auf einen Job: Ein
untätiger Runner wird etwa alle 3 Stunden neu aufgesetzt. Ein Job, der kurz vor diesem
Zeitpunkt startet, kann abgebrochen werden (dann neu starten); Jobs, die Stunden dauern, sind
nicht vorgesehen. **Preis:** Basis-Images und das
Job-Image werden für jeden Job neu geladen; Builds dauern entsprechend länger, der erste
Schritt eines Jobs wartet bis zu einigen Minuten. Zwischen zwei Jobs vergehen etwa 30–90 s
(abhängig vom Download des Job-Images).

Weiterhin gilt für jeden Job:

- Rechte höchstens des Users `ci`: kein root, kein Zugriff auf den root-Docker-Socket
  (getestet: verbunden wird nicht), keine fremden Homes. Den Metadaten-Dienst und die
  root-Docker-Netze sperrt nftables (uid/Sub-UIDs und `user.slice`, siehe oben); aus einem
  Job-Container läuft eine Anfrage dorthin in einen Timeout, der Regelzähler steigt.
- `privileged: false`, eigenes Netz pro Job (`network: ""`), der eingebaute Cache-Server ist
  aus (er hätte keinen Zugriffsschutz).
- **Was ein Job über Gitea kann, bleibt:** Jeder Workflow – auch einer, den `agent-bot` auf
  einem Feature-Branch pusht – bekommt ein Job-Token (`GITEA_TOKEN`) mit Schreibrechten auf
  sein Repo und **liest alle Actions-Secrets des Repos** (Gitea hält Secrets nur vor
  Fork-PRs zurück, es gibt keine Forks hier). Die Container-Registry lehnt das Job-Token ab
  (Gitea 28.3, getestet); wer aus einem Job Images pushen will, braucht ein Token mit
  `write:package` als Actions-Secret – und das kann dann jeder Branch-Workflow lesen und
  benutzen. Daher: **keine langlebigen Secrets in Actions-Secrets der Repos** (kein
  PROD-Zugang, keine Cloud-Tokens), und PROD vertraut keinen Registry-Tags (siehe Plan, PR 4).
  Tags pushen kann ein Job nicht (geschützte Tags, `protect-repo.sh`).
- `uses:`-Actions kommen von GitHub (`DEFAULT_ACTIONS_URL`) per Tag, also veränderlich; in
  der Projekt-Vorlage (PR 4) per Commit-SHA festlegen oder spiegeln.

Der Runner erreicht Gitea über `https://GITEA_DOMAIN`, also über die öffentliche IP des
Servers. Das funktioniert auf demselben Server ohne Umweg über die Hetzner-Firewall
(Verbindungen an die eigene IP bleiben lokal, Docker leitet Port 443 an Caddy weiter).

### Wo liegen Secrets

| Datei | Inhalt |
|---|---|
| `/opt/adk/secrets/gitea-*` (root, 0600, Verzeichnis 0700) | Gitea `SECRET_KEY`, `INTERNAL_TOKEN`, JWT-Secrets – einmal erzeugt, nie ausgegeben; per `__FILE` in den Container gereicht. Gitea schreibt sie beim Start in `/var/lib/adk/gitea/gitea/conf/app.ini` (Daten von `adk-gitea`, root 0700 darüber) – sie stehen also auch dort und im `gitea dump` |
| `/opt/adk/secrets/dns-api-token`, `caddy.env` | DNS-API-Token für Caddy (nur `dns01`; bei Hetzner siehe oben) |
| `/root/adk-gitea-initial-password` | Startpasswort des Mitarbeiters, nach Übergabe löschen |
| `~hermes/.config/gitea/token` | Token von `agent-bot` |
| `/var/lib/adk-runner/.runner` | Ephemere Registrierung des Runners (User `ci`), gilt für genau einen Job, wird danach gelöscht |
| `/root/.ssh/adk-backup-sign` | Schlüssel, mit dem jedes Backup-`MANIFEST` signiert wird (öffentlicher Teil: `/etc/adk/backup-allowed-signers`) |
| `/root/.ssh/adk-backup`, `adk-backup.known_hosts` | SSH-Key und festgelegter Host-Key des Off-Site-Ziels (nur mit `BACKUP_TARGET`) |

Alle Backups (`/var/backups/adk`, Off-Site) enthalten `kit.env`, die Gitea-Secrets, das
DNS-Token, das Token von `agent-bot`, den LLM-Key in `~hermes/.hermes` und allen Code. Lokal
liegen sie unverschlüsselt (root 0700), off-site nur mit `age` verschlüsselt.

### Backup und Restore

Täglich um 03:30 schreibt `agent/backup.sh` nach `/var/backups/adk/<UTC-Zeit>/` (root 0700):

- `gitea-dump.tar.gz`: `gitea dump` eines **gestoppten** Gitea. Gitea wird kurz angehalten,
  ein Einmal-Container desselben Images erzeugt den Dump als Container-User (höchstens 2 h,
  dann wird er beendet und der Teil gilt als fehlgeschlagen), danach startet Gitea wieder –
  auch bei Fehlern, wenn das Skript abgebrochen wird oder der Server währenddessen
  herunterfährt (`ExecStopPost=backup.sh --ensure-gitea` startet Gitea, wenn eine
  Markierungsdatei zeigt, dass das Backup es gestoppt hat; nach Absturz oder Stromausfall
  macht das `adk-backup-recover.service` beim nächsten Start). So schreibt während des Dumps
  niemand (keine Pushes des Agenten, keine Jobs); Gitea ist dafür einige Sekunden bis Minuten
  nicht erreichbar, ein um 03:30 laufender Job kann daran scheitern.
- `adk-secrets.tar`: `/opt/adk/secrets` + `kit.env`.
- `hermes-home.tar.gz`: Home von `hermes`, als `hermes` gepackt und komprimiert, Symlinks
  werden nicht verfolgt; ohne Caches, `node_modules`, rootless-Docker-Daten und die von
  `setup.sh` neu installierbare Hermes-Software.
- `MANIFEST`: erste Zeile `backup <UTC-Zeit> adk-<CUSTOMER_NAME>-agent` (Zeitpunkt und
  Server), dann sha256 je Datei – mit `BACKUP_TARGET` auch der `age`-verschlüsselten Kopien –,
  fehlgeschlagene Teile als `FAILED <teil>`; `MANIFEST.sig`: Signatur mit `ssh-keygen -Y sign`
  (Schlüssel `/root/.ssh/adk-backup-sign`, Namespace `adk-backup`). Der öffentliche Teil
  (`.pub`, `/etc/adk/backup-allowed-signers`) wird bei jedem `setup.sh`-Lauf aus dem privaten
  Schlüssel neu abgeleitet.

Vor dem Start prüft das Skript den freien Platz (Gitea-Daten + Secrets + gesichertes Home,
unkomprimiert, plus 10 % und 512 MB); reicht er nicht, endet es ohne Backup mit Fehler.
Aufbewahrt werden 7 Tage nach Verzeichnisname (UTC-Zeitstempel, also lexikalisch = zeitlich);
das neueste vollständige Backup wird nie gelöscht. Schlägt ein Teil fehl, laufen die anderen
trotzdem, das Verzeichnis bekommt eine Datei `FAILED` und der Dienst endet mit Fehler
(`systemctl status adk-backup.service`, `journalctl -u adk-backup`). Auch ein gescheiterter
Off-Site-Transfer markiert das ganze Backup als `FAILED` (die lokalen Teile bleiben nutzbar,
`restore.sh` verweigert nur Teile, die selbst fehlgeschlagen sind); es zählt dann nicht als
„neuestes vollständiges“ Backup.

```bash
sudo systemctl start adk-backup.service          # Backup sofort
systemctl list-timers adk-backup.timer           # nächster Lauf
sudo ls /var/backups/adk/
# Gitea zurückspielen (stoppt Gitea, alte Daten bleiben als /var/lib/adk/gitea.before-restore-<Zeit>)
sudo /opt/adk/agent/restore.sh --yes /var/backups/adk/<Zeit>
# zusätzlich: --secrets (neuer Server) und/oder --hermes-home (als hermes entpackt)
sudo /opt/adk/agent/restore.sh --gitea --hermes-home --yes /var/backups/adk/<Zeit>
```

`restore.sh` kopiert ein Backup-Verzeichnis, das ein normaler Benutzer ändern könnte
(Eigentümer, Schreibrechte des Verzeichnisses, seiner Dateien oder eines übergeordneten
Verzeichnisses), zuerst in ein root-eigenes temporäres Verzeichnis und prüft und benutzt nur
die Kopie. Es prüft vor jeder Änderung: Signatur von `MANIFEST` (Standard-Schlüssel
`/etc/adk/backup-allowed-signers`, sonst `--signer <öffentlicher Schlüssel>`); die signierte
Kopfzeile passt zum Verzeichnisnamen (ein älteres Backup unter dem Namen eines neueren wird
abgelehnt) und zu diesem Server (`CUSTOMER_NAME` aus `kit.env`), das Alter des Backups wird
angezeigt; sha256 jeder gewählten Datei, bei `*.age` zuerst die des Chiffrats (vor dem
Entschlüsseln); keine als fehlgeschlagen markierten Teile, und dass `gitea-dump.tar.gz` und
`adk-secrets.tar` nur normale Dateien und Verzeichnisse an erwarteten Pfaden enthalten (keine
Symlinks, Hardlinks, Geräte, `..`, absolute Pfade) – ein manipulierter Dump kann root so
nicht an andere Stellen schreiben lassen. Ohne `--yes` prüft es nur. Nach dem Gitea-Restore
läuft Gitea wieder und `/api/healthz` antwortet; danach
`/var/lib/adk/gitea.before-restore-<Zeit>` löschen.

Neuer Server nach Totalausfall: `provision.sh` + `bootstrap.sh` mit derselben `kit.env`,
Backup-Verzeichnis nach `/var/backups/adk/` kopieren, dann
`restore.sh --signer <alter Signatur-Public-Key> [--age-identity <age-Schlüssel>] --secrets --gitea --hermes-home --yes <dir>`
und `setup.sh` erneut (die Runner-Registrierung legt der Runner vor jedem Job ohnehin neu an).

**Off-Site:** Mit `BACKUP_TARGET=sftp://user@host[:port]/pfad` (z. B. Hetzner Storage Box,
Port 23) ist `BACKUP_AGE_RECIPIENT` Pflicht: der öffentliche `age`-Schlüssel des Kunden
(`age-keygen -o kunde-backup.key` auf einem Rechner des Kunden; nur die Zeile `age1…` kommt
in `kit.env`, der private Schlüssel bleibt offline beim Kunden, nie auf dem Server).

1. `setup.sh` erzeugt einmal `/root/.ssh/adk-backup` und zeigt nur den öffentlichen Teil – der
   kommt in die `authorized_keys` des Ziels. Bei der Storage Box einen **Unter-Account nur für
   dieses Verzeichnis** anlegen (ohne Samba/WebDAV/externe Erreichbarkeit, wo möglich nur SFTP).
2. Host-Key festlegen (kein Vertrauen beim ersten Kontakt): `setup.sh` zeigt die gefundenen
   Fingerprints; mit dem vom Anbieter veröffentlichten Wert vergleichen, dann
   `ssh adk-admin@<IP> sudo /opt/adk/agent/setup.sh --accept-backup-hostkey SHA256:<…>`.
   Ohne festgelegten Host-Key schlägt jede Off-Site-Kopie laut fehl.
3. Den Signatur-Public-Key (`/root/.ssh/adk-backup-sign.pub`, zeigt `setup.sh` beim Anlegen)
   zusammen mit dem `age`-Schlüssel offline aufbewahren.

`backup.sh` verschlüsselt danach jede Datei mit `age` an `BACKUP_AGE_RECIPIENT` (vor dem
Signieren, damit das `MANIFEST` auch die Prüfsummen der `*.age`-Dateien enthält) und kopiert
`*.age`, `MANIFEST` und `MANIFEST.sig` per `rsync` über SSH nach `<pfad>/<Zeit>/`; unverschlüsselt
verlässt nichts den Server. Wer das Ziel kontrolliert, kann ein Backup löschen oder ein älteres
liefern, aber nicht unbemerkt umbenennen oder verändern. Restore aus der Off-Site-Kopie: Verzeichnis zurückkopieren und
`restore.sh --age-identity <age-Schlüssel> --signer <Signatur-Public-Key> …` (entschlüsselt in
ein root-eigenes temporäres Verzeichnis) – oder auf dem eigenen Rechner mit
`age -d -i kunde-backup.key` entschlüsseln und das Verzeichnis hochladen. Die Aufbewahrung am
Ziel regelt der Kunde (z. B. Snapshots der Storage Box). Ein Backup auf demselben Server
ersetzt kein Off-Site-Backup; die Hetzner-Backups des Servers sind zusätzlich an.

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
- `make check`, Review-Runde 2: Wipe löscht in `/tmp` & Co. nur als `ci` (`find -delete`), ein
  zwischen Aufzählen und Löschen gegen einen Symlink getauschtes Verzeichnis führt nie nach
  außen (deterministischer Test und Dauer-Tausch-Test), Spool-Verzeichnisse nur, wenn kein
  normaler Benutzer sie ändern kann, Konto gesperrt/abgelaufen + Linger aus, `cgroup.kill`
  (ohne `user-runtime-dir@`), SysV-IPC per ID, Runner-Unit (Egress-Bindung,
  `RuntimeMaxSec`), nftables-Drop-in, `cron.deny`/`at.deny`; Teams ohne „alle Repos“, Zugriff
  erst nach dem Schutz, Sperre und eigener Token-Name; Backup-Kopfzeile, `*.age`-Prüfsummen,
  Dump-Timeout, Gitea-Neustart bei Abbruch/Signal/Boot; Restore: umbenanntes Backup, fremder
  Server, Chiffrat vor dem Entschlüsseln, Kopie unsicherer Verzeichnisse; `.pub` aus dem
  privaten Schlüssel.
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
  Header gesetzt; von außen offen nur 22 und 443 (LLMNR 5355 abgeschaltet), Gitea auf keinem
  Host-Port, `:2019` zu; Mitarbeiter-Login führt zur Passwortänderung (Kennzeichen bleibt
  nach jedem `setup.sh`-Lauf gesetzt); `agent-bot` (Token aus der Datei von `hermes`, als
  `hermes`, Scopes ohne `write:package`) klont und pusht Feature-Branches; abgelehnt: Push auf
  `main`, Tag-Push und Tag-Löschen, Release anlegen, Repo anlegen (Organisation und eigener
  Namensraum), Merge des eigenen PR – auch nach Freigabe durch den Mitarbeiter (nur der
  Mitarbeiter merged), Branch-/Tag-Schutz, Repo-/Org-Einstellungen, Owner-Beitritt,
  Actions-Secrets lesen, `docker push` in die Registry; `protect-repo.sh` zweimal (zweiter Lauf
  ohne Änderungen), `gitea-init.sh` warnt vorher vor dem ungeschützten Repo, danach nicht;
  CI: Job im rootless Docker von `ci` (root-Socket nicht nutzbar, Metadaten gesperrt, Job-Token
  von der Registry abgelehnt, `docker build` + Push mit Publisher-Token aus einem
  Actions-Secret grün); **zwei Jobs nacheinander**: Job 1 legt ein Image-Tag, einen
  Container mit `--restart always`, eine User-Unit in `~ci/.config/systemd/user` und eine Datei
  in `/tmp` an und liest das Runner-Verzeichnis (Registrierungsdatei ist während des Jobs
  schon verbraucht/entfernt), Job 2 findet nichts davon; jede Registrierung ist ephemer und
  nach ihrem Job gelöscht; Egress: `unshare --user --map-auto --map-root-user` + `setpriv
  --reuid=1` als `hermes` erreichte mit den alten Regeln Gitea direkt, mit den neuen weder
  Gitea:3000 noch den Metadaten-Dienst (sofort abgewiesen, Zähler steigt), root in einer
  Admin-Sitzung ebenso (cgroup-Schicht); DNS-Token-Rotation per `set-secret.sh` + `setup.sh`
  erzeugt Caddy neu (Token in der Umgebung = Datei, nur Hashes verglichen); Backup per
  systemd mit signiertem `MANIFEST` und `age`-verschlüsselter Off-Site-Kopie per SFTP auf
  einen lokalen zweiten sshd (ohne festgelegten Host-Key und mit falschem Fingerprint
  abgelehnt; am Ziel nur `*.age`, `MANIFEST`, `MANIFEST.sig`); Repo löschen → `restore.sh`
  aus der verschlüsselten Kopie (ohne `--age-identity` und mit verändertem `MANIFEST`
  abgelehnt) → Repo, Commits und Registry-Paket wieder da, Home als `hermes` entpackt,
  keine Reste des Entschlüsselungsverzeichnisses; Timer gelistet.
- Integrationstest nach Review-Runde 2 (frische VM, gleiche Parameter): `bootstrap.sh` bis 0
  Änderungen, HTTPS/Header, offen nur 22 und 443; ein neues Repo ist für `agent-bot` unsichtbar
  (404, Clone scheitert), `gitea-init.sh` warnt, erst nach `protect-repo.sh` hat er Zugriff
  (zweiter Lauf ohne Änderungen); `agent-bot`-Grenzen wie oben. **Tausch-Angriff:** `hermes`
  legt `/tmp/H/J` (0777) an, ein Job legt dort Dateien von `ci` und einer Sub-UID an, während
  des Wipes tauscht `hermes` `J` rund 30 000-mal gegen einen Symlink auf ein root-eigenes
  Verzeichnis – dessen Dateien bleiben, die Job-Dateien sind weg. Cron/`at`: `crontab`/`at` als
  `ci` abgelehnt; trotzdem untergeschobene Einträge (Deny-Listen kurz entfernt) sind nach dem
  Wipe aus den Spools gelöscht und laufen nicht mehr (Journal). Ein Container mit
  `--restart always`, der ständig Prozesse erzeugt, und eine Endlosschleife als User-Unit von
  `ci` (300+ Prozesse): danach 0 Prozesse von `ci`/Sub-UIDs. Eine Datei in `/run/user/<ci>`
  ist im nächsten Job weg (der Test fand hier einen Fehler der ersten Fassung: `cgroup.kill`
  traf den Stop von `user-runtime-dir@`, behoben). Der Folgejob sieht keine Images, Container,
  Units oder Dateien des vorigen. `systemctl restart`/`reload nftables`: Tabelle bleibt
  geladen; ohne Tabelle startet der Runner nicht, mit ihr wieder. Ein hängender Job wird
  durch `RuntimeMaxSec` (im Test per Drop-in verkürzt) beendet, der Wipe läuft. Backup: Kopfzeile
  und `*.age`-Prüfsummen signiert; Restore aus der Off-Site-Kopie (Verzeichnis gehört dem
  SFTP-Benutzer → root-eigene Kopie) stellt das gelöschte Repo wieder her; abgelehnt: älteres
  Backup unter dem Namen des neueren, Chiffrat eines anderen Backups. Gitea läuft wieder nach
  `kill -9` des Backups während des Dumps, nach `systemctl stop` und nach einem Neustart des
  Servers mit zurückgebliebener Markierung (`adk-backup-recover.service`).
- Noch nicht geprüft (PR 6, E2E): echter Hetzner-API-Lauf, ACME mit echtem DNS-Anbieter,
  Off-Site-Backup auf eine Storage Box (Host-Key-Fingerprint von Hetzner), Port-Scan von außen
  durch die Hetzner-Firewall.
