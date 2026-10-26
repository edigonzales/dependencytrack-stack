# Lokale Prüfung vom 26. Oktober 2026

Geprüft auf macOS/arm64 mit Docker Engine 29.8.2 und Compose 5.5.1.
Die Container liefen mit den ausgelieferten Speicherlimits. Die Docker-VM
hatte insgesamt 8 GB RAM; das ersetzt keinen Lasttest auf dem 4-GB-Zielserver.

## Erfolgreich geprüft

- `docker compose config --quiet` und `caddy validate` für den gelieferten Stack.
- Image-Manifeste: API, Frontend, Caddy, PostgreSQL und Trivy unterstützen
  sowohl `linux/amd64` als auch `linux/arm64`.
- Start mit PostgreSQL 18.6, Dependency-Track 5.2.1 und Caddy 2.11.7 mit
  benannten Volumes; Datenbank-, API- und Frontend-Healthchecks erfolgreich.
- Isolierte lokale Portfreigaben: nur Caddy auf `127.0.0.1:18080/18443`.
  HTTP liefert 308, HTTPS funktioniert mit explizit vertrauter lokaler Caddy-CA.
- Frontend-Konfiguration, `/api/version`, Erstlogin, Änderung des
  Standardpassworts und anschliessender Login über HTTPS.
- Eigenes CI-Team mit ausschliesslich `BOM_UPLOAD` und
  `PROJECT_CREATION_UPLOAD`; vier Multipart-Uploads mit automatischer
  Projektanlage und getrennten Zielprojekten erfolgreich.
- Echter Trivy-0.76.1-Container-Scan des veröffentlichten
  `ghcr.io/sogis/datenportal-sodata-jvm` für `linux/arm64` über Digest
  `sha256:b254b0ee02a7aab563579894a6b87faa8dbaabfa2ebbe57908ac02f5842530cc`:
  CycloneDX-JSON mit 191 Komponenten; Upload an die wiederhergestellte API
  angenommen.
- `scripts/backup.sh` gegen den laufenden Stack: PostgreSQL-Custom-Dump,
  API-/Caddy-Archive, lokale Konfiguration und automatischer Wiederanlauf.
- Restore in ein separates Compose-Projekt mit frischen benannten Volumes:
  identische vier Projekt-UUIDs, Komponentenlisten und Passwort; gesicherter
  CI-Key funktioniert weiterhin. Caddys lokale CA und die API-Schlüssel sind
  erhalten geblieben.
- Vollständige Neuerstellung der Container mit erhaltenen Volumes und
  erneute Prüfung der gespeicherten Projekte und des Logins.
- `shellcheck` für das Backup-Skript und `actionlint` für die erweiterte Pipeline.
- 15 gezielte Python-Integrationstests: echter lokaler Multipart-Endpunkt,
  Projekttrennung, HTTP 401/403/500, Timeout, fehlende Konfiguration,
  Digest-Auswahl, Architektur, unvollständige SBOMs, Warnungen und
  Geheimnisbehandlung. Auch die Bereinigung von Scan-Containern wird geprüft.
- `./gradlew clean check` im Datenportal mit Java 25.0.3 erfolgreich,
  einschliesslich Vitest, TypeScript, Java- und Playwright-Prüfungen.

Wiederholbare Prüfungen im jeweiligen Repository:

```bash
# dependencytrack-stack, nach lokaler Konfiguration wie in der Anleitung
docker compose --env-file hetzner/.env -f hetzner/docker-compose.yml config --quiet
bash -n hetzner/scripts/backup.sh

# datenportal-sodata
python3 -m unittest discover -s tools -p 'test_sbom_integration.py' -v
actionlint .github/workflows/container-image.yml
./gradlew clean check
```

## Auf dem Zielsystem noch abzunehmen

Die Tests verwenden ausschliesslich lokale Testinstanzen. Keine DNS-Einträge,
Server oder GitHub-Einstellungen wurden verändert und keine Commits gepusht.

- Öffentliche Erreichbarkeit und Let's-Encrypt-Ausstellung/-Erneuerung.
- Feed-Synchronisation und Lastprüfung auf dem tatsächlichen 4-GB-Server.
- Erster echter GitHub-Lauf nach Einrichtung von `DTRACK_URL` und
  `DTRACK_API_KEY`, einschliesslich Artefaktaufbewahrung.
- Betriebssystem-Neustart und das betriebliche Offsite-Backup.

Die vollständige [Abnahmeliste](../hetzner/README.md#abnahme-auf-dem-zielserver)
und die Betriebsverfahren stehen in der Hetzner-Anleitung.
