# Dependency-Track auf Hetzner

Docker-Compose-Stack für **https://dtrack.sogeo.services**: Dependency-Track
5.2.1 (API und Frontend), PostgreSQL 18 und Caddy 2.11.7 mit automatisch
erneuerten Let's-Encrypt-Zertifikaten. Die Verzeichnisstruktur orientiert sich
an [reposilite-stack](https://github.com/edigonzales/reposilite-stack).

**[Vollständige Installation und Betriebsanleitung → hetzner/README.md](hetzner/README.md)**

[Durchgeführte lokale Prüfungen und verbleibende Server-Abnahme](docs/validation.md)

```text
hetzner/
  docker-compose.yml       Dienste, Healthchecks, Speicherlimits, Volumes
  .env.example             Domain, ACME-Kontakt und anpassbare Ressourcen
  caddy/Caddyfile           HTTPS und Routing auf derselben Domain
  scripts/backup.sh         Konsistentes Backup mit kurzer Unterbrechung
```

Ziel ist ein einzelner Server mit mindestens 2 vCPU, 4 GB RAM und SSD.
**4 GB sind ein knapper Einstieg, keine Kapazitätsgarantie.** Die offizielle
Produktionsempfehlung ist deutlich höher. Erste Feed-Synchronisationen und
SBOM-Importe müssen auf dem Zielserver beobachtet werden; bei Speicherdruck
auf 8 GB oder mehr wechseln und die Containerlimits mit erhöhen.

Die GitHub-Pipeline von
[datenportal-sodata](https://github.com/sogis/datenportal-sodata) erzeugt nach
der Veröffentlichung vier CycloneDX-SBOMs und lädt sie in getrennte Projekte.
Die [Betriebsanleitung](hetzner/README.md#github-actions-anbinden) beschreibt
die Einrichtung. Scan-/Uploadfehler werden als Warnung gemeldet.

Es werden keine Server automatisch angelegt, DNS-Einträge geändert oder
produktiven Systeme durch dieses Repository aktualisiert.
