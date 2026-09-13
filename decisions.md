# Decisions

Five or more decisions made while fixing and hardening this environment, with the
assumptions behind each, alternatives considered, trade-offs accepted, and known
limitations.

## 1. Keep `proxy_next_upstream off` in NGINX

**Decision:** Leave NGINX's upstream retry behavior disabled, so a request routed
to a stopped/unreachable backend fails immediately (502/504) instead of NGINX
silently retrying the other backend.

**Assumption:** Requests hitting `/records` (POST) must never be silently retried,
since a retry after a slow-but-successful write could create a duplicate database
record.

**Alternative considered:** Enable `proxy_next_upstream error timeout` so a failed
request automatically retries on the healthy backend, giving a fully seamless
failover experience for the client.

**Trade-off:** With retries off, `failure_test.py` shows real 502/504 errors during
an outage (proven: 5 of 10 requests failed when app-01 was stopped). This is more
visible to monitoring/alerting than a silently-retried request would be, but it
means real failures are never masked.

**Limitation:** This is a real single point of failure at the individual-request
level — a client whose request happened to land on the down backend gets an error,
even though the overall service is still "up." A production fix would scope retry
to safe, idempotent methods only (GET), never POST.

## 2. Run the Flask app as a dedicated non-root user

**Decision:** Fixed the Dockerfile so the app actually runs as the `app` user
(uid 10001) it creates, instead of the `USER root` override that was in the
starter Dockerfile.

**Assumption:** The Flask app does not need root privileges for anything it does
(no binding to privileged ports, no writing outside its own working directory).

**Alternative considered:** Leave it as root, since it was already working and the
brief only says to avoid root "where practical."

**Trade-off:** None found — confirmed the app still builds, starts, and passes
`/ready` and all endpoint checks as a non-root user, so there was no functional
cost to fixing this.

**Limitation:** The base image itself (`python:3.12-slim-bookworm`) is not a
minimal/distroless image, so the container still has a general-purpose Linux
userland available if an attacker got code execution — non-root reduces but does
not eliminate that risk.

## 3. Resource limits: modest values sized for a lab environment, not a load test

**Decision:** Set `mem_limit`/`cpus` per service, roughly: app-01/app-02 256MB/0.5
CPU each, Postgres 512MB/1.0 CPU, Redis 128MB/0.5 CPU, NGINX 64MB/0.25 CPU.

**Assumption:** This environment only needs to survive the assessment's own tests
(validate.sh, failure_test.py, the video demo) — not production-scale traffic.

**Alternative considered:** No limits at all (the starter's original state), or
much higher limits "to be safe."

**Trade-off:** These values are a reasonable guess based on what each service
actually does (Flask dev server, small Postgres/Redis instances), not derived from
a real load test. They're intentionally generous enough not to cause OOM kills
during normal use, documented here as an assumption rather than a measured result.

**Limitation:** Without an actual load test, these numbers could be wrong in either
direction for a real workload. A production deployment would need real traffic
profiling before finalizing limits.

## 4. Redis persistence: enable AOF, not RDB snapshotting

**Decision:** Changed Redis's command from `--save "" --appendonly no` (persistence
fully disabled) to `--appendonly yes` (AOF enabled), backed by a named volume.

**Assumption:** The counter value (used by `/counter`) should survive a container
restart, matching the brief's "configure Redis persistence where appropriate."

**Alternative considered:** RDB snapshotting (`--save 60 1` style) instead of AOF.

**Trade-off:** AOF is slightly slower per-write than RDB snapshotting but loses
less data on a crash (RDB only snapshots periodically; AOF logs every write).
Given this is a low-write counter/cache workload, the write-performance cost of
AOF is negligible, so I chose durability over raw speed.

**Limitation:** AOF file growth over time isn't addressed here (no `appendfsync`
tuning or rewrite scheduling configured) — fine for this assessment's scale, not
tuned for a long-running production Redis instance.

## 5. Isolate PostgreSQL and Redis on an internal-only Docker network

**Decision:** Kept the `backend` network's existing `internal: true` setting, and
additionally removed the host port mappings (`15432`, `16379`) that the starter
had published for Postgres and Redis directly to the host.

**Assumption:** Nothing outside the Docker Compose project (including the host
machine itself) should be able to reach Postgres or Redis directly — only the
app containers and NGINX should reach them, and only over the internal network.

**Alternative considered:** Leave the host port mappings in place for convenience
(they were useful for direct `psql`/`redis-cli` debugging during Phase 1).

**Trade-off:** Removing them means I can no longer connect directly from the host
for ad-hoc debugging — I have to use `docker compose exec postgres psql ...`
instead. This is the correct trade-off for meeting the brief's explicit
requirement ("do not publish app, PostgreSQL or Redis ports"), and it was caught
specifically because writing `validate.sh` forced me to think through exactly
what "network isolation" needs to prove.

**Limitation:** `internal: true` blocks external connectivity at the Docker network
level, but does not by itself add authentication hardening inside the network —
any container successfully added to the `backend` network would still reach
Postgres/Redis with the app's own credentials. This is acceptable for a
single-tenant lab environment, not a multi-tenant production one.

## 6. Named containers over Compose's default naming

**Decision:** Kept explicit `container_name` for all five services rather than
letting Compose auto-generate them.

**Assumption:** The brief's requirement to name containers `app-01`, `app-02`,
`nginx`, `postgres`, `redis` implies these names should be predictable and stable
for scripting (`docker compose exec app-01 ...`, `docker compose stop app-01`),
not just cosmetic.

**Alternative considered:** Rely on Compose's default `<project>-<service>-<n>`
naming and reference services by their Compose service name instead.

**Trade-off:** Explicit `container_name` values mean this Compose file cannot be
scaled with `docker compose up --scale app-01=3`, since Compose requires
auto-generated names to run multiple replicas of the same service. This is an
accepted trade-off given the brief calls for exactly two named, distinct app
instances, not a scalable replica set.

**Limitation:** Adding a third instance live during the video (as the brief
requires) needs a new named service entry, not a `--scale` flag — planned for
directly in `docker-compose.yml` before recording.

## 7. Restart policy: `unless-stopped` on every service

**Decision:** Changed the shared app anchor from `restart: "no"` (the starter default)
to `restart: unless-stopped`, and added the same policy to Postgres, Redis, and NGINX,
which had no restart policy configured at all.

**Assumption:** An unexpected container crash (process error, OOM, host reboot) should
recover automatically; an intentional `docker compose stop` (as used by `failure_test.py`
and by hand during the video's live failure demo) should stay stopped until explicitly
started again.

**Alternative considered:** `restart: always` (restarts even after an intentional stop,
which would break `failure_test.py`'s ability to keep a backend down on purpose), or
leaving the default `"no"` (no automatic recovery at all).

**Trade-off:** `unless-stopped` gives real resilience against unexpected failures without
fighting deliberate test/demo actions. Verified this doesn't interfere with the failure
test: `docker compose stop app-01` correctly kept it down for the full test duration, and
`docker compose start app-01` correctly brought it back — `unless-stopped` does not
auto-restart a container that was stopped on purpose.

**Evidence:** Re-ran `failure_test.py` after this change — result unchanged (PASS),
confirming the restart policy doesn't interfere with intentional stop/start.

**Production improvement:** Combine with proper health-based orchestration (e.g.
Kubernetes liveness/readiness probes with pod restarts) rather than relying on Docker
Compose's restart policy alone, which has no visibility into application-level health
beyond the container process being alive.

**Limitation:** `unless-stopped` does not help if the underlying host itself goes down,
or if every instance of a service fails simultaneously — it only recovers individual
container crashes on a running host.
