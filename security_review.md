# Security Review

Concrete risks and improvements found while working on this environment.
Each item is marked either **[Fixed]** (already implemented in this repo) or
**[Production plan]** (a real risk that remains, with what I'd do about it in
a real deployment — not implemented here due to assessment scope/time).

## 1. [Fixed] Real database credential committed to git
`config/app.env` (containing the real synthetic-lab Postgres password) was
tracked in git from the starter repo. Removed it from tracking with
`git rm --cached`, added it to `.gitignore`, and added `config/app.env.example`
with a placeholder value instead.
**Residual risk:** the credential still exists in the git history of earlier
commits (before removal). For a real secret, this would require rewriting
history or rotating the credential — not done here since it's synthetic lab
data, but noted as the correct next step for a real leak.

## 2. [Fixed] PostgreSQL and Redis ports published to the host
The starter published `15432` and `16379` to `127.0.0.1`, meaning anything on
the host machine (not just Docker containers) could connect directly. Removed
both port mappings; both services are now reachable only via the internal
`backend` Docker network.

## 3. [Fixed] Application container ran as root
The Dockerfile created a dedicated `app` user but then explicitly ran `USER root`
before the app started. Fixed to `USER app`. Verified the app still functions
identically with no root privileges.

## 4. [Fixed] No resource limits on any container
A single runaway container (e.g. a memory leak in the Flask dev server, or an
unbounded Postgres query) could previously consume all host resources and
starve every other service. Added `mem_limit`/`cpus` to every service.

## 5. [Production plan] No secrets manager / static plaintext env file
Even with `config/app.env` correctly gitignored now, the credential still sits
in plaintext on disk, and would be baked into the built image via
`COPY config/app.env /srv/app.env` in the Dockerfile. In production, this should
come from a secrets manager (e.g. Docker Secrets, Vault, AWS Secrets Manager) and
be injected at runtime, never baked into the image layer at all — the current
`COPY` approach means the secret is retrievable from the image itself with
`docker history`/`docker save`, even without container access.

## 6. [Production plan] No TLS anywhere
NGINX currently serves plain HTTP on port 8080. There is no TLS termination, so
all traffic between a client and the edge (and internally between NGINX and the
app instances) is unencrypted. In production, NGINX should terminate TLS
(e.g. via a certificate from Let's Encrypt or an internal CA) and internal
traffic should ideally use mTLS or at minimum a private network with no
expectation of being internet-exposed.

## 7. [Production plan] No centralized logging or metrics/monitoring
Each container currently logs to its own stdout, viewable only via
`docker compose logs`. There is no aggregation (e.g. Loki, ELK), no metrics
collection (e.g. Prometheus), and no alerting. In an outage like the one
`failure_test.py` simulates, nobody would be notified — someone would have to
be actively watching. This is a real gap for the "monitoring" item the brief
asks to be covered.

## 8. [Production plan] `proxy_next_upstream off` means no automatic failover
per-request
Documented in detail in `decisions.md` (#1). A request that happens to land on
a down backend fails outright rather than transparently retrying. This is a
deliberate trade-off given the non-idempotent `POST /records` endpoint, but it
remains a real single point of failure at the individual-request level.
Production fix: scope automatic retry to idempotent (GET) requests only.

## 9. [Production plan] Backup is manual and unscheduled
`backup.sh` exists and is proven to work (see `restore.sh`'s verification step),
but nothing runs it automatically. There is no retention policy, no off-host
backup storage, and no automated restore drill. In production this should be a
scheduled job (e.g. cron, or a Kubernetes CronJob) writing to off-host/off-region
storage, with periodic automated restore tests — not just a script that exists.

## 10. [Production plan] Single Postgres instance, no replication
There is exactly one Postgres container with one named volume. If the underlying
disk/volume is lost or corrupted, the most recent backup is the only recovery
path (with backups being manual, per #9, this compounds the risk). Production
should have at least a primary/replica setup, or use a managed database service
with automated failover.

## 11. [Production plan] Base images are not the smallest/most hardened option
`python:3.12-slim-bookworm` and standard `nginx:1.28-alpine` are used. These are
reasonable, well-maintained images, but a further-hardened deployment could use
distroless or minimal images to reduce the attack surface (fewer installed
packages means fewer potential CVEs to track), at the cost of harder debugging
(no shell inside the container for `docker compose exec`).

## 12. [Fixed] app-02 misreported its own identity
Not a traditional "security" risk, but a correctness/integrity issue worth
noting here: `app-02` was configured with `INSTANCE_ID: "app-01"`, meaning the
`/instance` endpoint could not be trusted to actually distinguish which backend
served a request — a monitoring/observability integrity issue if left in place
(logs and metrics attributed to the wrong instance). Fixed by correcting the
environment variable.

## 13. [Fixed] Secret baked into image layer via unnecessary Dockerfile COPY

**Risk and evidence:** The Dockerfile included `COPY config/app.env /srv/app.env`,
copying the file containing the real (synthetic-lab) Postgres credential into the
built image. Confirmed via `grep -rn "app.env" app/` that no application code actually
reads `/srv/app.env` — the app only uses `os.getenv()`, which Compose already populates
at runtime via `env_file: ./config/app.env`. The `COPY` served no functional purpose and
only meant the credential was retrievable from the image itself (e.g. via `docker
history` or `docker save`), independent of container access or `.gitignore`.

**Implemented fix:** Removed the `COPY config/app.env /srv/app.env` line from the
Dockerfile. Re-ran the full verification suite (`validate.sh`, `failure_test.py`)
after the change — both passed with no regression, confirming the app never needed
the file baked into the image.

**Production follow-up:** For a real secret, this would also warrant checking whether
older, already-pushed image layers (if ever published to a registry) still contain
the credential in their history — a removed `COPY` in a new build does not retroactively
clean prior image layers already distributed.

## 14. [Fixed/documented] NGINX `max_fails=0` disables passive failure detection

**Risk and evidence:** The NGINX upstream pool is configured with `max_fails=0` on
both application servers, which explicitly disables NGINX's own passive health
tracking for that server — meaning NGINX never marks a backend as "failed" and
temporarily stops routing to it, regardless of how many consecutive errors it returns.

**Impact:** Combined with `proxy_next_upstream off` (see `decisions.md` #1), this means
a downed backend continues to receive its full share of round-robin traffic
indefinitely, with every one of those requests failing, until the container's own
Docker healthcheck-driven restart (or a human) intervenes — NGINX itself never adapts.

**Implemented fix:** None applied — documented here as an accepted, understood
trade-off alongside the `proxy_next_upstream off` decision, not a bug. Together
these two settings prioritize deterministic, visible failure over hidden automatic
rerouting, consistent with the reasoning in `decisions.md` #1.

**Production follow-up:** Set a real `max_fails` (e.g. 3) with a `fail_timeout`
window, in combination with a considered `proxy_next_upstream` policy scoped to
idempotent methods only, so NGINX both stops routing to a confirmed-bad backend
and safely retries GET requests without risking duplicate writes on POST.

**How to verify:** `grep -n "max_fails" nginx/nginx.conf`
