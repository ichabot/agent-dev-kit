# TEST-VM

Ein Hetzner-Cloud-Server (Debian 13) pro Kunde, auf dem die Projekte des Kunden mit
**Testdaten** laufen. Nach jedem Merge auf `main` deployt die CI auf dem Agent-VPS den
gemergten Commit dorthin; der Mitarbeiter prüft das Ergebnis unter
`https://<projekt>.TEST_DOMAIN/`. Echte Daten gibt es nur auf PROD.

Der Agent (`hermes`) hat **keine Shell** auf TEST. Er kann dort nur über die CI etwas
auslösen, und die CI kann nur `deploy <projekt> <ref>` sagen.

## Was läuft wo

| Wo | Was |
|---|---|
| Rechner des Einrichters | `test/provision.sh` (Hetzner API), `agent/bootstrap.sh --role test` (SSH) |
| Hetzner Cloud | Firewall `adk-<kunde>-test`, Server `adk-<kunde>-test`; die Agent-Firewall bekommt eine Regel für TEST |
| TEST, als root | `/opt/adk` (Kit, root-eigen, `kit.env` 0600), Docker CE (root), Caddy (`/opt/adk/test-services`), `test/deploy.sh` |
| TEST, User `adk-admin` | Admin mit sudo, Login nur per Key |
| TEST, User `deploy` | nur SSH-Login mit dem CI-Deploy-Key, Zwangsbefehl `test/deploy-gate.sh`; kein sudo außer genau einer Regel, nicht in `docker` |
| TEST, Systemuser `adk-app` | führt `deploy/update.sh` der Projekte aus; Mitglied der Gruppe `docker` (siehe [Grenzen](#grenzen-bewusst-akzeptiert)) |
| TEST, `/srv/test/<projekt>/` | `deploy/` (Dateien des deployten Stands), `.env`, `state/`, `VERSION`, `http_port` |
| Agent-VPS | Deploy-Key-Paar (`/opt/adk/secrets/test-deploy-key`), Gitea-Bot `test-pull`, Org-Secret/-Variablen für die CI |

## Firewall (Hetzner Cloud, nur eingehend)

| Server | Port | Quelle |
|---|---|---|
| TEST | tcp 443, ICMP | `CUSTOMER_IPS` |
| TEST | tcp 22 | `CUSTOMER_IPS`, Agent-VPS (IPv4 + IPv6-Netz, per API nachgeschlagen), `--admin-source` |
| TEST | tcp 80 | weltweit, nur bei `ACME_MODE=http01` |
| Agent-VPS | tcp 443 | zusätzlich vom TEST-Server (IPv4 + IPv6-Netz): Deploy-Dateien und Images aus Gitea |

Alle Quellen laufen durch dieselbe Prüfung wie `CUSTOMER_IPS` (öffentlich, Mindest-Präfix).
Vorschau: `agent/firewall-rules.sh --role test` bzw.
`agent/firewall-rules.sh --extra-https-source <TEST-IPv4> --extra-https-source <TEST-IPv6-Netz>`.

`test/provision.sh` (= `agent/provision.sh --role test`) legt Firewall und Server an und
wendet danach die Firewall des Agent-VPS neu an (`agent/provision.sh --role agent`, gleiche
`--admin-source`). Umgekehrt nimmt jeder Lauf von `agent/provision.sh` die TEST-IPs mit, solange
der TEST-Server existiert – die Regel geht also bei der Übergabe (Lauf ohne `--admin-source`)
nicht verloren. Ein Server mit dem Namen `adk-<kunde>-test` ohne die Labels des Kits wird
abgelehnt. TEST hat keine Hetzner-Backups (Testdaten, jederzeit neu aufsetzbar).

## Ablauf

Voraussetzung: Agent-VPS läuft (`docs/agent-vps.md`), DNS `*.TEST_DOMAIN` (oder je Projekt
`<projekt>.TEST_DOMAIN`) zeigt auf die TEST-IP.

```bash
# 1. Plan ansehen, dann anlegen (idempotent)
test/provision.sh --pubkey ~/.ssh/id_ed25519.pub --admin-source <eigene-IP> --dry-run
test/provision.sh --pubkey ~/.ssh/id_ed25519.pub --admin-source <eigene-IP>
# 2. Kit kopieren und test/setup.sh ausführen
agent/bootstrap.sh --role test --identity ~/.ssh/id_ed25519 <TEST-IPv4>
# 3. CI-Deploy-Key: Host-Key von TEST festnageln, Schlüssel auf dem Agent-VPS erzeugen,
#    öffentlichen Teil als Zwangsbefehl-Key bei deploy eintragen
ssh adk-admin@<TEST> cat /etc/ssh/ssh_host_ed25519_key.pub \
  | ssh adk-admin@<AGENT> sudo /opt/adk/agent/test-deploy-key.sh --host <TEST-Adresse> \
  | ssh adk-admin@<TEST> sudo /opt/adk/agent/add-key.sh --forced-command deploy
# 4. Lese-Token des Gitea-Bots test-pull nach TEST (nur über die Pipe, nie auf dem Bildschirm)
ssh adk-admin@<AGENT> sudo /opt/adk/agent/test-pull-token.sh \
  | ssh adk-admin@<TEST> sudo /opt/adk/agent/set-secret.sh gitea-pull-token
```

- Bei `ACME_MODE=dns01` bricht der erste `setup.sh`-Lauf ab und verlangt das DNS-Token
  (`set-secret.sh dns-api-token`), wie auf dem Agent-VPS. **Achtung:** Auf TEST kann
  deployter Projektcode (siehe Grenzen) das Token lesen. Für TEST nur ein Token verwenden, das
  ausschließlich die TEST-Zone (bzw. eine per CNAME delegierte `_acme-challenge`-Zone)
  ändern kann – nie ein Token, mit dem sich Server oder Firewalls ändern lassen.
- Der Host-Key in Schritt 3 kommt über die SSH-Verbindung des Einrichters, deren Host-Key
  `bootstrap.sh` beim ersten Kontakt übernommen hat; wer ganz sicher gehen will, vergleicht den
  Fingerprint mit der Ausgabe von `setup.sh` in der Hetzner-Konsole.
- Schritt 3 und 4 sind wiederholbar: Schritt 3 erzeugt den Schlüssel nur einmal und ändert
  danach nur geänderte Variablen; Schritt 4 erzeugt jedes Mal ein neues Token und widerruft die
  alten (Rotation).

## Deploy-Weg

```
CI-Job (Agent-VPS, rootless Docker von ci)
  ssh -i <TEST_DEPLOY_KEY> deploy@TEST  deploy <projekt> <commit-sha>
    sshd: Key-Option restrict,command="/opt/adk/test/deploy-gate.sh" + Match User deploy:
          ForceCommand, kein PTY, kein Forwarding jeder Art, keine ~/.ssh/rc
    test/deploy-gate.sh (als deploy): prüft NUR $SSH_ORIGINAL_COMMAND gegen
          ^deploy <projekt> <ref>$, protokolliert (syslog, Tag adk-deploy-gate)
    sudo -n /opt/adk/test/deploy.sh <projekt> <ref>     (die einzige sudo-Regel von deploy)
      test/deploy.sh (root): prüft beide Argumente erneut, holt deploy/ aus Gitea, ...
```

**Grammatik:** `projekt` = `^[a-z][a-z0-9-]{1,38}$` (= Repo-Name in der Organisation
`CUSTOMER_NAME`), `ref` = 40-stelliger Commit-SHA (Kleinbuchstaben) oder Tag
`v<major>.<minor>.<patch>[-<prerelease>]`. Alles andere (Shell, `scp`, `sftp`, `rsync`,
interaktives Login, weitere Wörter, `;`, `$(...)`, Zeilenumbruch, Tabulator, `..`) wird
abgewiesen, ohne dass `sudo` aufgerufen wird. Die sudoers-Regel
(`/etc/sudoers.d/adk-deploy`) erlaubt nur `/opt/adk/test/deploy.sh` mit Argumenten, die auf
denselben regulären Ausdruck passen (sudo ≥ 1.9.10); `deploy.sh` prüft als root noch einmal
(sudo verbindet die Argumente mit Leerzeichen – ein einzelnes Argument `"shop v1.0.0"` passt
auf die Regel, wird aber von `deploy.sh` abgelehnt).

**`test/deploy.sh`** (root, immer nur eine Ausführung gleichzeitig, Sperre
`/run/adk/test-deploy.lock`):

1. Archiv des Repos `CUSTOMER_NAME/<projekt>` beim Stand `<ref>` von
   `https://GITEA_DOMAIN/api/v1/repos/.../archive/<ref>.tar.gz` mit dem Token von `test-pull`
   (`/opt/adk/secrets/gitea-pull-token`, an `curl` über stdin). `test-pull` liest nur Repos, die
   `protect-repo.sh` freigegeben hat.
2. Nur das Verzeichnis `deploy/` wird ausgepackt (`test/lib/deploy.py`): nur normale Dateien
   und Verzeichnisse – Symlinks, Hardlinks, Geräte, absolute Pfade, `..`, Steuerzeichen, mehr
   als 2000 Einträge oder 50 MB werden abgelehnt; Pflicht: `deploy/update.sh` und
   `deploy/adk.json`.
3. `deploy/adk.json` muss genau `{"http_port": <1024–65535>}` sein; der Port darf von keinem
   anderen Projekt belegt sein.
4. `/srv/test/<projekt>/deploy` wird ersetzt (root-eigen, für die App nur lesbar; der vorige
   Stand bleibt als `deploy.prev`). `.env` wird beim ersten Deploy aus `deploy/.env.example`
   angelegt und danach nie wieder angefasst.
5. `deploy/update.sh --non-interactive --additive-only --version <ref>` läuft in
   `/srv/test/<projekt>` als `adk-app` (nie als root), höchstens 30 Minuten, mit
   `COMPOSE_PROJECT_NAME=app-<projekt>`, `ADK_STATE_DIR=/srv/test/<projekt>/state` und einer
   temporären `DOCKER_CONFIG` mit den Registry-Zugangsdaten von `test-pull`. Scheitert es, wird
   der vorige `deploy/`-Stand zurückgelegt; Caddy bleibt unverändert.
6. Warten auf `http://127.0.0.1:<http_port>/healthz` (60 s).
7. Caddy-Site `<projekt>.TEST_DOMAIN` → `127.0.0.1:<http_port>` schreiben, mit
   `caddy validate` prüfen, dann `caddy reload` über den Admin-Socket im Container. Lehnt Caddy
   ab oder scheitert der Reload, wird die alte Site-Datei wiederhergestellt (und neu geladen).

## Deployment-Vertrag für TEST (Ergänzung zu PR 4)

Jedes Projekt, das auf TEST laufen soll, hat im Repo:

| Datei | Inhalt |
|---|---|
| `deploy/adk.json` | `{"http_port": 8080}` – Port, auf dem die App auf `127.0.0.1` lauscht (Compose: `"127.0.0.1:8080:<container-port>"`) |
| `deploy/update.sh` | ausführbar; versteht `--non-interactive --additive-only --version <ref>` (PR 4: Plan, Backup, nur additive Migrationen, ändernde → Abbruch mit Hinweis, Health, Rollback). Arbeitsverzeichnis `/srv/test/<projekt>` mit `deploy/`, `.env`, `state/` (beschreibbar) |
| `deploy/compose.yaml` | die Dienste; nur benannte Volumes für Daten |
| `deploy/.env.example` | Startwerte für `.env` auf TEST (Testdaten-Konfiguration, keine echten Secrets) |
| `/healthz` | antwortet mit 2xx, sobald die App bereit ist |

Testprojekt mit Stub-`update.sh` (startet nur `docker compose up`):
`tests/fixtures/test-project/`.

## CI: Deploy-Job im Projekt

Vorlage: `test/deploy-test.workflow.yaml` → `.gitea/workflows/ci.yaml` des Projekts. Der
Job `deploy-test` läuft nach `test` nur bei einem Push auf `main` (also nach dem Merge durch
den Mitarbeiter) und führt aus:

```bash
ssh -i <TEST_DEPLOY_KEY> -o StrictHostKeyChecking=yes -o UserKnownHostsFile=<TEST_DEPLOY_KNOWN_HOSTS> \
  deploy@<TEST_DEPLOY_HOST> deploy <repo-name> <commit-sha>
```

`agent/test-deploy-key.sh` legt dafür in der Organisation an (einmal, gilt für alle Repos):

| Name | Art | Inhalt |
|---|---|---|
| `TEST_DEPLOY_KEY` | Actions-Secret | privater Schlüssel (auf dem Agent-VPS als root erzeugt, über stdin an die API, nie ausgegeben) |
| `TEST_DEPLOY_HOST` | Actions-Variable | Adresse von TEST |
| `TEST_DEPLOY_KNOWN_HOSTS` | Actions-Variable | festgelegte Host-Keys von TEST |

## Grenzen (bewusst akzeptiert)

- **Jeder Branch-Job kann deployen.** Actions-Secrets sind für jeden Workflow jedes Branches
  lesbar, auch für einen, den der Agent auf einem Feature-Branch pusht. Damit kann jeder Job
  **jeden Stand** (jeden Commit-SHA, jeden Tag) jedes freigegebenen Repos auf TEST deployen –
  also auch ungeprüften Code. Akzeptiert, weil TEST nur Testdaten hat, nur aus den
  Kundennetzen erreichbar ist und der Schlüssel nichts anderes kann als
  `deploy <projekt> <ref>` (keine Shell, kein `scp`, kein Forwarding).
- **Projekt-Compose läuft mit root-Docker.** `update.sh` läuft als `adk-app`, aber `adk-app`
  ist in der Gruppe `docker`; ein Compose-File kann Host-Pfade einbinden oder privilegierte
  Container starten. Deployter Projektcode ist damit **root auf TEST**. TEST ist der
  Explosionsradius: dort liegen nur Testdaten, das Lese-Token von `test-pull` (liest dieselben
  Repos, die `agent-bot` ohnehin lesen kann), bei `dns01` das DNS-Token (siehe oben) und
  die Zertifikate von TEST. Kein Weg führt von TEST zum Agent-VPS außer HTTPS zu Gitea mit
  dem Lese-Token; PROD ist nicht erreichbar.
- Der Deploy-Key liegt auf dem Agent-VPS in `/opt/adk/secrets` (root) und in Gitea; das
  Gitea-Backup enthält ihn.

## Übergabe

Zusätzlich zu `docs/agent-vps.md`: `test/provision.sh` ohne `--admin-source` erneut
ausführen (entfernt die Installer-Regel auf TEST und – über den Agent-Lauf – auch dort),
Installer-Key aus `/etc/ssh/authorized_keys/adk-admin` auf TEST entfernen
(`remove-key.sh`), `/root/.ssh/authorized_keys` leeren.

## Was geprüft ist

- `make check`: Firewall-Regeln `--role test` (443/22/ICMP nur `CUSTOMER_IPS`, SSH vom
  Agent-VPS als eigene Regel, 80 nur bei http01, kein VPN) und `--extra-https-source` am
  Agent; `provision.sh --role test` gegen die simulierte API (Agent muss existieren, fremde
  Labels abgelehnt, IPv4-only, private IPs abgelehnt, Agent-Firewall danach mit den TEST-IPs,
  Idempotenz, keine Backups); Cloud-Init mit dem TEST-sshd-Drop-in; `sshd -T` für `deploy`
  (ForceCommand, kein PTY, kein Forwarding) und gleiche globale Härtung wie der Agent;
  `add-key.sh --forced-command deploy`; Deploy-Gate (Grammatik, ~50 Angriffs-Strings, kein
  stdin an deploy.sh); `deploy.sh` (Token nur über stdin, Archiv-Prüfungen, `adk.json`,
  Port-Kollision, Rollback bei `update.sh`-Fehler, Health, Caddy validate/reload mit
  Wiederherstellung); sudoers-Regel (`visudo -c`, Regex); Caddyfile/Compose für TEST
  (Wildcard bei dns01, Admin nur Unix-Socket); `test-deploy-key.sh` und `test-pull-token.sh`
  gegen das simulierte Gitea (privater Schlüssel nie in argv/Ausgabe, Idempotenz, Rotation).
- Integrationstest im Labor (zwei VMs aus dem Debian-13-Cloud-Image mit genau diesem Cloud-Init,
  ohne Hetzner-Firewall, `ADK_TLS_INTERNAL=1`, DNS per `/etc/hosts`): Agent-VPS mit
  `bootstrap.sh` bis 0 Änderungen (Bot `test-pull` angelegt), TEST mit
  `bootstrap.sh --role test` (1. Lauf 22, 2. und 3. Lauf – auch nach Deploys – 0 Änderungen);
  Schlüssel und Token über die Pipes aus dem Ablauf (privater Schlüssel nie ausgegeben,
  zweiter Lauf von `test-deploy-key.sh` ändert nichts). Ablauf wie beim Kunden: Mitarbeiter
  legt das Repo an, `protect-repo.sh`, `agent-bot` (als `hermes`) pusht einen Feature-Branch
  und öffnet den PR (eigener Merge: 405), Mitarbeiter gibt frei und merged → CI-Job
  `deploy-test` deployt den Merge-Commit → `https://<projekt>.TEST_DOMAIN/` liefert die App
  (Zertifikat gültig, Header gesetzt, Port 80 leitet um, unbekannte Namen ohne Antwort).
  Zweiter PR: Image aus der Gitea-Registry (gezogen mit dem Token von `test-pull`, temporäre
  `DOCKER_CONFIG` danach weg), neuer Stand ausgeliefert. Tag `v1.0.0` (vom Mitarbeiter)
  deploybar. Deploy eines ungeschützten Repos scheitert (`test-pull` sieht es nicht).
  Abgewiesen mit dem echten Deploy-Key: interaktives Login, `id`, `/bin/sh -c id`,
  `deploy x; id`, `deploy shop <sha>; id`, `deploy ../x <sha>`, Zusatzwort, Zeilenumbruch,
  `$(id)`, Branch-Name statt SHA, PTY (`ssh -tt`), `SetEnv`, Login als `adk-admin`, `scp`
  (SFTP und `-O`, hoch und runter – keine Datei angelegt), `sftp`, `rsync`, `-W`, `-L`, `-R`,
  `-D` (Verbindungen scheitern). Als `deploy`: `sudo -n id`, `/bin/sh`, `deploy.sh` mit
  falschen/zusätzlichen Argumenten, `-E`, `-u adk-app` abgelehnt; ein Argument mit Leerzeichen
  passiert sudo, `deploy.sh` lehnt ab (Exit 2); kein Docker-Zugriff, kein eigenes `~/.ssh`.
  `hermes` kann den Deploy-Key auf dem Agent-VPS nicht lesen. Caddyfile der dns01-Variante
  (Wildcard + Handler) mit `caddy validate` gegen das gepinnte Caddy-Image geprüft.
