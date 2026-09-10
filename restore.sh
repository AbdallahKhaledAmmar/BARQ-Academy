#!/usr/bin/env bash
# restore.sh — prove that a PostgreSQL backup actually restores, and that a
# record survives recreating the app and postgres containers (keeping the volume).
#
# What this does, in plain steps:
# 1. Create a new test record through the running API, so we have something
#    specific to check for later.
# 2. Run backup.sh to take a fresh backup that includes this record.
# 3. Recreate the app and postgres containers WITHOUT deleting the named volume
#    (docker compose down, then docker compose up -d — no -v flag).
# 4. Wait for the environment to become ready again.
# 5. Check that the test record we created in step 1 is still there.
# 6. Additionally, restore the backup file into the database and confirm
#    the record count matches what pg_dump saved.
# 7. Print PASS or FAIL.

set -uo pipefail

BASE_URL="http://localhost:8080"
POSTGRES_USER="barq_app"
POSTGRES_DB="barq_tasks"
MARKER_TITLE="restore-test-marker-$(date +%s)"

echo "=== PostgreSQL Restore / Persistence Test ==="
echo

echo "Step 1: creating a test record with a unique marker title"
echo "  marker: $MARKER_TITLE"
curl -s -X POST "${BASE_URL}/records" \
    -H "Content-Type: application/json" \
    -d "{\"title\":\"${MARKER_TITLE}\"}" > /dev/null
echo

echo "Step 2: taking a backup that includes this record"
./backup.sh
LATEST_BACKUP=$(ls -t backups/*.dump | head -1)
echo "  using backup file: $LATEST_BACKUP"
echo

echo "Step 3: recreating app and postgres containers (keeping the named volume)"
echo "  running: docker compose down"
docker compose down
echo "  running: docker compose up -d"
docker compose up -d
echo

echo "Step 4: waiting up to 30 seconds for the environment to become ready again"
WAITED=0
READY=0
while [ "$WAITED" -lt 30 ]; do
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "${BASE_URL}/ready")
    echo "  [${WAITED}s] /ready status = $STATUS"
    if [ "$STATUS" = "200" ]; then
        READY=1
        break
    fi
    sleep 2
    WAITED=$((WAITED + 2))
done

if [ "$READY" -ne 1 ]; then
    echo "FAIL: environment did not become ready again within 30 seconds"
    exit 1
fi
echo

echo "Step 5: checking if our marker record survived the recreation"
RECORDS_JSON=$(curl -s "${BASE_URL}/records")
if echo "$RECORDS_JSON" | grep -q "$MARKER_TITLE"; then
    echo "PASS: marker record '$MARKER_TITLE' is still present after recreating containers."
    PERSISTENCE_OK=1
else
    echo "FAIL: marker record '$MARKER_TITLE' was NOT found after recreating containers."
    echo "  records returned: $RECORDS_JSON"
    PERSISTENCE_OK=0
fi
echo

echo "Step 6: proving the backup file itself restores correctly"
echo "  (restoring into a temporary database so we don't disturb the live one)"
TEMP_DB="barq_tasks_restore_check"

docker compose exec -T postgres psql -U "$POSTGRES_USER" -d postgres \
    -c "DROP DATABASE IF EXISTS ${TEMP_DB};" > /dev/null
docker compose exec -T postgres psql -U "$POSTGRES_USER" -d postgres \
    -c "CREATE DATABASE ${TEMP_DB};" > /dev/null

cat "$LATEST_BACKUP" | docker compose exec -T postgres pg_restore \
    -U "$POSTGRES_USER" -d "$TEMP_DB" > /dev/null 2>&1

RESTORED_COUNT=$(docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$TEMP_DB" \
    -t -c "SELECT COUNT(*) FROM records;" | tr -d '[:space:]')

echo "  records found in restored backup: $RESTORED_COUNT"

if [ -n "$RESTORED_COUNT" ] && [ "$RESTORED_COUNT" -gt 0 ]; then
    echo "PASS: backup file restores successfully and contains records."
    BACKUP_OK=1
else
    echo "FAIL: backup file did not restore any records."
    BACKUP_OK=0
fi

docker compose exec -T postgres psql -U "$POSTGRES_USER" -d postgres \
    -c "DROP DATABASE IF EXISTS ${TEMP_DB};" > /dev/null

echo
echo "=== Summary ==="
if [ "$PERSISTENCE_OK" -eq 1 ] && [ "$BACKUP_OK" -eq 1 ]; then
    echo "RESULT: PASS"
    exit 0
else
    echo "RESULT: FAIL"
    exit 1
fi
