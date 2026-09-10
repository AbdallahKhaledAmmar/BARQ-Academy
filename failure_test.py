#!/usr/bin/env python3
"""
failure_test.py

What this script does, in plain steps:
1. Check the app is healthy before we start.
2. Stop app-01 using docker compose.
3. Send 10 requests to /instance and print what comes back.
   - We expect to only see app-02 answering, since app-01 is stopped.
4. Start app-01 again.
5. Wait a bit and keep checking until Docker says app-01 is healthy.
6. Send more requests to /instance and check that app-01 answers again.
7. Print PASS or FAIL at the end.
"""

import json
import subprocess
import sys
import time
import urllib.request

BASE_URL = "http://localhost:8080"
SERVICE_TO_STOP = "app-01"


def get_instance_id():
    """Send one GET request to /instance and return the instance_id, or None on error."""
    try:
        response = urllib.request.urlopen(BASE_URL + "/instance", timeout=3)
        data = json.loads(response.read())
        return data.get("instance_id")
    except Exception as error:
        print("  request failed:", error)
        return None


def is_ready():
    """Return True if /ready responds with status 200."""
    try:
        response = urllib.request.urlopen(BASE_URL + "/ready", timeout=3)
        return response.status == 200
    except Exception:
        return False


def run_docker_command(args):
    """Run a docker compose command and print it, like typing it in the terminal."""
    full_command = ["docker", "compose"] + args
    print("Running:", " ".join(full_command))
    result = subprocess.run(full_command, capture_output=True, text=True)
    print(result.stdout.strip())
    return result.returncode


def get_health_status(service_name):
    """Ask docker compose what the health status of a service is right now."""
    result = subprocess.run(
        ["docker", "compose", "ps", service_name, "--format", "{{.Health}}"],
        capture_output=True, text=True,
    )
    return result.stdout.strip()


# ---- Step 1: check everything is healthy before we start ----

print("Step 1: checking the environment is ready before starting the test")
if not is_ready():
    print("FAIL: environment is not ready, stopping test")
    sys.exit(1)
print("OK, environment is ready.\n")


# ---- Step 2: stop app-01 ----

print(f"Step 2: stopping {SERVICE_TO_STOP}")
run_docker_command(["stop", SERVICE_TO_STOP])
print()


# ---- Step 3: send requests while app-01 is stopped ----

print("Step 3: sending 10 requests to /instance while app-01 is stopped")
app01_count = 0
app02_count = 0
error_count = 0

for i in range(1, 11):
    instance_id = get_instance_id()
    print(f"  request {i}: instance_id = {instance_id}")
    if instance_id == "app-01":
        app01_count += 1
    elif instance_id == "app-02":
        app02_count += 1
    else:
        error_count += 1
    time.sleep(1)

print()
print(f"Results during outage: app-01 answered {app01_count} times, "
      f"app-02 answered {app02_count} times, errors = {error_count}")

outage_test_passed = True

if app01_count > 0:
    print("FAIL: app-01 answered even though it should be stopped.")
    outage_test_passed = False

if app02_count == 0:
    print("FAIL: app-02 never answered, so the service was actually down.")
    outage_test_passed = False

if outage_test_passed:
    print("PASS: the service stayed available through app-02 while app-01 was down.")
print()


# ---- Step 4: start app-01 again ----

print(f"Step 4: starting {SERVICE_TO_STOP} again")
run_docker_command(["start", SERVICE_TO_STOP])
print()


# ---- Step 5: wait for app-01 to become healthy ----

print(f"Step 5: waiting for {SERVICE_TO_STOP} to become healthy (checking every 2 seconds, max 30 seconds)")
seconds_waited = 0
became_healthy = False

while seconds_waited < 30:
    health = get_health_status(SERVICE_TO_STOP)
    print(f"  [{seconds_waited}s] health = {health}")
    if health == "healthy":
        became_healthy = True
        break
    time.sleep(2)
    seconds_waited += 2

if not became_healthy:
    print(f"FAIL: {SERVICE_TO_STOP} did not become healthy within 30 seconds.")
    sys.exit(1)

print(f"OK, {SERVICE_TO_STOP} is healthy again.\n")


# ---- Step 6: confirm app-01 is actually serving requests again ----

print("Step 6: sending 15 requests to /instance to confirm app-01 is back")
app01_after_count = 0

for i in range(1, 16):
    instance_id = get_instance_id()
    if instance_id == "app-01":
        app01_after_count += 1
    time.sleep(0.5)

print(f"app-01 answered {app01_after_count} out of 15 requests after restarting.")

recovery_test_passed = app01_after_count > 0
if recovery_test_passed:
    print("PASS: app-01 is serving requests again.")
else:
    print("FAIL: app-01 is healthy but never answered a request.")

print()


# ---- Final result ----

print("=== Final Result ===")
if outage_test_passed and became_healthy and recovery_test_passed:
    print("RESULT: PASS")
    sys.exit(0)
else:
    print("RESULT: FAIL")
    sys.exit(1)
