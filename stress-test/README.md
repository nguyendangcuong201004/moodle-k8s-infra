# Stress test (k6)

**Requires:** `k6`, `jq`, `kubectl` (for seeding), and `moodle-k8s-infra/.env` with `MOODLE_WWWROOT` (same site you want to load-test).

## 1. Seed (before any `auth_quiz` run)

From a machine with cluster access (web pod must be running):

```bash
cd moodle-k8s-infra/stress-test
./seed-auth-quiz-data.sh
```

Common env overrides: `NAMESPACE`, `USER_PREFIX`, `USER_COUNT` (default **500** students), `TEACHER_COUNT` (default **100**), `USER_PASSWORD`, `COURSE_SHORTNAME`, `COURSE_FULLNAME`, `QUIZ_NAME`. The script prints **`COURSE_ID`**, **`QUIZ_CMID`**, and a sample `0_stress_testing` line. Re-run seed after raising counts so new accounts exist in Moodle.

Set in **`stress-params.env`** (or export):

- `COURSE_PATH=/course/view.php?id=<COURSE_ID>`
- `QUIZ_PATH=/mod/quiz/view.php?id=<QUIZ_CMID>`

(IDs must match the seeded course/quiz.)

## 2. Run

```bash
# stress test: staircase to find the breaking point
./0_stress_testing.sh

# load test: stable load around the expected operating threshold
./1_loadtesting.sh

# burst test: sudden spike, then recovery window
./2_burst_testing.sh
```

Both wrappers use `_run_k6_common.sh` for env loading, k6 execution, summary parsing, and artifact paths. Terminal output is intentionally short; full k6 output is saved in `results/run-*.log`.

With `PROFILE=auth_quiz`, the scenario is: home → login → course → quiz → attempt → **POST** `processattempt` → summary → quiz (see `k6-moodle.js`).

## 3. Tweaks

| Variable | Role |
|----------|------|
| `STAIRCASE_PLAN_PRESET` | Stair stages (`duration:vus,...`) |
| `BASELINE_VUS`, `BURST_VUS` | Burst wrapper baseline and spike size |
| `WARMUP_DURATION`, `BURST_RAMP_DURATION`, `BURST_HOLD_DURATION`, `RECOVERY_DURATION` | Burst shape and recovery window |
| `MAX_P95_MS`, `MAX_P99_MS`, `MAX_FAIL_RATE` | Abort thresholds (k6 `http_req_duration` + `http_req_failed`) |
| `THINK_*` | Pause between steps |

Other profiles: `PROFILE=mixed|home|login` (GET-heavy only).

Example burst override:

```bash
BURST_VUS=800 BURST_RAMP_DURATION=3s BURST_HOLD_DURATION=90s ./2_burst_testing.sh
```

Deploy stack first: [../README.md](../README.md) (DigitalOcean).
