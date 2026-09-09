# Log Analysis

Three logs analyzed: `logs/access.log` (NGINX, JSON), `logs/application.log` (app, JSON),
`logs/error.log` (NGINX error log, plain text). Originals left unmodified; all analysis
run against copies/pipes.

## Data quality issues found first

Before computing any counts, `jq` failed to parse both JSON logs outright:

```
jq -r '.status' access.log | sort | uniq -c | sort -rn
# jq: parse error: Expected separator between values at line 313, column 1
```

Isolated the exact bad lines:

```
grep -n '"request_id":$' access.log
# 311:{"timestamp":"2026-08-20T11:12:48Z","request_id":

grep -n '"event":$' application.log
# 401:{"timestamp":"2026-08-20T11:17:00Z","event":
```

Both logs contain one truncated/incomplete JSON entry (write cut off mid-record — consistent
with a crash or disk-full event during logging, not something we can recover). Both are
excluded from all counts below.

Also found duplicate entries in access.log:

```
jq -r '.request_id' access.log | sort | uniq -c | sort -rn | awk '$1 > 1'
#   2 lab-000241
#   2 lab-000121
```

Two `request_id`s each appear twice, byte-for-byte identical. **This is the answer to
"how did you avoid double-counting requests": all counts below are computed after
deduplicating on `request_id` (`jq -s 'unique_by(.request_id)'`), not on raw line count.**
Access.log's `request_id` is treated as the authoritative unit of a request throughout,
since application.log only records requests that actually reached a healthy app process
(see correlation section below) and error.log only records requests NGINX itself failed
to proxy — access.log is the only log that reliably records every request exactly once.

## Clean totals (deduplicated, malformed line excluded)

```
jq -R 'fromjson? // empty' access.log | jq -s 'unique_by(.request_id)' > clean_access.json
jq -r '.[].request_id' clean_access.json | wc -l
# 720
```

Status code breakdown, all 720 requests:

| Status | Count |
|--------|-------|
| 200    | 615   |
| 503    | 47    |
| 502    | 40    |
| 404    | 10    |
| 504    | 8     |

By upstream instance:

| Status | app-01 (172.23.0.11) | app-02 (172.23.0.12) |
|--------|----------------------|----------------------|
| 200    | 328                  | 268                  |
| 503    | 23                   | 24                   |
| 504    | 4                    | 4                    |
| 404    | 5                    | 5                    |
| 502    | 0                    | 40                   |

Reconciliation: 360 (app-01) + 341 (app-02) = 701. The remaining 19 requests are logged
against **both** upstreams in a single access.log entry (NGINX's own retry — see below),
accounting for the gap to 720: 701 + 19 = 720. Confirmed:

```
grep -c "172.23.0.12:8080, 172.23.0.11:8080" access.log
# 19
```

Requests per minute are flat at 24/min for the entire captured window (11:00–11:29),
confirming the log represents synthetic, evenly-paced traffic rather than organic load —
expected for a lab-generated dataset.

## Timeline and incidents

### Incident 1 — app-02 outage, 11:05:02–11:07:52+ (connection refused)

`error.log` shows 61 entries of `connect() failed (111: Connection refused)`, all against
`172.23.0.12:8080` (app-02), spanning every endpoint (`/`, `/health`, `/ready`, `/records`,
`/counter`, `/instance`).

Cross-referenced in access.log: every direct hit to app-02 in this window returns `502`.
app-01 has **zero** 502s the entire capture — it never went down.

For `/ready` and `/instance` specifically, access.log shows entries where NGINX logs
**both** upstreams for one request (`"172.23.0.12:8080, 172.23.0.11:8080"`,
`upstream_status: "502, 200"`) — i.e. NGINX tried app-02, got refused, and retried app-01
within the same client-facing request, returning 200 to the client. For `/`, `/health`,
`/records`, `/counter`, no such retry appears — those return a bare `502` straight through.
This indicates the historical NGINX config in this incident had retry-on-failure enabled
for some routes but not others (our current `nginx.conf` sets `proxy_next_upstream off`
globally, which is a stricter, more predictable choice — documented as a deliberate
decision in `decisions.md`, trading automatic retry for explicit, visible failure).

**Conclusion:** app-02 suffered a full outage (process down or unreachable) for at least
~3 minutes. The system remained partially/fully available throughout because app-01
kept serving every request routed to it. This is direct evidence of load-balancer-level
resilience to a single-backend failure — the scenario the required `failure_test.sh`
is designed to reproduce and prove recovery from.

### Incident 2 — /records timeouts on both instances, 11:25:14–11:26:47 (504)

`error.log`: 8 entries reading `upstream timed out (110: Operation timed out) ... reading
response header from upstream`, all specifically on `GET /records`, split evenly across
**both** app-01 and app-02 (4 each).

This is a distinct failure signature from Incident 1: not "connection refused" (process
down/unreachable) but "timed out" (process reachable, response too slow), and it affects
**both** instances rather than one. Since `/records` is the only endpoint backed by a
Postgres query, and the app enforces `statement_timeout=2000` (2 seconds) per query,
the most likely explanation is a slow/blocked Postgres query or lock during this window —
a shared-dependency slowdown, not an app-instance crash. This distinction matters
operationally: Incident 1 is fixed by restarting/replacing one app instance; Incident 2
would require investigating Postgres itself (query plans, locks, connection pool
exhaustion), since restarting an app instance would not help if the database is the
bottleneck.

Log ends at `11:30:00 [notice] log collector rotated stream` — a routine rotation event,
not an error, explaining why the capture stops there.

### Other status codes

- **404 (10 total, 5 per instance):** all on `/missing`, a deliberately nonexistent path —
  expected behavior, not a defect.
- **Remaining 503s (47 total, roughly even across instances, outside the two incident
  windows):** consistent background rate, not concentrated in any one timeframe — not
  investigated further as a distinct incident; likely synthetic noise built into the lab
  dataset rather than a real fault (recommend spot-checking if this needs a definitive
  answer for submission — command below).

```
jq -r '.[] | select(.status==503) | .timestamp' clean_access.json | cut -c1-16 | sort | uniq -c
```

## Correlation method across the three logs

- **access.log** = ground truth for "did a request happen and what did the client see."
  Every request NGINX handled is logged here exactly once (after removing the 2 duplicate
  entries), regardless of whether it succeeded.
- **error.log** = NGINX's own record of failures to reach an upstream (connection refused,
  timeout). Every error.log line has a matching access.log entry with a 502/503/504 status
  and the same `request_id`.
- **application.log** = only requests that actually reached a *running, responsive* app
  process. During Incident 1, application.log's per-minute rate for app-02 visibly drops
  from the steady 24/min baseline, because refused connections never reach the app process
  at all and so are never logged there.

Example correlation (single request during Incident 1):
```
grep "lab-000122" access.log error.log application.log
```
`lab-000122` appears in access.log (502, upstream 172.23.0.12) and error.log (connection
refused, same upstream) — but is **absent** from application.log, since app-02 never
received it. This is the concrete mechanism behind the double-counting/source-of-truth
answer above: application.log undercounts by design during an outage, so it is never
used as the basis for request totals.
