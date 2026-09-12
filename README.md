<img src="assets/barq-logo.svg" alt="BARQ Systems" width="180">

# BARQ Systems — DevOps Internship Assessment

Fixed, tested, and documented deployment of a Flask API behind NGINX, backed by
PostgreSQL and Redis. Full investigation is in `troubleshooting.md` and
`log_analysis.md`; design rationale is in `decisions.md`; risk review is in
`security_review.md`; AI tool usage is disclosed in `AI_USAGE.md`.

**Current state:** two app instances (`app-01`, `app-02`) on host port `8080`. A third
instance and a live port change to `8090` are added during the recorded demo, per the
assessment brief — see `docs/EVIDENCE_INDEX.md` for the final committed state.

## Prerequisites

- Linux or WSL2, Git, Docker with Compose
- Recommended: 2 CPU cores, 4 GB free RAM, 3 GB free disk

## Setup

```bash
git clone https://github.com/AbdallahKhaledAmmar/BARQ-Academy.git
cd BARQ-Academy
cp config/app.env.example config/app.env   # then set the real Postgres password to match
                                            # docker-compose.yml's POSTGRES_PASSWORD
cp .env.example .env                       # optional: override PUBLIC_PORT
```

## Build and start

```bash
docker compose up -d --build
docker compose ps
```

Wait for all five services (`app-01`, `app-02`, `nginx`, `postgres`, `redis`) to show
`(healthy)`. Then confirm:

```bash
curl http://localhost:8080/ready
```

## Test the endpoints

```bash
curl -i http://localhost:8080/
curl -i http://localhost:8080/health
curl -i http://localhost:8080/ready
curl -i http://localhost:8080/instance
curl -X POST http://localhost:8080/records -H "Content-Type: application/json" -d '{"title":"example"}'
curl -i http://localhost:8080/records
curl -i http://localhost:8080/counter
```

Confirm both backends serve traffic through NGINX:

```bash
for i in $(seq 1 20); do curl -s http://localhost:8080/instance | grep -o '"instance_id":"[^"]*"'; done | sort | uniq -c
```

## Automated validation

```bash
chmod +x validate.sh
./validate.sh
echo "Exit code: $?"
```

Runs 13 checks (public access, all endpoints, both backend identities, PostgreSQL/Redis
readiness, and confirms PostgreSQL/Redis ports are NOT reachable from the host). Exits
non-zero on any failure.

## Failure test

```bash
python3 failure_test.py
echo "Exit code: $?"
```

Stops `app-01`, samples traffic during the outage (proves `app-02` keeps the service
available), restarts `app-01`, waits for it to become healthy again, and confirms it
serves requests once more.

## Backup and restore

```bash
./backup.sh          # creates backups/barq_tasks_<timestamp>.dump
./restore.sh          # creates a record, backs it up, recreates containers, proves
                       # the record survives, and restores the dump into a scratch
                       # database to prove the backup file itself is valid
```

## Persistence proof (manual)

```bash
curl -X POST http://localhost:8080/records -H "Content-Type: application/json" -d '{"title":"persistence test"}'
docker compose down        # no -v — this keeps the named volumes
docker compose up -d
curl http://localhost:8080/records   # the record is still there
```

## CI

`.github/workflows/ci.yml` runs on every push and pull request: checkout, syntax check,
build, start, wait for readiness, run `validate.sh`. See the Actions tab for the latest run.

## App-only unit tests (no Docker required)

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
python -m unittest discover -s tests -v
deactivate
```

## Cleanup

```bash
docker compose down          # stops containers, keeps named volumes
docker compose down -v       # also removes named volumes (only when lab data is no longer needed)
```

Avoid `docker system prune` — it affects unrelated Docker resources on your machine.

## Answers to the required questions

**What failed first? What proved the cause? Which failed attempt taught you something?**
The healthcheck path mismatch (`/healthz` vs `/health`) failed first — containers stuck
`unhealthy` forever. Proved by comparing the Compose healthcheck command against the
actual Flask routes. The most instructive failed attempt: after fixing the NGINX
listen-port mismatch, a `docker compose up -d` didn't apply the change, because
`nginx.conf` is a read-only bind mount only read at container start — a plain restart
was needed. Full detail in `troubleshooting.md`.

**What patterns did the logs reveal? How did you avoid double-counting requests?**
Two incidents: a full app-02 outage (`connect() failed`, ~3 minutes, app-01 kept the
service available), and a narrower `/records`-only timeout affecting both instances
(pointing at a slow Postgres query rather than an instance crash). Two duplicate log
lines and one truncated line were found and excluded before computing any counts —
all counts are deduplicated by `request_id`, treating `access.log` as the source of
truth for "did a request happen." Full detail in `log_analysis.md`.

**How do requests flow? Why these ports, networks and readiness checks?**
Client → NGINX (`:8080` host-published) → `app-01`/`app-02` (`frontend` network) →
PostgreSQL/Redis (`backend` network, `internal: true`, no host ports). `/health` proves
the Flask process is alive; `/ready` proves PostgreSQL and Redis are actually reachable
— the two are intentionally different so a process-alive-but-dependency-down state is
visible. See `architecture.png` and `decisions.md`.

**Why these timeouts, retries, restart settings and resource limits?**
Short connect/read timeouts on both the Postgres connection and NGINX's proxy prevent
a slow dependency from holding a request indefinitely. `proxy_next_upstream off` is a
deliberate choice, not a default — see `decisions.md` entry 1. Resource limits are
sized for this lab's scale, not load-tested — see `decisions.md` entry 3.

**When should validation fail? What does green CI prove, or not prove?**
`validate.sh` fails whenever any endpoint returns the wrong status, either backend goes
unseen across 20 sampled requests, a dependency isn't ready, or a supposedly-blocked
host port (`15432`, `16379`) is actually reachable. A green CI run proves the checked
behaviors held at that moment in GitHub's environment — it does not prove production
load handling, long-term reliability, or security beyond what's explicitly checked.

**Which single points of failure remain? How would you fix them in production?**
Single NGINX instance, single Postgres instance (manual/unscheduled backups), single
Redis instance, and `proxy_next_upstream off` meaning a request routed to a down
backend fails outright rather than retrying. All documented with production fixes in
`security_review.md` and `decisions.md`.

**What would you improve? How did you verify AI-assisted work?**
See `AI_USAGE.md` for full disclosure and verification method. Production improvements
are listed throughout `security_review.md` (secrets management, TLS, centralized
logging/monitoring, database replication, scheduled backups).
