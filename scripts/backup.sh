#!/usr/bin/env bash
set -euo pipefail

DATE=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="${BACKUP_DIR:-/var/backups/swaga-bot}"
mkdir -p "$BACKUP_DIR"

pg_dump "$SUPABASE_DB_URL" \
  --no-owner --no-privileges \
  --exclude-table-data='public.rate_limits' \
  | gzip > "$BACKUP_DIR/db-$DATE.sql.gz"

find "$BACKUP_DIR" -name "db-*.sql.gz" -mtime +14 -delete
