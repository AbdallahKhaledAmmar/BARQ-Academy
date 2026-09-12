# AI Usage Disclosure

## Tool
Claude (Anthropic), accessed via claude.ai, used alongside manual investigation
and local testing throughout the assessment.

## Purpose
- Troubleshooting Docker Compose networking, NGINX reverse proxy configuration,
  health/readiness checks, persistence, and resource limits.
- Drafting the required automation scripts and CI workflow.
- Reviewing implementation choices against the assessment requirements.

## Files or decisions affected
`docker-compose.yml`, `nginx/nginx.conf`, `Dockerfile`, `config/app.env`,
`validate.sh`, `failure_test.py`, `backup.sh`, `restore.sh`,
`.github/workflows/ci.yml`, and the write-up of `troubleshooting.md` /
`log_analysis.md` based on my own investigation.

## What was changed, rejected, or caught
- The three hardest issues to isolate: a 502 that persisted across two separate
  NGINX config fixes, eventually traced to the app being bound to loopback only
  (`APP_HOST=127.0.0.1`) instead of all interfaces; a Postgres "unavailable"
  status caused by a single-character password mismatch between
  `docker-compose.yml` and `config/app.env`, only found by testing the exact
  connection string directly from inside the container; and two real CI
  failures on GitHub Actions itself (a step-ordering bug, then a placeholder
  credential that didn't match the real Postgres password), both diagnosed
  from the actual Actions logs, not assumed.
- Rejected a suggested NGINX auto-retry (`proxy_next_upstream`) change and kept
  it disabled instead, since automatic retries risk duplicating a
  non-idempotent `POST /records` request — documented as a deliberate trade-off
  in `decisions.md`, not an oversight.
- An early resource-limit approach (`deploy.resources.limits`, which only
  applies under Swarm) would have been silently ignored by plain
  `docker compose` — caught by validating with `docker compose config` and
  switched to `mem_limit`/`cpus`, which Compose actually enforces.

## Independent verification
- `docker compose config` to validate Compose syntax after every structural edit
- `docker compose ps` / `docker compose logs` after every fix, to confirm real
  container health rather than assumed health
- `curl` against every required endpoint (`/`, `/health`, `/ready`, `/instance`,
  `/records`, `/counter`) after each change
- Direct `psql` and Python `psycopg` connection tests to isolate the password
  issue from a networking issue
- Real backup/restore: created a live record, ran `backup.sh`, recreated
  containers, confirmed the record survived, and restored the dump into a
  separate database to confirm it actually contains data
- Real failure test: stopped `app-01`, sampled live traffic during the outage,
  restarted it, and confirmed recovery via `failure_test.py`'s printed output
- Actual GitHub Actions run logs, read directly, to diagnose both CI failures

## Related commits
`60a071d`, `ab186ea`, `924dc8a`, `0286000`, `7f73f8f`, `9e68759`, `c182ef8`,
`5d54596`, plus the commits adding `validate.sh`, `failure_test.py`,
`backup.sh`/`restore.sh`, and `.github/workflows/ci.yml` (see full commit
history for exact hashes and messages).
