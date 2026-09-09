# Troubleshooting Journal

Investigation carried out via `docker compose up --build`, container logs, and direct
`psql`/`python` connection tests. Each issue below is documented in the order discovered.

## Issue 1: app-01 / app-02 stuck "unhealthy"

**Symptom:** `docker compose ps` showed both app containers `Up (unhealthy)` indefinitely.

**Hypothesis:** Healthcheck command targets a route that doesn't exist.

**Commands:**
```
grep -n -A5 "healthcheck" docker-compose.yml
grep -rn "healthz\|/health\|/ready" app/
```

**Result:** `docker-compose.yml` healthcheck called `http://127.0.0.1:8080/healthz`;
`app/server.py` only defines `/health` and `/ready` — no `/healthz` route exists.
Every healthcheck attempt returned 404, so Docker never marked the container healthy.

**Root cause:** Path mismatch between the healthcheck probe and the actual app route.

**Fix:**
```
sed -i "s#http://127.0.0.1:8080/healthz#http://127.0.0.1:8080/health#" docker-compose.yml
```

**Retest evidence:** `docker compose ps` showed both containers `(healthy)` after rebuild.

---

## Issue 2: NGINX connection reset on host port 8080

**Symptom:** `curl http://localhost:8080/` returned `Recv failure: Connection reset by peer`.

**Hypothesis:** Port mapping mismatch between Compose and nginx.conf.

**Commands:**
```
grep -n -A5 "nginx:" docker-compose.yml
grep -n "listen" nginx/nginx.conf
```

**Result:** Compose mapped host port to container port 81 (`127.0.0.1:8080:81`), but
`nginx.conf` had `listen 80;`. Nothing listened on port 81 inside the container.

**Root cause:** Config mismatch between Compose port mapping and NGINX's listen directive.

**Fix:**
```
sed -i "s/listen 80;/listen 81;/" nginx/nginx.conf
docker compose restart nginx
```

**Failed attempt:** Initial `docker compose up -d` after the sed edit did not pick up the
change, since `nginx.conf` is a read-only bind mount and NGINX only reads it at container
start — a plain restart was required to force a reload.

**Retest evidence:** `curl -v http://localhost:8080/` returned `502 Bad Gateway` (progress —
connection no longer reset, next issue surfaced).

---

## Issue 3: NGINX upstream 502 — wrong app-01 port

**Symptom:** `502 Bad Gateway` from NGINX after fixing Issue 2.

**Hypothesis:** NGINX upstream block points at the wrong port for one of the app instances.

**Commands:**
```
grep -n -B2 -A15 "upstream" nginx/nginx.conf
docker compose logs nginx --tail=30
```

**Result:** `nginx.conf` upstream block listed `server app-01:8081` but `app-02:8080`.
Both app containers actually expose port 8080 internally (confirmed via `docker compose ps`).
NGINX error log confirmed: `connect() failed (111: Connection refused) ... upstream:
"http://172.19.0.2:8081/"`.

**Root cause:** Typo/inconsistency in the upstream port for app-01.

**Fix:**
```
sed -i "s/server app-01:8081/server app-01:8080/" nginx/nginx.conf
docker compose restart nginx
```

**Retest evidence:** Still 502 after this fix — pointed to a further issue (Issue 4).

---

## Issue 4: 502 persists — app not reachable from other containers (APP_HOST)

**Symptom:** After fixing Issue 3, NGINX still returned 502; error log showed
`connect() failed (111: Connection refused)` even though the app container itself
was marked `(healthy)`.

**Hypothesis:** Healthcheck (same-container, loopback) succeeds but the app is not
actually reachable from *other* containers — suggests the app is bound to loopback only.

**Commands:**
```
grep -n "run(\|host=\|HOST" app/server.py
grep -n "HOST\|BIND" docker-compose.yml
```

**Result:** `app/server.py` defaults to `host=os.getenv("APP_HOST", "0.0.0.0")` (correct
default), but `docker-compose.yml` explicitly set `APP_HOST: "127.0.0.1"`, overriding the
safe default and binding the app to loopback only — invisible to NGINX on the Docker network.

**Root cause:** Environment variable override forcing the app to bind to loopback instead
of all interfaces.

**Fix:**
```
sed -i 's/APP_HOST: "127.0.0.1"/APP_HOST: "0.0.0.0"/' docker-compose.yml
docker compose up -d --build
```

**Retest evidence:** `curl -v http://localhost:8080/` returned `200 OK` with valid JSON
body and `X-Instance-ID: app-01` header.

---

## Issue 5: Postgres / Redis "unavailable" on /ready, /records, /counter

**Symptom:** `/ready` reported `{"postgres":"unavailable","redis":"unavailable"}`;
`/records` and `/counter` returned 503.

**Hypothesis:** App's DB/cache connection strings point at wrong ports.

**Commands:**
```
grep -n "PORT\|5432\|5433\|6379\|6380" docker-compose.yml
cat config/app.env
```

**Result:** `config/app.env` had `DATABASE_URL=...@postgres:5433/...` and
`REDIS_URL=redis://redis:6380/0`, but the actual containers expose the standard
`5432` (Postgres) and `6379` (Redis) internally — confirmed via `docker compose ps`.

**Root cause:** Wrong internal port numbers in the app's connection strings.

**Fix:**
```
sed -i 's/postgres:5433/postgres:5432/' config/app.env
sed -i 's/redis:6380/redis:6379/' config/app.env
docker compose up -d --build
```

**Retest evidence:** `/ready` showed `redis:"ready"`; postgres still failed (Issue 6).

---

## Issue 6: Postgres still unavailable after port fix — password mismatch

**Symptom:** `/ready` still reported `postgres:"unavailable"` after the port fix; direct
`psql -U barq_app -d barq_tasks` (trust-auth, local) succeeded, ruling out a broken database.

**Hypothesis:** Password mismatch between the Postgres container's init env and the app's
connection string, since local trust-auth bypasses password checks entirely.

**Commands:**
```
docker compose exec app-01 python3 -c "import psycopg; psycopg.connect('postgresql://barq_app:BarqLabOnly_7qN2vK8d@postgres:5432/barq_tasks', connect_timeout=2)"
```

**Result:** Raised `psycopg.OperationalError: ... FATAL: password authentication failed for
user "barq_app"`. Comparing `docker-compose.yml`'s `POSTGRES_PASSWORD: BarqLabOnly_7qN2vK8c`
against `config/app.env`'s `...vK8d` revealed a single-character mismatch (`c` vs `d`).

**Root cause:** Password typo in `config/app.env`, one character off from the actual
Postgres container password.

**Fix:**
```
sed -i 's/BarqLabOnly_7qN2vK8d/BarqLabOnly_7qN2vK8c/' config/app.env
docker compose up -d --build
```

**Retest evidence:** `/ready` returned `{"postgres":"ready","redis":"ready"}`. Created a
record via `POST /records` and confirmed it appeared in `GET /records` alongside two
pre-seeded rows.

---

## Known issue — not yet fixed (flagged for Phase 3)

**Postgres volume misconfiguration:** `docker-compose.yml` mounts the named volume
`postgres-data` to `/var/lib/postgresql/backup`, while Postgres actually stores live data
in `/var/lib/postgresql/data`, which is currently declared as `tmpfs` (RAM-backed, wiped on
container removal). This means records created now will **not** survive container
recreation. Must be fixed before the Part 3 persistence test (mount the named volume to
`/var/lib/postgresql/data` and remove the `tmpfs` declaration).

## Log analysis findings (see log_analysis.md for full detail)

- Two duplicate access-log entries found (`lab-000121`, `lab-000241`) — deduplicated by
  `request_id` before computing any counts.
- One truncated/malformed JSON line found in access.log (line 311) — excluded from counts.
- One truncated/malformed JSON line found in application.log (line 401) — excluded from counts.
- Historical incident identified: app-02 (172.23.0.12) returned 502 on nearly every request
  from approximately 11:05:02 through at least 11:07:52, while app-01 (172.23.0.11) maintained
  100% availability throughout — evidence that NGINX load balancing kept the service available
  during a single-backend outage.
