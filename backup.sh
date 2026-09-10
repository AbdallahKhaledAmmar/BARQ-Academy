#!/usr/bin/env bash
# backup.sh — dump the PostgreSQL database to a timestamped file.
#
# What this does, in plain steps:
# 1. Make a backups/ folder if it doesn't exist yet (this folder is gitignored,
#    dumps should never be committed to the repo).
# 2. Run pg_dump inside the running postgres container.
# 3. Save the output to a file with today's date/time in the name.
# 4. Print PASS if the file was created and is not empty, FAIL otherwise.

set -uo pipefail

BACKUP_DIR="backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/barq_tasks_${TIMESTAMP}.dump"

POSTGRES_USER="barq_app"
POSTGRES_DB="barq_tasks"

echo "=== PostgreSQL Backup ==="

mkdir -p "$BACKUP_DIR"

echo "Running pg_dump inside the postgres container..."
docker compose exec -T postgres pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -F c > "$BACKUP_FILE"

if [ -s "$BACKUP_FILE" ]; then
    SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
    echo "PASS: backup created at $BACKUP_FILE (size: $SIZE)"
    exit 0
else
    echo "FAIL: backup file was not created or is empty"
    rm -f "$BACKUP_FILE"
    exit 1
fi
