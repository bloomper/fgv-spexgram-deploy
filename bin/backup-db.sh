#!/usr/bin/env bash
# Dumps Spexgram's and Immich's databases into backups/, pruning dumps older than BACKUP_KEEP_DAYS (14). Immich also
# keeps nightly dumps of its own in data/immich/backups, which bin/backup-media.sh copies off the host.
set -euo pipefail

cd "$(dirname "$0")/.."
umask 077

keep_days=${BACKUP_KEEP_DAYS:-14}
target=backups/$(date +%Y-%m-%dT%H%M%S)
mkdir -p "$target"

docker compose exec -T spexgram-mysql sh -c \
  "MYSQL_PWD=\$(cat /run/secrets/MYSQL_ROOT_PASSWORD) exec mysqldump -uroot --single-transaction --routines --triggers --events --default-character-set=utf8mb4 \"\$MYSQL_DATABASE\"" \
  | gzip > "$target/spexgram-mysql.sql.gz"
echo "wrote $target/spexgram-mysql.sql.gz"

docker compose exec -T immich-postgres pg_dump --clean --if-exists -U immich immich \
  | gzip > "$target/immich-postgres.sql.gz"
echo "wrote $target/immich-postgres.sql.gz"

find backups -mindepth 1 -maxdepth 1 -type d -mtime "+$keep_days" -exec rm -rf {} +
