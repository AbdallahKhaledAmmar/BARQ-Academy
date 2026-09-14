# Evidence and submission index

- Repository URL: https://github.com/AbdallahKhaledAmmar/BARQ-Academy
- Final commit: `dcd7aeb` — "add app-03, change public port to 8090 (video demo)"
- Matching CI run: https://github.com/AbdallahKhaledAmmar/BARQ-Academy/actions/runs/34860983108 (green, run #17)
- Continuous 12-18 minute video URL: https://drive.google.com/file/d/1YT_0QE2-qlX3o-SHfb7wynhQTclXQAPQ/view?usp=sharing
- Challenge receipt ID: `3d8f51187ca04ab99ca211c3d4f639b8` (applied 2026-09-14T15:06:24.919735+00:00, see `.assessment/challenge.json`)
- Starting video commit: `06698d1` — "docs: add final architecture diagram (3 instances, port 8090)"
  (last commit before the live in-video changes; the video begins by showing `git log`
  at this commit, then proceeds through the live challenge, port change, and adding
  app-03, ending at the final commit `dcd7aeb`)
- Later documentation-only commits, if any: none — all documentation was committed
  before recording; the only commit made during/after the video is the final
  `dcd7aeb`, which includes both the live infrastructure changes (app-03,
  port 8090) and is itself a code/config change, not documentation-only.

## Requirement → evidence mapping

| Requirement | File / output | Commit | Video timestamp |
|---|---|---|---|
| Baseline preserved before changes | `git log` (starter tags intact: `starter-v2.0.0`) | `8442da3` | — (pre-video) |
| Healthcheck path bug fixed (`/healthz` → `/health`) | `troubleshooting.md` Issue 1 | see `git log --oneline` history | — (pre-video) |
| NGINX port/upstream bugs fixed | `troubleshooting.md` Issues 2–3 | see history | — (pre-video) |
| APP_HOST loopback bug fixed | `troubleshooting.md` Issue 4 | `60a071d` | — (pre-video) |
| Postgres/Redis port + password bugs fixed | `troubleshooting.md` Issues 5–6 | `ab186ea` | — (pre-video) |
| Log analysis, all template questions answered | `log_analysis.md` | see history | shown in video, live-log-finding segment |
| Postgres volume/persistence fixed | `decisions.md` | `924dc8a` | — (pre-video) |
| Redis persistence enabled | `decisions.md` #4 | `0286000` | — (pre-video) |
| app-02 identity bug fixed | `troubleshooting.md` | `7f73f8f` | — (pre-video) |
| Resource limits added | `decisions.md` #3 | `9e68759` | — (pre-video) |
| Non-root user fixed | `decisions.md` #2 | `c182ef8` | — (pre-video) |
| Secret removed from git tracking | `security_review.md` #1 | `5d54596` | — (pre-video) |
| Postgres/Redis host ports removed | `security_review.md` #2 | see history | — (pre-video) |
| NGINX healthcheck added (found via rehearsal) | `troubleshooting.md` Issue 7 | `3543884` | — (pre-video) |
| NGINX network isolation fixed (found via rehearsal) | `troubleshooting.md` Issue 8 | `e0431c4` | — (pre-video) |
| Restart policy added to all services | `decisions.md` #7 | `361569a` | — (pre-video) |
| Secret baked into image layer removed | `security_review.md` #13 | `894d584` | — (pre-video) |
| `max_fails=0` documented trade-off | `security_review.md` #14 | `7c8de08` | — (pre-video) |
| Architecture diagram (final 3-instance/8090 state) | `architecture.png` | `06698d1` | — (pre-video) |
| `validate.sh` implemented, 13 checks | `validate.sh` output | see history | 7:46 |
| `failure_test.py` implemented, recovery proven | `failure_test.py` output | see history | 8:23 |
| `backup.sh` / `restore.sh`, persistence + restore proven | script output | see history | — (demonstrated via manual persistence proof in video) |
| CI workflow green | `.github/workflows/ci.yml`, Actions run #17 | `dcd7aeb` | — (checked after recording) |
| Repository, starting commit, clean git status shown | video opening | `06698d1` (state at start) | video start |
| Build/start stopped environment, service health shown | video | — | 00:51 |
| Endpoints tested: `/`, `/health`, `/ready`, `/records`, `/counter` | video | — | 1:30 |
| Both backends proven via `/instance` | video | — | 3:55 |
| Backend stopped, continued traffic + errors shown, recovered | video | — | 4:19 |
| Record survives app + Postgres container recreation | video | — | 6:19 |
| `video_challenge.sh` run once, first time, diagnosed and fixed live | video, `.assessment/challenge.json` | `dcd7aeb` | 10:10 |
| Public port changed 8080 → 8090 live | video, `docker-compose.yml` | `dcd7aeb` | 13:10 |
| Third app instance added live (both `docker-compose.yml` and `nginx/nginx.conf`) | video, `docker-compose.yml`, `nginx/nginx.conf` | `dcd7aeb` | 14:20 |
| Final validation rerun (3 instances, port 8090) | video, `validate.sh` output | `dcd7aeb` | 17:15 |
| `git status`/`git diff` shown, commit on screen, hashes shown | video | `dcd7aeb` | 17:21 |
| Video commits pushed | `git push` output, GitHub | `dcd7aeb` | 17:55 |
