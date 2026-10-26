#!/usr/bin/env bash
# Aufruf: bash scripts/backup.sh /absoluter/pfad/zu/einem/neuen-backup
set -euo pipefail
umask 077

stack_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# != 1 || $1 != /* ]]; then
  echo "Aufruf: bash scripts/backup.sh /absoluter/pfad/zu/einem/neuen-backup" >&2
  exit 2
fi
backup_dir=$1
mkdir -- "$backup_dir" # Bestehende Backups niemals überschreiben.
touch "$backup_dir/.incomplete"
cd -- "$stack_dir"
compose=(docker compose --env-file .env -f docker-compose.yml)
"${compose[@]}" config --quiet

# Nur die zuvor laufenden Dienste nach dem Backup wieder starten.
stopped_services=()
while IFS= read -r service; do
  case "$service" in
    apiserver|frontend|caddy) stopped_services+=("$service") ;;
  esac
done < <("${compose[@]}" ps --services --status running)
restart_services() {
  if (( ${#stopped_services[@]} )); then
    "${compose[@]}" start "${stopped_services[@]}"
  fi
}
trap restart_services EXIT
if (( ${#stopped_services[@]} )); then
  "${compose[@]}" stop "${stopped_services[@]}"
fi

# Variablen sollen im Container, nicht auf dem Host, expandieren.
# shellcheck disable=SC2016
"${compose[@]}" exec -T postgres sh -c \
  'exec pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --format=custom' \
  > "$backup_dir/postgres.dump"
"${compose[@]}" run --rm -T --no-deps --entrypoint tar apiserver \
  -C /data -czf - . > "$backup_dir/apiserver-data.tar.gz"
"${compose[@]}" run --rm -T --no-deps --entrypoint tar caddy \
  -C /data -czf - . > "$backup_dir/caddy-data.tar.gz"
"${compose[@]}" run --rm -T --no-deps --entrypoint tar caddy \
  -C /config -czf - . > "$backup_dir/caddy-config.tar.gz"
tar -czf "$backup_dir/config.tar.gz" .env secrets caddy/Caddyfile docker-compose.yml
"${compose[@]}" config --images > "$backup_dir/images.txt"
if ! git rev-parse HEAD > "$backup_dir/repository-revision.txt" 2>/dev/null; then
  echo "unknown (not a Git checkout)" > "$backup_dir/repository-revision.txt"
fi
rm -- "$backup_dir/.incomplete"
echo "Backup vollständig: $backup_dir"
