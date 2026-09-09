#!/usr/bin/env bash
# validate.sh — environment validation for the BARQ DevOps assessment.
# Checks: public access, all required endpoints, both backend identities,
# PostgreSQL/Redis readiness, and that prohibited host ports are NOT reachable.
# Bounded waits, PASS/FAIL per check, non-zero exit on any failure.

set -uo pipefail

HOST="${PUBLIC_HOST:-localhost}"
PORT="${PUBLIC_PORT:-8080}"
BASE_URL="http://${HOST}:${PORT}"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-30}"
POLL_INTERVAL=2

PASS_COUNT=0
FAIL_COUNT=0

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo "FAIL: $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

# Wait (bounded) for the public endpoint to respond at all before running checks.
wait_for_public_access() {
    local waited=0
    while [ "$waited" -lt "$MAX_WAIT_SECONDS" ]; do
        if curl -s -o /dev/null --max-time 3 "${BASE_URL}/"; then
            pass "Public access reachable at ${BASE_URL}/ (waited ${waited}s)"
            return 0
        fi
        sleep "$POLL_INTERVAL"
        waited=$((waited + POLL_INTERVAL))
    done
    fail "Public access NOT reachable at ${BASE_URL}/ after ${MAX_WAIT_SECONDS}s"
    return 1
}

# Wait (bounded) for /ready to report both dependencies ready.
wait_for_readiness() {
    local waited=0
    local body
    while [ "$waited" -lt "$MAX_WAIT_SECONDS" ]; do
        body=$(curl -s --max-time 3 "${BASE_URL}/ready")
        if echo "$body" | grep -q '"status":"ready"'; then
            pass "Dependencies ready (postgres + redis) after ${waited}s"
            return 0
        fi
        sleep "$POLL_INTERVAL"
        waited=$((waited + POLL_INTERVAL))
    done
    fail "Dependencies NOT ready after ${MAX_WAIT_SECONDS}s. Last response: ${body}"
    return 1
}

# Generic endpoint check: expects a specific HTTP status code.
check_endpoint() {
    local path="$1"
    local expected_status="$2"
    local method="${3:-GET}"
    local data="${4:-}"
    local status

    if [ -n "$data" ]; then
        status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
            -X "$method" -H "Content-Type: application/json" -d "$data" \
            "${BASE_URL}${path}")
    else
        status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
            -X "$method" "${BASE_URL}${path}")
    fi

    if [ "$status" = "$expected_status" ]; then
        pass "${method} ${path} -> ${status} (expected ${expected_status})"
    else
        fail "${method} ${path} -> ${status} (expected ${expected_status})"
    fi
}

# Confirm both backend instances actually serve traffic through NGINX by
# sampling /instance enough times to see both instance_ids appear.
check_both_backends_served() {
    local samples=20
    local seen_01=0
    local seen_02=0
    local i body

    for i in $(seq 1 "$samples"); do
        body=$(curl -s --max-time 3 "${BASE_URL}/instance")
        if echo "$body" | grep -q '"instance_id":"app-01"'; then
            seen_01=1
        fi
        if echo "$body" | grep -q '"instance_id":"app-02"'; then
            seen_02=1
        fi
    done

    if [ "$seen_01" -eq 1 ] && [ "$seen_02" -eq 1 ]; then
        pass "Both app-01 and app-02 served /instance across ${samples} requests"
    else
        fail "Did not observe both backends in ${samples} requests (app-01 seen=${seen_01}, app-02 seen=${seen_02})"
    fi
}

# Confirm a prohibited host port is NOT reachable from outside Docker.
check_port_not_published() {
    local port="$1"
    local label="$2"

    if curl -s -o /dev/null --max-time 2 "http://${HOST}:${port}/" 2>/dev/null; then
        fail "${label} port ${port} is reachable from host (should NOT be published)"
    else
        pass "${label} port ${port} is NOT reachable from host (correctly isolated)"
    fi
}

echo "=== BARQ Assessment Validation ==="
echo "Target: ${BASE_URL}"
echo

wait_for_public_access
wait_for_readiness

check_endpoint "/" 200
check_endpoint "/health" 200
check_endpoint "/ready" 200
check_endpoint "/instance" 200
check_endpoint "/records" 200
check_endpoint "/records" 201 POST '{"title":"validation-run-record"}'
check_endpoint "/counter" 200
check_endpoint "/nonexistent-path" 404

check_both_backends_served

check_port_not_published 15432 "PostgreSQL"
check_port_not_published 16379 "Redis"

echo
echo "=== Summary ==="
echo "PASS: ${PASS_COUNT}"
echo "FAIL: ${FAIL_COUNT}"

if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "RESULT: FAIL"
    exit 1
else
    echo "RESULT: PASS"
    exit 0
fi
