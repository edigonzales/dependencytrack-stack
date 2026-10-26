# Installation und Betrieb auf Hetzner

Diese Anleitung installiert Dependency-Track unter **https://dtrack.sogeo.services**
auf einem einzelnen Server. Alle Compose-Befehle werden, sofern nicht anders
angegeben, als Benutzer `dtrack` im Verzeichnis
`~/dependencytrack-stack/hetzner` ausgeführt. Docker Compose v2.24.4 oder neuer
wird vorausgesetzt (auch Compose v5 funktioniert).

## Architektur und Dimensionierung

| Dienst | Image | Speicherlimit | Erreichbarkeit |
|---|---|---|---|
| Caddy | `caddy:2.11.7-alpine` | 128 MB | Öffentlich TCP 80/443 |
| Frontend | `ghcr.io/dependencytrack/frontend:5.2.1` | 128 MB | Nur Docker-Netz, Port 8080 |
| API | `ghcr.io/dependencytrack/apiserver:5.2.1` | 2 GB | Nur Docker-Netz, Port 8080 |
| API-Management | Bestandteil der API | – | Nur Docker-Netz, Port 9000 |
| PostgreSQL | `postgres:18-alpine` | 768 MB | Nur Docker-Netz, Port 5432 |

Der Browser verwendet dieselbe HTTPS-Adresse für UI und API. Caddy reicht
`/api` und `/api/*` unverändert an die API durch, alle anderen Pfade ans
Frontend. Es ist weder eine zweite Subdomain noch eine CORS-Freigabe nötig.
Caddy setzt die üblichen `X-Forwarded-*`-Header selbst.

Für den Einstieg: **mindestens 2 vCPU, 4 GB RAM, 40 GB SSD**, öffentliche IPv4,
optional IPv6. Alle Images unterstützen `linux/amd64` und `linux/arm64`.
Standort beispielsweise Falkenstein; Betriebssystem Ubuntu 24.04 LTS.
Auf diesem Host keine weiteren speicherintensiven Anwendungen betreiben.

**Die 4-GB-Konfiguration ist bewusst knapp.** Die
[offizielle Produktionsanleitung](https://dependencytrack.github.io/docs/next/guides/administration/deploying-to-production/)
empfiehlt bereits für PostgreSQL deutlich mehr Ressourcen. Die hier gesetzten
Limits sind ein Ausgangspunkt für einen kleinen Bestand, keine Zusicherung
für beliebig grosse Feeds oder viele Builds. Insbesondere die erste
Synchronisation und ein vollständiger JVM-SBOM-Import gehören zum Lasttest.
Bei OOM-Kills, dauerndem Swap oder wachsender Verarbeitungswarteschlange den
Host und die Limits erhöhen; Swap ersetzt keinen RAM.

Die JVM verwendet standardmässig bis zu 80 % des API-Containerlimits als Heap.
PostgreSQL ist auf 30 Verbindungen, 128 MB `shared_buffers` und 4 MB `work_mem`
pro Operation begrenzt; der API-Pool verwendet maximal zehn Verbindungen.
Es gibt eine API-Instanz und keine Hochverfügbarkeit.

## 1. Server und Firewall vorbereiten

In der Hetzner Cloud Console einen Server mit dem oben beschriebenen Profil
und dem eigenen SSH-Public-Key erstellen. Eine Primary IPv4 erleichtert den
Zugriff von GitHub-Runnern. Keine Floating IP und kein Load Balancer nötig.

Eine Hetzner Cloud Firewall erstellen und dem Server zuweisen:

| Richtung | Protokoll/Port | Quelle/Ziel |
|---|---|---|
| Eingehend | TCP 22 | Nur eigene Administrator-IP-Adressen bzw. CIDRs |
| Eingehend | TCP 80 | Alle IPv4/IPv6-Adressen; HTTP und ACME-Challenge |
| Eingehend | TCP 443 | Alle IPv4/IPv6-Adressen; UI, API und GitHub Actions |
| Ausgehend | Standard: alles erlauben | DNS, NTP, HTTPS, Registries und Paketquellen |

Keine Freigaben für 5432, 8080, 8081, 9000 oder Caddys Admin-Port 2019
anlegen. Es werden auch keine solchen Ports auf dem Host veröffentlicht.
Die Hetzner-Firewall schützt unabhängig von Docker-Portfreigaben; bei UFW
allein die Docker-iptables-Regeln berücksichtigen. HTTP/3 ist deaktiviert,
daher wird kein UDP-Port 443 benötigt.

Als `root` per SSH anmelden:

```bash
ssh root@SERVER_IPV4
apt-get update
apt-get upgrade -y
apt-get install -y ca-certificates curl git openssl
adduser --disabled-password --gecos '' dtrack
install -d -o dtrack -g dtrack -m 700 /home/dtrack/.ssh
install -o dtrack -g dtrack -m 600 /root/.ssh/authorized_keys /home/dtrack/.ssh/authorized_keys
```

Docker aus dem offiziellen Ubuntu-Paketrepository von Docker installieren
([Herstelleranleitung](https://docs.docker.com/engine/install/ubuntu/)):

```bash
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
usermod -aG docker dtrack
```

Die Docker-Gruppe gewährt praktisch Root-Rechte; nur den Betriebsbenutzer
aufnehmen. Danach eine neue SSH-Sitzung öffnen:

```bash
ssh dtrack@SERVER_IPV4
docker version
docker compose version
```

Betriebssystem-Sicherheitsupdates regelmässig installieren und notwendige
Neustarts einplanen. Hetzner-Backups aktivieren; zusätzlich die unten
beschriebenen Anwendungsbackups ausserhalb dieses Servers aufbewahren.

## 2. DNS setzen

In der DNS-Zone `sogeo.services` einen **A-Record `dtrack`** auf die öffentliche
IPv4 des Servers setzen. Einen AAAA-Record nur setzen, wenn die zugehörige
IPv6-Adresse auf diesem Server korrekt konfiguriert und erreichbar ist.
Ein falscher AAAA-Record kann Zertifikatsausstellung und Clientzugriffe stören.

Vom eigenen Rechner prüfen, beispielsweise mit `dig`:

```bash
dig +short A dtrack.sogeo.services
dig +short AAAA dtrack.sogeo.services
```

Port 80 und 443 müssen auf diesen Server zeigen. Falls CAA-Einträge die
Zertifikatsausstellung begrenzen, `letsencrypt.org` erlauben. Bei einem
DNS-Anbieter mit HTTP-Proxy zunächst nur DNS verwenden.

## 3. Konfiguration und Start

```bash
cd ~
git clone https://github.com/edigonzales/dependencytrack-stack.git
cd dependencytrack-stack/hetzner
cp .env.example .env
chmod 600 .env
nano .env
```

`DTRACK_DOMAIN` ist ein Hostname ohne Protokoll oder Pfad. In `ACME_EMAIL`
eine eigene erreichbare E-Mail-Adresse eintragen. `admin@example.com` ist
nur ein Platzhalter. `COMPOSE_PROJECT_NAME` nach dem ersten Start stabil
halten: Er bestimmt die Namen der Daten-Volumes.

Das Datenbankpasswort wird nicht in `.env` oder Compose gespeichert:

```bash
install -d -m 700 secrets
openssl rand -hex 32 > secrets/postgres_password
chmod 644 secrets/postgres_password
```

Das Verzeichnis ist nur für den Betriebsbenutzer zugänglich. Die Datei selbst
ist lesbar, damit auch die nicht privilegierte UID im API-Container das
eingebundene Secret lesen kann. Bei lokalem Compose sind Secrets
Dateimounts, kein verschlüsselter Secret-Speicher; `uid`/`gid`/`mode` werden
für solche Bind-Mounts nicht zuverlässig umgesetzt. Die API lädt den Wert
über die MicroProfile-Dateireferenz, PostgreSQL über `POSTGRES_PASSWORD_FILE`.

```bash
docker compose config --quiet
docker compose pull
docker compose run --rm --no-deps caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
docker compose up -d --wait --wait-timeout 900
docker compose ps
```

Der erste API-Start initialisiert Datenbank, Schlüssel und Hintergrunddienste
und kann mehrere Minuten dauern. Caddy startet erst nach Bereitschaft der
API. Nach einem Timeout zunächst die Logs prüfen, statt Volumes zu löschen:

```bash
docker compose logs --tail=150 apiserver postgres caddy
docker compose exec -T apiserver wget -qO- http://127.0.0.1:9000/health/ready
curl -I http://dtrack.sogeo.services
curl -fsS https://dtrack.sogeo.services/ -o /dev/null
```

Der HTTP-Aufruf muss zu HTTPS umleiten. HTTPS muss ohne `-k` erfolgreich
sein. Caddy fordert ausdrücklich Let's-Encrypt-Zertifikate an und erneuert
sie selbständig. Dafür müssen DNS und Ports dauerhaft stimmen und das
Volume `caddy-data` erhalten bleiben. Es braucht weder Certbot noch einen
Renewal-Cronjob. In Caddys Logs erscheinen Zertifikatsfehler und Erneuerungen;
Request-Header mit API-Keys werden nicht als Access-Log ausgegeben.

Für wiederholte ACME-Experimente kann vorübergehend
`ACME_CA=https://acme-staging-v02.api.letsencrypt.org/directory` verwendet
werden. Staging-Zertifikate sind absichtlich nicht browservertrauenswürdig.
Anschliessend die Produktionsadresse aus `.env.example` wieder setzen und
`docker compose up -d --force-recreate caddy` ausführen. Nicht ständig
Zertifikatsvolumes löschen: Let's Encrypt hat Rate Limits.

## 4. Erstlogin und CI-Zugang

1. **https://dtrack.sogeo.services** öffnen.
2. Mit `admin` / `admin` anmelden und das Passwort **sofort** ändern. Dieses
   Passwort ist allgemein bekannt.
3. Persönliche Benutzer für den normalen Betrieb anlegen; Admin nur für
   Administration verwenden. Für einen späteren zentralen Login unterstützt
   Dependency-Track OIDC und LDAP.
4. Unter **Administration → Access Management → Teams** ein dediziertes
   Team `datenportal-ci` anlegen.
5. Genau die Berechtigungen `BOM_UPLOAD` und `PROJECT_CREATION_UPLOAD`
   zuweisen. Für reines Hochladen sind keine Administratorrechte nötig.
6. Einen API-Key für dieses Team erzeugen und im Passwortmanager sichern.
   Bei aktivierter Portfolio-Zugriffskontrolle dem Team auch Zugriff auf
   bereits vorhandene Zielprojekte geben. Neu über diesen Team-Key angelegte
   Projekte erhalten die Team-Zuordnung automatisch.

Die vier Zielprojekte werden beim ersten Upload automatisch angelegt.
Weitere Image-Versionen erscheinen als weitere Projektversionen. Bei
Key-Rotation erst das GitHub-Secret aktualisieren, einen erfolgreichen
Upload prüfen und dann den alten Key widerrufen.

## 5. Schwachstellenquellen und erster Import

Ein erfolgreicher Upload bedeutet zunächst nur, dass die SBOM angenommen
wurde. Ergebnisse setzen passende Datenquellen und eine abgeschlossene
Analyse voraus. Unter **Administration → Vulnerability Sources** die
gewünschten Quellen aktivieren und die erste Synchronisation mit **Mirror
now** starten ([Herstelleranleitung](https://dependencytrack.github.io/docs/next/guides/administration/configuring-vulnerability-sources/)).

- **OSV** für benötigte Ökosysteme, insbesondere Maven, aktivieren. Nur
  tatsächlich benötigte Ökosysteme auswählen.
- **GitHub Advisories** benötigt einen GitHub-PAT ohne zusätzliche Scopes
  oder eine GitHub-App-Konfiguration. Dieses Token ist ein separates
  Integrationssecret, nicht der `DTRACK_API_KEY`.
- **NVD** liefert CPE-basierte Daten. Pakete mit ausschliesslich PURL werden
  dadurch nicht automatisch abgedeckt; die erste Spiegelung kann lange dauern.

Ausgehendes HTTPS zu `nvd.nist.gov`, `api.github.com` und
`storage.googleapis.com` muss möglich sein. Quellen auf dem kleinen Host
nacheinander initialisieren und parallel RAM/Platte beobachten:

```bash
docker compose logs -f --tail=100 apiserver
```

In einer zweiten Sitzung:

```bash
docker stats --no-stream
free -h
df -h
docker inspect --format '{{.Name}}: OOMKilled={{.State.OOMKilled}} Restarts={{.RestartCount}}' $(docker compose ps -q)
```

Für einen manuellen ersten Import ein veröffentlichtes Image verwenden:

```bash
mkdir -p /tmp/dtrack-sbom
docker run --rm --user "$(id -u):$(id -g)" \
  -e TRIVY_CACHE_DIR=/tmp/trivy-cache \
  -v /tmp/dtrack-sbom:/work aquasec/trivy:0.76.1 image \
  --image-src remote --platform linux/amd64 --timeout 10m \
  --format cyclonedx --output /work/sbom.json \
  ghcr.io/sogis/datenportal-sodata-jvm:latest
```

Für reproduzierbare Prüfungen `latest` durch einen vorhandenen Versionstag
oder Digest ersetzen. Den API-Key verdeckt eingeben und hochladen:

```bash
read -r -s -p 'Dependency-Track API-Key: ' DTRACK_API_KEY
echo
curl -fsS --connect-timeout 10 --max-time 120 \
  -X POST https://dtrack.sogeo.services/api/v1/bom \
  -H "X-Api-Key: $DTRACK_API_KEY" \
  -F 'autoCreate=true' \
  -F 'projectName=datenportal-smoketest' \
  -F 'projectVersion=manual-test' \
  -F 'bom=@/tmp/dtrack-sbom/sbom.json'
unset DTRACK_API_KEY
```

Die Antwort enthält einen Verarbeitungstoken. Danach in der UI das Projekt
öffnen, Komponentenanzahl und Verarbeitung prüfen und auf Analyseergebnisse
warten. Mit einem gezielt ausgewählten SBOM mit bekannten Schwachstellen
auch die Quellenanbindung prüfen. Ein leerer Findings-Bildschirm unmittelbar
nach dem Upload ist kein Nachweis, dass das Image keine Schwachstellen hat.
Das Testprojekt kann anschliessend in der UI gelöscht werden.

## GitHub Actions anbinden

Im Repository **datenportal-sodata**, unter **Settings → Secrets and
variables → Actions**, Folgendes anlegen:

| Typ | Name | Wert |
|---|---|---|
| Repository variable | `DTRACK_URL` | `https://dtrack.sogeo.services` |
| Repository secret | `DTRACK_API_KEY` | API-Key des Teams `datenportal-ci` |

`DTRACK_URL` enthält weder `/api` noch einen abschliessenden API-Endpunkt.
Keine zusätzliche Basic-Authentifizierung vor `/api/*` setzen: CI
authentifiziert sich mit dem API-Key. GitHub-Runner müssen die HTTPS-Adresse
öffentlich erreichen können.

Nach dem nächsten erfolgreichen Push auf `main` startet der zusätzliche
Job erst **nach** Veröffentlichung und Prüfung sämtlicher Multiarch-Manifeste.
Vier Matrix-Einträge laufen mit `max-parallel: 1`:

| GHCR-Image | Architektur | Projektname |
|---|---|---|
| `sogis/datenportal-sodata` | amd64 | `datenportal-native-amd64` |
| `sogis/datenportal-sodata` | arm64 | `datenportal-native-arm64` |
| `sogis/datenportal-sodata-jvm` | amd64 | `datenportal-jvm-amd64` |
| `sogis/datenportal-sodata-jvm` | arm64 | `datenportal-jvm-arm64` |

`projectVersion` ist der vorhandene Image-Tag, beispielsweise `0.1.187`.
Jeder Architektur-Tag wird zu einem Digest aufgelöst und mit Trivy 0.76.1
gescannt. Die Docker-Hub-Kopien müssen nicht erneut gescannt werden.
Die Pipeline archiviert erzeugte SBOMs für 14 Tage. Pull Requests führen
diesen zusätzlichen Job nicht aus.

Scanfehler, fehlende Konfiguration oder Uploadfehler erscheinen als
**Warnung** und im **Job Summary**. Die Images bleiben veröffentlicht;
weitere Varianten werden verarbeitet. Ein erfolgreicher Workflow allein
beweist deshalb keinen erfolgreichen Import. Im ersten Lauf alle vier
Zusammenfassungen auf **Upload accepted** und anschliessend in Dependency-Track
alle vier Projekte mit passender Version prüfen. Bei einem ausgefallenen
Server das SBOM-Artefakt herunterladen und nach Behebung erneut hochladen.

**Grenze des Image-Scans:** Das Native-Image enthält kompilierte Java-Bibliotheken,
keine vollständig auswertbaren JARs. Trivy kann diese Abhängigkeiten aus dem
Binary nicht vollständig rekonstruieren. Das JVM-Image bietet bessere
Java-Abdeckung; auch gebündelte/minifizierte Frontend-Bibliotheken werden
nicht zwingend vollständig erkannt. Eine vollständige Build-Abhängigkeitsliste
würde ergänzende Gradle-/npm-SBOMs benötigen. Diese Integration erzeugt
ausschliesslich die vereinbarten Image-SBOMs.

## Laufender Betrieb

```bash
docker compose ps
docker compose logs --tail=100 apiserver
docker compose logs --tail=100 caddy
docker compose restart apiserver
docker compose exec -T apiserver wget -qO- http://127.0.0.1:9000/health/ready
docker system df
```

Die Docker-Logs rotieren je Container bei 10 MB mit drei Dateien. Bei
Konfigurationsänderungen `docker compose up -d` verwenden; ein einfaches
`restart` übernimmt keine geänderten Umgebungsvariablen. Nach Host-Neustarts
starten die Container automatisch. Bis die API bereit ist, kann Caddy
vorübergehend 502 melden. Healthchecks allein starten einen ungesunden
laufenden Container nicht neu; bei wiederkehrenden Problemen Ursache prüfen.

### Daten und Versionsaufbewahrung

| Volume | Inhalt |
|---|---|
| `dependencytrack_postgres-data` | Projekte, Komponenten, Findings, Benutzer und Analysezustand |
| `dependencytrack_apiserver-data` | API-Dateien, temporäre Importdaten und insbesondere `/data/.dependency-track/keys/secret-management-kek.json` |
| `dependencytrack_caddy-data` | ACME-Konto, private Schlüssel und Zertifikate |
| `dependencytrack_caddy-config` | Caddys persistente Konfiguration |

Andere Projektnamen ändern den Präfix. **`docker compose down -v` löscht diese
Daten. Im normalen Betrieb niemals verwenden.** `docker compose down`
erhält die Volumes. Ein frisches Checkout allein enthält keine Nutzdaten.

Jeder Build legt neue Versionen an und vergrössert den Bestand. Monatlich
prüfen: Produktiv eingesetzte und noch unterstützte Versionen behalten,
veraltete Build-Versionen nach einem Backup über die UI entfernen. Es ist
keine automatische Löschung konfiguriert. Aufbewahrung von 14 Tagen betrifft
nur GitHub-Artefakte, nicht Dependency-Track-Projekte oder Serverbackups.

### Updates

1. Release Notes und gegebenenfalls Migrationsanleitung lesen.
2. Ein vollständiges Backup erstellen und ausserhalb des Hosts sichern.
3. Gewünschten Git-Stand holen; Änderungen an `.env.example` mit `.env`
   vergleichen. `DTRACK_VERSION` für API und Frontend gemeinsam aktualisieren,
   Caddy-Version separat setzen.
4. `docker compose config --quiet`, `docker compose pull` und
   `docker compose up -d --wait --wait-timeout 900` ausführen.
5. Healthcheck, Login und einen SBOM-Upload prüfen.

`postgres:18-alpine` übernimmt beim expliziten Pull Updates innerhalb von 18.
Ein Wechsel auf PostgreSQL 19 ist ein eigenständiges Datenbank-Upgrade mit
Dump/Restore oder `pg_upgrade`; nur den Tag zu ändern reicht nicht.
Nach einer Datenbankmigration ist ein Downgrade der API nicht sicher:
für einen Rollback den vollständigen alten Backup-Stand mit den passenden
Image-Versionen in frische Volumes wiederherstellen.

### Datenbankpasswort ändern

Das Secret wird von PostgreSQL nur bei der **ersten Initialisierung** als
Passwort gesetzt. Später die Datei allein zu ändern bricht den API-Zugriff.
In einem Wartungsfenster API stoppen, mit
`docker compose exec postgres psql -U dtrack -d dtrack` eine Sitzung öffnen
und über `\password dtrack` das neue Passwort interaktiv setzen. Anschliessend
dieses Passwort in `secrets/postgres_password` ersetzen und
`docker compose up -d --force-recreate apiserver` ausführen. Danach Healthcheck
und Backup aktualisieren. Passwörter nicht in SQL-Shellargumente schreiben.

## Backup

Das mitgelieferte Skript stoppt die zuvor laufenden API-/Frontend-/Caddy-Dienste
kurz, erzeugt einen PostgreSQL-Dump und archiviert die dazu passenden Volumes
und lokalen Einstellungen. PostgreSQL bleibt aktiv. Ein EXIT-Trap startet
die zuvor laufenden Dienste auch bei einem Fehler wieder.

```bash
mkdir -p backups
bash scripts/backup.sh "$PWD/backups/$(date -u +%Y%m%dT%H%M%SZ)"
```

Das Zielverzeichnis darf noch nicht existieren. Ein fehlgeschlagenes Backup
behält `.incomplete` und darf nicht zur Wiederherstellung benutzt werden.
Bei Erfolg liegen dort:

```text
postgres.dump                 PostgreSQL-Custom-Dump
apiserver-data.tar.gz          einschliesslich KEK-Schlüsseln
caddy-data.tar.gz              einschliesslich ACME-Schlüsseln
caddy-config.tar.gz
config.tar.gz                  .env, secrets/, Compose und Caddyfile
images.txt                     konfigurierte Image-Tags
repository-revision.txt        Git-Stand des Checkouts
```

**Backups enthalten Zugangsdaten und private Schlüssel.** Nur verschlüsselt
auf ein separates Ziel übertragen, beispielsweise mit dem vorhandenen
Backup-System oder SSH auf einen verschlüsselten Backup-Speicher. Eine
Hetzner-VM-Sicherung allein ersetzt diesen konsistenten Anwendungsdump nicht.
Empfohlener Start: täglich sichern, sieben Tages- und vier Wochenstände
behalten, vor jedem Update zusätzlich sichern. Die zeitliche Ausführung
und der Offsite-Transfer müssen im eigenen Betriebs-/Backup-System eingerichtet
werden; dieses Repository installiert keine Zeitpläne.

## Wiederherstellen und Wiederherstellung testen

Die folgenden Schritte gelten für **frische, leere Volumes**, entweder auf
einem Ersatzserver oder in einem separaten Testprojekt. Niemals in eine
laufende Produktionsinstallation importieren. Passenden Repository-Stand
auschecken; alle Befehle aus dessen `hetzner`-Verzeichnis ausführen.

```bash
set -e
BACKUP_DIR=/absoluter/pfad/zum/vollstaendigen-backup
test ! -e "$BACKUP_DIR/.incomplete"
tar -xzf "$BACKUP_DIR/config.tar.gz"
chmod 600 .env
chmod 700 secrets
```

Damit sind die beim Backup verwendeten Image-Versionen und Secrets wieder
gesetzt. Für eine produktive Wiederherstellung den gleichen Projektnamen
mit frischen Volumes verwenden und DNS gegebenenfalls auf den Ersatzserver
umstellen. **Für einen Test auf demselben Docker-Host zuerst** eine eigene
Projektidentität setzen und ausschliesslich Datenbank/API starten:

```bash
export COMPOSE_PROJECT_NAME=dtrack-restore-test
docker compose up -d --wait postgres
docker compose exec -T postgres psql -U dtrack -d dtrack -Atc \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';"
```

Die Abfrage muss `0` ergeben; andernfalls abbrechen und ein neues, leeres
Projekt verwenden. Dump und Volumes wiederherstellen:

```bash
docker compose exec -T postgres pg_restore \
  --username=dtrack --dbname=dtrack --no-owner --no-acl --exit-on-error \
  < "$BACKUP_DIR/postgres.dump"
docker compose run --rm -T --no-deps --user 0 --entrypoint tar apiserver \
  -C /data -xzf - < "$BACKUP_DIR/apiserver-data.tar.gz"
docker compose run --rm -T --no-deps --entrypoint tar caddy \
  -C /data -xzf - < "$BACKUP_DIR/caddy-data.tar.gz"
docker compose run --rm -T --no-deps --entrypoint tar caddy \
  -C /config -xzf - < "$BACKUP_DIR/caddy-config.tar.gz"
docker compose up -d --wait --wait-timeout 900 apiserver
docker compose exec -T apiserver wget -qO- http://127.0.0.1:9000/health/ready
```

Damit wird auch geprüft, dass API und gesicherte Schlüssel zusammenpassen.
Auf dem Ersatzserver anschliessend `docker compose up -d --wait` ausführen
und Login, bestehende Projekte sowie einen neuen Upload prüfen.

Im Testprojekt Caddy nicht mit der Produktivdomain/den Produktivports starten.
Für einen isolierten UI-Test eine lokale Override-Datei anlegen:

```yaml
services:
  frontend:
    environment:
      API_BASE_URL: https://localhost:18443
  caddy:
    environment:
      DTRACK_DOMAIN: localhost
    ports: !override
      - "127.0.0.1:18080:80"
      - "127.0.0.1:18443:443"
```

Als `restore.local.yml` speichern, dann
`docker compose -f docker-compose.yml -f restore.local.yml up -d --wait`
ausführen. Bei entferntem Server mit
`ssh -L 18443:127.0.0.1:18443 dtrack@SERVER_IPV4` tunneln.
`https://localhost:18443` verwendet Caddys lokale CA; deren Root-Zertifikat
liegt im Test-Caddy unter `/data/caddy/pki/authorities/local/root.crt`.
Für automatisierte Tests dieses Zertifikat explizit mit `curl --cacert`
verwenden. Keine ACME-Produktionszertifikate für localhost erwarten.

Nach dem Test nur das **eigene Testprojekt** entfernen:

```bash
docker compose -f docker-compose.yml -f restore.local.yml down -v
unset COMPOSE_PROJECT_NAME
rm restore.local.yml
```

Den Restore vor dem ersten produktiven Update und danach regelmässig
wiederholen. Die API setzt beim Restore vorhandene Hintergrundarbeiten fort;
Uploads nach dem Backup-Zeitpunkt müssen erneut angestossen werden.

## Fehlerdiagnose

| Symptom | Prüfung und Massnahme |
|---|---|
| Kein Zertifikat | A/AAAA, CAA, Ports 80/443 und `docker compose logs caddy` prüfen |
| 502 nach Start | API-Readiness und Logs prüfen; Initialisierung abwarten |
| UI lädt, API fehlschlägt | `DTRACK_DOMAIN`, Frontend-`API_BASE_URL` und `/api/*`-Routing kontrollieren |
| Upload HTTP 401/403 | API-Key, Teamrechte und gegebenenfalls Projekt-ACL prüfen |
| HTTP 413 | SBOM-Grösse und API-Uploadlimit prüfen; bei Anhebung RAM-Bedarf berücksichtigen |
| curl exit 22 / 28 in CI | HTTP-Fehler bzw. Timeout; zuerst URL, Erreichbarkeit und API-Logs prüfen |
| Keine Findings | Importstatus, aktivierte Quellen, Synchronisation und Paketkennungen prüfen |
| Neustarts / Exit 137 | OOM-Status und Host-RAM prüfen; Host und Containerlimit erhöhen |
| Daten scheinbar verschwunden | Compose-Projektname und vorhandene Volumes prüfen; nicht neu initialisieren |
| API startet nach Restore nicht | Passende API-Version, Datenbankpasswort und KEK im API-Volume prüfen |

## Abnahme auf dem Zielserver

- [ ] DNS stimmt; nur die vorgesehenen Host-Ports sind erreichbar.
- [ ] HTTP leitet zu HTTPS um; Let's-Encrypt-Zertifikat ist ohne Ausnahme gültig.
- [ ] API ist bereit, Login funktioniert und das Standardpasswort ist ersetzt.
- [ ] Gewünschte Datenquellen sind synchronisiert und ein bekannter Testfall liefert Findings.
- [ ] RAM, Neustarts und Plattenbelegung während Synchronisation und JVM-SBOM-Import geprüft.
- [ ] Alle vier Pipeline-Uploads wurden angenommen; passende Projekte/Versionen sind sichtbar.
- [ ] Dienste/Host neu gestartet; Daten und Login bleiben erhalten.
- [ ] Konsistentes Backup erstellt, Offsite-Kopie vorhanden und Restore in separatem Projekt geprüft.

## Quellen

- [Dependency-Track Quickstart](https://dependencytrack.github.io/docs/next/tutorials/quickstart/)
- [Produktion und Dimensionierung](https://dependencytrack.github.io/docs/next/guides/administration/deploying-to-production/)
- [Berechtigungen](https://dependencytrack.github.io/docs/next/reference/permissions/)
- [Backup und Restore](https://dependencytrack.github.io/docs/next/guides/administration/backing-up/)
- [Caddy Automatic HTTPS](https://caddyserver.com/docs/automatic-https)
- [Trivy CycloneDX-SBOMs](https://trivy.dev/docs/latest/supply-chain/sbom/)
