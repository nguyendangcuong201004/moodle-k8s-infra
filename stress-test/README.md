# Stress test (k6)

**Requires:** `k6`, `jq`, `kubectl` (for seeding), and `moodle-k8s-infra/.env` with `MOODLE_WWWROOT` (same site you want to load-test).

## 1. Seed (before any `auth_quiz` run)

From a machine with cluster access (web pod must be running):

```bash
cd moodle-k8s-infra/stress-test
./seed-auth-quiz-data.sh
```

Common env overrides: `NAMESPACE`, `USER_PREFIX`, `USER_COUNT` (default **300** students), `TEACHER_COUNT` (default **60**), `USER_PASSWORD`, `COURSE_SHORTNAME`, `COURSE_FULLNAME`, `QUIZ_NAME`. The script prints **`COURSE_ID`**, **`QUIZ_CMID`**, and a sample `run-stress-test` line. Re-run seed after raising counts so new accounts exist in Moodle.

Set in **`stress-params.env`** (or export):

- `COURSE_PATH=/course/view.php?id=<COURSE_ID>`
- `QUIZ_PATH=/mod/quiz/view.php?id=<QUIZ_CMID>`

(IDs must match the seeded course/quiz.)

## 2. Run

```bash
# edit stress-params.env: paths, VUs, thresholds
./run-stress-test.sh
```

Logs: `results/run-*.log`. With `PROFILE=auth_quiz`, the scenario is: home → login → course → quiz → attempt → **POST** `processattempt` → summary → quiz (see `k6-moodle.js`).

## 3. Tweaks

| Variable | Role |
|----------|------|
| `STAIRCASE_PLAN_PRESET` | Stair stages (`duration:vus,...`) |
| `MAX_P95_MS`, `MAX_P99_MS`, `MAX_FAIL_RATE` | Abort thresholds (k6 `http_req_duration` + `http_req_failed`) |
| `THINK_*` | Pause between steps |

Other profiles: `PROFILE=mixed|home|login` (GET-heavy only).

Deploy stack first: [../README.md](../README.md) (DigitalOcean).
