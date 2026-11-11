# agent-dev-kit – Plan

> **Für Hermes:** Ein PR pro Abschnitt. Nach jedem PR: Gate, Code-Review, Fixes, Merge – erst dann der nächste.
> Code-ändernde Subagenten sequenziell, jeweils mit genau einem PR-Abschnitt als Kontext.

**Ziel:** Ein wiederverwendbares Kit (Repo + Setup-Skill mit Platzhaltern), mit dem pro Kunde aufgebaut wird:
Hetzner-VPS mit Hermes + Gitea, Hetzner-TEST-VM mit Caddy/HTTPS, und ein Update-Weg für PROD im Kunden-LAN,
der vorhandene Daten nie ohne Freigabe ändert. Nach der Übergabe gehört alles dem Kunden, der Einrichter hat keinen Zugang mehr.

**Rahmen (geklärt):**
- Hetzner-Account des Kunden; Einrichter nur während des Setups Projektmitglied.
- LLM-Zugang regelt der Kunde (API-Key; Abo-Logins sind laut Anbieter-Terms nicht für Fremd-Agenten gedacht).
- Bedienung durch einen Mitarbeiter am Arbeitsplatz im Kunden-LAN (statische IP), Hermes-Desktop → VPS über VPN.
- VPN richtet der Einrichter separat ein. Domains/IPs folgen → Platzhalter.
- Mitarbeiter gibt Merges und Releases frei. Nur Testdaten auf TEST, echte Daten nur auf PROD.
- Stack der Kundenprojekte offen → stack-neutraler Deployment-Vertrag.

**Aufwand:** ca. 7 KI-Tage (Summe PR-Tabelle).

---

## 0. Regeln für alle PRs

- TDD wo Code entsteht (Shell: `bats`, Lint: `shellcheck`); ein Task = ein Commit.
- Jeder PR beginnt mit dem Security-Gate.
- Keine Secrets im Repo; Platzhalter nur in `kit.env.example`. Tokens beim Kunden unter `~/.config/*` bzw. `/etc/<dienst>/` mit 0600.
- Keine User-Passwörter erzeugen oder speichern: Gitea-Admin wird mit `--must-change-password` angelegt, Passwort setzt der Mitarbeiter.
- Doku für den Kunden: Deutsch, kurz, Befehle zum Kopieren. Code/Kommentare: Englisch.
- Issue pro PR, nach Merge mit Kommentar schließen.

## 1. Entscheidungen

| # | Frage | Empfehlung |
|---|---|---|
| 1 | Wo liegt das Kit? | Öffentliches Repo `agent-dev-kit` + Setup-Skill `agent-dev-kit-setup` beim Einrichter. Beim Kunden landen nur Kopien, keine Verbindung zum Einrichter. |
| 2 | Zertifikate, wenn alles nur für Kunden-IPs offen ist | DNS-01 über Caddy-DNS-Modul (Platzhalter `DNS_PROVIDER`). Fallback `ACME_MODE=http01`: Port 80 öffentlich, liefert nur Redirect + Challenge. |
| 3 | Migrationswerkzeug (Stack offen) | PostgreSQL als Standard-DB, reine SQL-Migrationen mit `dbmate` (eine Binary, auch MySQL/SQLite). Apps migrieren nie selbst beim Start. |
| 4 | Agent-Isolation auf dem VPS | Hermes als User `hermes` ohne root, ohne `docker`-Gruppe; eigene Tests über rootless Docker. Gitea + Runner laufen unter root-Docker getrennt. |
| 5 | End-to-End-Test des Kits | 3 temporäre Hetzner-Server (agent, test, prod-sim) in einem Test-Projekt des Einrichters, nach dem Test löschen (Kosten: wenige Euro). |

## 2. PR-Tabelle

| PR | Inhalt | KI-Tage |
|---|---|---|
| 1 | Kit-Gerüst, Platzhalter-Datei, Prüfskript, Spike Hermes-Desktop-Remote | 0,5 |
| 2a | Agent-VPS Basis: Hetzner-Firewall, Cloud-Init, Bootstrap, sshd-Härtung, rootless Docker, Hermes | 0,75 |
| 2b | Agent-VPS Dienste: Gitea, CI-Runner (rootless), Caddy/TLS, Backup + Restore | 1 |
| 3 | TEST-VM: Firewall, Cloud-Init, Docker, Caddy, Deploy-User mit Zwangsbefehl | 0,5 |
| 4 | Projekt-Vorlage: Deployment-Vertrag, `update.sh`, Migrations-Lint, CI mit Upgrade-Test | 2 |
| 5 | Kunden-Hermes: SOUL.md, Skills, Token-Tuning, Kunden-Doku, Übergabe-Checkliste | 1 |
| 6 | Setup-Skill `agent-dev-kit-setup` + E2E-Lauf auf temporären Servern | 1,5 |

---

## PR 1 – Kit-Gerüst und Platzhalter

**Security-Gate:** Keine Laufzeit-Komponente. Risiko: Secrets in Beispieldateien → `kit.env.example` enthält nur Namen, `.gitignore` sperrt `kit.env`.

**Dateien:** `README.md`, `kit.env.example`, `scripts/check-config.sh`, `tests/check-config.bats`, `AGENTS.md`.

**Platzhalter (`kit.env.example`):**
```
CUSTOMER_NAME=            # short id, e.g. acme
CUSTOMER_IPS=             # static IPv4/IPv6 CIDRs, comma separated
VPN_PORT= VPN_PROTO=udp   # VPN set up separately
GITEA_DOMAIN= TEST_DOMAIN=
ACME_EMAIL= ACME_MODE=dns01   # dns01 | http01
DNS_PROVIDER=             # caddy-dns module name, e.g. hetzner
HCLOUD_LOCATION=nbg1 AGENT_TYPE= TEST_TYPE=
BACKUP_TARGET=            # optional: Storage Box sftp://...
```

**Tasks:**
1. `check-config.sh` meldet fehlende/ungültige Werte (CIDR, Domain, Port) – Tests zuerst.
2. Spike (Wegwerf, ½ h): in Hermes-Doku (`llms.txt`) klären, wie die Desktop-App sich an einen entfernten Hermes anmeldet (Endpoint, Port, Auth). Ergebnis in `docs/hermes-remote.md`.
3. AGENTS.md mit Konventionen (shellcheck, bats, keine Secrets).

**Abnahme:** `make check` grün; Spike-Ergebnis dokumentiert.

## PR 2 – Agent-VPS (aufgeteilt in 2a Basis und 2b Dienste)

**Aufteilung:** 2a = Firewall, Server, Cloud-Init, Bootstrap, sshd, Users, rootless Docker, Hermes. 2b = Gitea, Runner, Caddy, Backup/Restore.

**Zusatz aus Review:** Der CI-Runner läuft mit rootless Docker eines eigenen Users `ci` – ein Runner am root-Docker-Socket würde Agent-Code über CI-Jobs root-Rechte geben. Während des Setups bekommt die Admin-IP des Einrichters eine eigene SSH-Regel (`--admin-source`), die bei der Übergabe entfernt wird.

**Security-Gate:** Exponiert SSH, Gitea (443), VPN – alles nur für `CUSTOMER_IPS` (Hetzner Cloud Firewall) und zusätzlich nur an den nötigen Interfaces gebunden. Ausgehend offen (LLM-API, Pakete, ACME). Blast-Radius Agent: User `hermes` ohne root/Docker-Gruppe; Gitea-Bot `agent-bot` ohne Admin, `main` geschützt (Merge nur nach Freigabe durch Mitarbeiter-Account).

**Dateien (2a):** `agent/provision.sh` (hcloud: Server, Firewall, Backups an), `agent/firewall-rules.sh`, `agent/cloud-init.yaml.tmpl` + `agent/render-cloud-init.sh`, `agent/sshd-adk.conf`, `agent/bootstrap.sh`, `agent/setup.sh` (inkl. Hermes-Installation), `agent/add-key.sh`, `agent/remove-key.sh`, `agent/lib/*`; Tests flach unter `tests/*.bats`.
**Dateien (2b):** `agent/render-services.sh` (erzeugt `/opt/adk/services/compose.yaml` mit Gitea + Caddy, `Caddyfile`, Caddy-Dockerfile für DNS-01 und `/etc/adk/runner.yaml`), `agent/lib/services.sh` (Setup-Schritte: Secrets, Compose, Runner als User `ci` mit systemd-Unit `adk-act-runner.service`, Backup-Timer), `agent/lib/versions.sh` (Versionen + Digests/sha256), `agent/gitea-init.sh`, `agent/set-secret.sh`, `agent/backup.sh`, `agent/restore.sh`, `agent/systemd/adk-backup.{service,timer}`; Tests `tests/{render-services,set-secret,gitea-init,backup,restore}.bats`. Der Runner läuft nicht in Compose, sondern als Systemdienst mit dem rootless Docker von `ci`.

**Hinweise für 2b (aus dem Review von 2a):**
- `PermitOpen 127.0.0.1:*` gibt `hermes` auch Loopback-Admin-Endpunkte frei, z. B. Caddys Admin-API auf `:2019`. In 2b abschalten (`admin off`) oder auf einen Unix-Socket legen; generell keine Admin-Endpunkte ohne Auth auf Loopback.
- Der CI-User `ci` kommt in die nftables-Egress-Regeln (`adk_egress_rules` in `agent/lib/host.sh`, zweite uid), damit auch CI-Jobs den Metadaten-Dienst nicht erreichen.
- Keine Secrets in user_data oder Metadaten (Metadaten-Sperre ist nur für die eingeschränkten uids).

**Ergebnisse aus 2b:**
- `agent-bot` darf keine Repos in der Organisation anlegen: Gitea macht den Ersteller eines Repos zu dessen Admin, damit könnte der Agent den Branch-Schutz abschalten. Repos legt der Mitarbeiter an (für PR 5: Skill „Projekt anlegen“ bittet den Mitarbeiter darum oder nutzt ein root-Hilfsskript).
- `agent-bot` und `prod-pull` sind Gitea-Bot-Konten (kein Passwort, keine Web-Anmeldung).
- Branch-Schutz pro Repo setzt der Mitarbeiter (Gitea kennt keinen Organisations-Standard); PR 4/5 liefern dafür eine Anleitung bzw. ein Skript.

**Regeln:**
- SSH nur Key, kein Passwort, kein root-Login nach Setup (eigener Admin-User mit sudo).
- `unattended-upgrades` für Sicherheitsupdates.
- Gitea: Registrierung aus, Packages (Container-Registry) an, Actions an.
- Accounts: `<mitarbeiter>` (Admin, Passwort selbst gesetzt), `agent-bot` (schreibt Branches, kein Merge auf `main`), `prod-pull` (nur Lesen: Repo + Packages).
- Backup nächtlich: `gitea dump` + `~hermes/.hermes` → lokal 7 Tage, optional `BACKUP_TARGET`; Hetzner-Backups zusätzlich an.

**Tasks:**
1. Firewall-Regeln aus `CUSTOMER_IPS` erzeugen (Test: Regel-JSON gegen Erwartung).
2. Cloud-Init: Basis-Härtung, Users, rootless Docker für `hermes`.
3. Compose: Gitea + Runner + Caddy (DNS-01/HTTP-01 je `ACME_MODE`).
4. Gitea-Init-Skript: Accounts, Tokens, Branch-Schutz, Template-Repo-Platz.
5. Hermes-Installation als `hermes` (vorher `libatomic1` installieren). Kein offener Hermes-Port: Desktop verbindet per SSH (siehe `docs/hermes-remote.md`); sshd mit Key-only und `AllowTcpForwarding local`.
6. Backup + Restore-Skript, Restore-Test.

**Abnahme:** Port-Scan von fremder IP: alles zu. Von Kunden-IP: 443/22/VPN offen. Gitea per HTTPS erreichbar, `agent-bot` kann nicht auf `main` pushen. Restore aus Backup funktioniert.

## PR 3 – TEST-VM

**Security-Gate:** 443 nur für `CUSTOMER_IPS`; 22 nur von Agent-VPS (Deploy) und Kunden-IPs. Deploy-Key in Gitea-Secrets, auf der VM per `command="/opt/deploy/deploy.sh"` eingeschränkt – kein Shell-Zugang für CI.

**Dateien:** `test/provision.sh`, `test/cloud-init.yaml`, `test/Caddyfile.tmpl`, `test/deploy.sh`, Tests.

**Tasks:**
1. Firewall + Server, IP der TEST-VM in die Agent-Firewall (für Registry-Pull) eintragen.
2. Docker + Caddy mit Wildcard oder Subdomain pro Projekt (`<projekt>.TEST_DOMAIN`).
3. `deploy.sh <projekt> <version>` nutzt denselben `update.sh`-Weg wie PROD (nicht interaktiv, nur additive Migrationen; ändernde → Abbruch mit Hinweis).

**Abnahme:** CI-Key kann nur `deploy.sh` ausführen; HTTPS-Zertifikat gültig; fremde IP kommt nicht ran.

## PR 4 – Projekt-Vorlage und sicheres Update

**Security-Gate:** Betrifft echte Kundendaten auf PROD. Grundsatz: Update ändert Daten nur mit Freigabe, nie ohne geprüftes Backup, und kann zurückgerollt werden. Hermes hat keinen PROD-Zugang.

**Dateien (Template-Repo `vorlage-app`):** `deploy/compose.yaml`, `deploy/update.sh`, `deploy/.env.example`, `db/migrations/*.sql`, `scripts/lint-migrations.sh`, `.gitea/workflows/ci.yaml`, `.gitea/workflows/release.yaml`, `tests/update/*.bats`, `docs/BETRIEB.md`.

**Deployment-Vertrag (jedes Projekt):**
- Auslieferung als Image `GITEA_DOMAIN/<org>/<projekt>:<version>`; `deploy/` im Repo.
- Daten nur in benannten Volumes; `.env` und Volumes werden vom Update nie überschrieben.
- Seeds nur bei leerer DB. Keine Auto-Migration beim App-Start.
- Health-Endpoint `/healthz`.
- Migration-Kopf: `-- kind: additive` oder `-- kind: changing` (+ `-- affects: tabelle.spalte`).

**Migrations-Lint (CI-Pflicht):** `additive` darf kein `DROP`, `TRUNCATE`, `DELETE`, `UPDATE`, `RENAME`, `ALTER … TYPE`, `ALTER … DROP`, `SET NOT NULL` ohne Default enthalten. Fehlender Kopf = Fehler.

**`update.sh` Ablauf (PROD):**
1. Vorprüfung: Platz, aktuelle Version, Zielversion vorhanden, `git checkout <tag>` und Neustart des Skripts in der neuen Fassung.
2. Images ziehen (noch keine Änderung).
3. Plan anzeigen: alt → neu, offene Migrationen mit Art und betroffenen Spalten.
4. Freigabe: `additive` → „ja“; `changing` → Zielversion eintippen, betroffene Objekte werden aufgelistet. Abbruch = nichts geändert.
5. Backup: `pg_dump -Fc` + Volumes + `.env` + alte Version → `backups/<zeit>-<version>/`, Prüfung mit `pg_restore --list`. Ohne gültiges Backup kein Update.
6. App stoppen, migrieren, neue Version starten, Health-Check.
7. Fehler in 6 → automatischer Rollback (DB-Restore + alte Version). Protokoll in `update.log`.
- Weitere Befehle: `--list` (Versionen), `--status`, `--rollback` (letztes Backup), Aufbewahrung `KEEP_BACKUPS=10`.

**CI:** Tests → Lint → Image bauen → **Upgrade-Test** (letzte Release-Version mit Testdaten starten, auf neuen Stand aktualisieren, Zeilenanzahl/Prüfsummen vorher = nachher, außer bei freigegebenen `changing`-Migrationen) → Deploy TEST. Release über Tag `vX.Y.Z`, nur Mitarbeiter darf taggen.

**Tasks:** je ein bats-Test zuerst für: Plan-Anzeige, Abbruch ändert nichts, `changing` ohne Versionseingabe abgelehnt, kein Backup → kein Update, Health-Fehler → Rollback, `--rollback` stellt Daten wieder her, `.env` unverändert nach Update, Lint erkennt verbotene Statements.

**Abnahme:** Alle Tests grün; manueller Durchlauf mit Beispiel-App: additive Änderung, ändernde Änderung mit Freigabe, provozierter Fehler mit Rollback.

## PR 5 – Kunden-Hermes und Doku

**Security-Gate:** Agent-Prompt legt Befugnisse fest: selbstständig Code, Tests, PRs, TEST-Deploy; nie PROD, nie Merge/Tag, nie Firewall/DNS. Hermes-Approval-Modus für gefährliche Befehle bleibt aktiv.

**Dateien:** `customer/SOUL.md.tmpl` (Rolle: einziger Entwickler, Mitarbeiter reviewt/testet, kennt Code nicht; Planung mit Empfehlung; PRs; Sicherheit; UI-Regeln; Deployment-Vertrag), `customer/skills/projekt-anlegen/`, `customer/skills/release/`, `customer/skills/update-sicherheit/`, `customer/docs/` (PROD einrichten, Update, Rollback, Backup prüfen, Hermes/Gitea aktualisieren), `customer/hermes-tuning.sh` (setzt `skills.disabled` und `agent.disabled_toolsets` laut `docs/hermes-tuning.md`), `HANDOVER.md`.

**Übergabe-Checkliste:** SSH-Keys des Einrichters entfernen, Einrichter aus Hetzner-Projekt entfernen, Setup-Tokens widerrufen, Mitarbeiter setzt Gitea-Passwort, Restore einmal gemeinsam durchspielen.

**Abnahme:** Neuer Hermes-Prozess auf prod-sim-Umgebung legt per Skill ein Projekt aus der Vorlage an und erstellt einen PR.

## PR 6 – Setup-Skill und E2E

**Dateien:** Skill `agent-dev-kit-setup` (Ablauf, Platzhalter-Tabelle, Fallstricke, Verweis aufs Kit), `docs/E2E.md`.

**E2E (temporäre Server, danach löschen):** provision agent + test + prod-sim → Projekt aus Vorlage → PR → Merge → TEST-Deploy → Tag → `update.sh` auf prod-sim mit Testdaten → ändernde Migration mit Freigabe → Rollback → Übergabe-Checkliste → Port-Scan von fremder IP.

**Abnahme:** E2E-Protokoll ohne manuelle Eingriffe außer den vorgesehenen Freigaben; Server gelöscht.

---

## Nicht enthalten (Backlog)
- VPN-Einrichtung (separat), DNS-Einträge anlegen (Kunde/Platzhalter), Installation des PROD-Servers selbst.
- Monitoring/Alarmierung (z. B. Mail bei fehlgeschlagenem Backup).
- SSO für Gitea.
- Docker-Sandbox nur für Recherche-Subagenten (fremder Web-Inhalt, Prompt-Injection).
- `docs/hermes-tuning.md` nach größeren Hermes-Updates neu prüfen.

## Risiken
- Remote-Anbindung der Desktop-App: per Spike geklärt (SSH-Modus), Test mit echter Desktop-App unter Windows steht noch aus.
- DNS-Anbieter des Kunden ohne Caddy-DNS-Modul → Fallback HTTP-01 (Port 80 öffentlich).
- Frameworks mit eigenem Migrator (Prisma, Django, EF) passen nicht direkt zu `dbmate` → Vertrag verlangt dann exportierte SQL-Migrationen mit Kopf; prüfen, sobald der Stack feststeht.
- Hermes-/Gitea-Updates nach der Übergabe liegen beim Mitarbeiter → Doku + Hinweis-Skill, kein Auto-Update.
