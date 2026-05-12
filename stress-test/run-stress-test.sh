#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
K6_SCRIPT="${SCRIPT_DIR}/k6-moodle.js"
OUT_DIR="${SCRIPT_DIR}/results"
mkdir -p "${OUT_DIR}"

if ! command -v k6 >/dev/null 2>&1; then
  echo "k6 is required. Install from https://k6.io/docs/get-started/installation/"
  # Do not exit with non-zero to keep terminal open
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required"
  # Do not exit with non-zero to keep terminal open
fi

PARAM_FILE="${SCRIPT_DIR}/stress-params.env"
if [[ -f "${PARAM_FILE}" ]]; then
  # Load defaults from file but keep explicitly provided env vars untouched.
  while IFS='=' read -r key value; do
    [[ -z "${key}" ]] && continue
    [[ "${key}" =~ ^[[:space:]]*# ]] && continue
    if [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      if [[ -z "${!key+x}" ]]; then
        export "${key}=${value}"
      fi
    fi
  done < "${PARAM_FILE}"
fi

ENV_FILE="${ROOT_DIR}/.env"
if [[ -f "${ENV_FILE}" ]]; then
  set -a
  source "${ENV_FILE}"
  set +a
fi

BASE_URL="${MOODLE_WWWROOT:-}"
if [[ -z "${BASE_URL}" ]]; then
  echo "MOODLE_WWWROOT is required in .env at repo root."
  # Do not exit with non-zero to keep terminal open
fi

BASE_HOST=""
if [[ -n "${BASE_URL}" ]]; then
  BASE_HOST="$(printf '%s' "${BASE_URL}" | sed -E 's#^[A-Za-z]+://([^/:]+).*#\1#')"
fi

START_VUS="${START_VUS:-50}"
STEP_VUS="${STEP_VUS:-50}"
MAX_VUS="${MAX_VUS:-400}"
STEP_HOLD="${STEP_HOLD:-45s}"
STEP_RAMP="${STEP_RAMP:-10s}"
MAX_P95_MS="${MAX_P95_MS:-10000}"
MAX_P99_MS="${MAX_P99_MS:-5000}"
MAX_FAIL_RATE="${MAX_FAIL_RATE:-0.05}"
ABORT_DELAY="${ABORT_DELAY:-0s}"
MAX_REDIRECTS="${MAX_REDIRECTS:-10}"
HTTP_TIMEOUT="${HTTP_TIMEOUT:-12s}"
HOST_MAP="${HOST_MAP:-}"
HOLD_AFTER_RUN="${HOLD_AFTER_RUN:-true}"
EXIT_WITH_K6_CODE="${EXIT_WITH_K6_CODE:-false}"
# LIVE_K6_OUTPUT=true — tee k6 to terminal; default logs only to results/
LIVE_K6_OUTPUT="${LIVE_K6_OUTPUT:-false}"
# Default: web-dashboard + browser; SHOW_WEB_DASHBOARD=false to disable
SHOW_WEB_DASHBOARD="${SHOW_WEB_DASHBOARD:-true}"
# Full UI needs ?endpoint=/ for SSE metrics.
K6_DASHBOARD_UI_URL="${K6_DASHBOARD_UI_URL:-http://127.0.0.1:5665/ui?endpoint=/}"
# If true, free 5665/6565 before run (stale k6 → empty dashboard / address in use)
K6_FREE_DASHBOARD_PORT="${K6_FREE_DASHBOARD_PORT:-true}"
# K6_WEB_DASHBOARD_PERIOD must be a duration (e.g. 10s); plain "10" breaks metrics on the UI
if [[ -n "${K6_WEB_DASHBOARD_PERIOD:-}" ]] && [[ "${K6_WEB_DASHBOARD_PERIOD}" =~ ^[0-9]+$ ]]; then
  export K6_WEB_DASHBOARD_PERIOD="${K6_WEB_DASHBOARD_PERIOD}s"
fi
PROFILE="${PROFILE:-mixed}"
COURSE_PATH="${COURSE_PATH:-/course/view.php?id=2}"
QUIZ_PATH="${QUIZ_PATH:-/mod/quiz/view.php?id=1}"
AUTH_USER_PREFIX="${AUTH_USER_PREFIX:-user}"
AUTH_USER_START="${AUTH_USER_START:-1}"
AUTH_USER_COUNT="${AUTH_USER_COUNT:-500}"
AUTH_USER_PASSWORD="${AUTH_USER_PASSWORD:-123456}"
QUIZ_DO_SUBMIT="${QUIZ_DO_SUBMIT:-true}"
QUIZ_TEXT_ANSWER="${QUIZ_TEXT_ANSWER:-2}"
QUIZ_TEXT_ANSWERS="${QUIZ_TEXT_ANSWERS:-2,4,8}"
THINK_AFTER_HOME_MIN_SEC="${THINK_AFTER_HOME_MIN_SEC:-0}"
THINK_AFTER_HOME_MAX_SEC="${THINK_AFTER_HOME_MAX_SEC:-0.2}"
THINK_AFTER_LOGIN_MIN_SEC="${THINK_AFTER_LOGIN_MIN_SEC:-0.2}"
THINK_AFTER_LOGIN_MAX_SEC="${THINK_AFTER_LOGIN_MAX_SEC:-1}"
THINK_AFTER_COURSE_MIN_SEC="${THINK_AFTER_COURSE_MIN_SEC:-0.2}"
THINK_AFTER_COURSE_MAX_SEC="${THINK_AFTER_COURSE_MAX_SEC:-1}"
THINK_AFTER_QUIZ_VIEW_MIN_SEC="${THINK_AFTER_QUIZ_VIEW_MIN_SEC:-0.3}"
THINK_AFTER_QUIZ_VIEW_MAX_SEC="${THINK_AFTER_QUIZ_VIEW_MAX_SEC:-1.2}"
THINK_BEFORE_SUBMIT_MIN_SEC="${THINK_BEFORE_SUBMIT_MIN_SEC:-0.5}"
THINK_BEFORE_SUBMIT_MAX_SEC="${THINK_BEFORE_SUBMIT_MAX_SEC:-2}"
THINK_AFTER_SUMMARY_MIN_SEC="${THINK_AFTER_SUMMARY_MIN_SEC:-0.1}"
THINK_AFTER_SUMMARY_MAX_SEC="${THINK_AFTER_SUMMARY_MAX_SEC:-0.5}"
THINK_ITERATION_MIN_SEC="${THINK_ITERATION_MIN_SEC:-1}"
THINK_ITERATION_MAX_SEC="${THINK_ITERATION_MAX_SEC:-4}"
LOGIN_USERS_FILE="${LOGIN_USERS_FILE:-}"
LOGIN_USERS_CSV="${LOGIN_USERS_CSV:-}"
TEACHER_USER_PREFIX="${TEACHER_USER_PREFIX:-teacher}"
TEACHER_USER_START="${TEACHER_USER_START:-1}"
TEACHER_USER_COUNT="${TEACHER_USER_COUNT:-100}"
TEACHER_USER_PASSWORD="${TEACHER_USER_PASSWORD:-123456}"
TEACHER_RATIO_PCT="${TEACHER_RATIO_PCT:-20}"
THINK_AFTER_REPORT_MIN_SEC="${THINK_AFTER_REPORT_MIN_SEC:-0.5}"
THINK_AFTER_REPORT_MAX_SEC="${THINK_AFTER_REPORT_MAX_SEC:-2}"
THINK_AFTER_GRADEBOOK_MIN_SEC="${THINK_AFTER_GRADEBOOK_MIN_SEC:-0.5}"
THINK_AFTER_GRADEBOOK_MAX_SEC="${THINK_AFTER_GRADEBOOK_MAX_SEC:-2}"

if [[ -n "${LOGIN_USERS_FILE}" && -z "${LOGIN_USERS_CSV}" ]]; then
  if [[ -f "${LOGIN_USERS_FILE}" ]]; then
    LOGIN_USERS_CSV="$(<"${LOGIN_USERS_FILE}")"
  else
    echo "Warning: LOGIN_USERS_FILE not found: ${LOGIN_USERS_FILE}"
  fi
fi

# If local DNS resolver cannot resolve BASE_URL host, auto-generate a host mapping
# from a public resolver so k6 can still run (common with flaky systemd-resolved).
if [[ -z "${HOST_MAP}" && -n "${BASE_HOST}" ]]; then
  if ! getent ahostsv4 "${BASE_HOST}" >/dev/null 2>&1; then
    FALLBACK_IP=""
    if command -v dig >/dev/null 2>&1; then
      FALLBACK_IP="$(dig +short "${BASE_HOST}" @1.1.1.1 2>/dev/null | head -n 1 || true)"
    elif command -v nslookup >/dev/null 2>&1; then
      FALLBACK_IP="$(nslookup "${BASE_HOST}" 1.1.1.1 2>/dev/null | awk '/^Address: / {print $2}' | tail -n 1 || true)"
    fi

    if [[ -n "${FALLBACK_IP}" ]]; then
      HOST_MAP="${BASE_HOST}=${FALLBACK_IP}"
      echo "Local DNS cannot resolve ${BASE_HOST}; auto-enabled HOST_MAP=${HOST_MAP}"
    else
      echo "Warning: local DNS cannot resolve ${BASE_HOST} and no fallback IP was discovered."
      echo "Set HOST_MAP manually, e.g.: HOST_MAP='${BASE_HOST}=<ip>' ./run-stress-test.sh"
    fi
  fi
fi

# Default --quiet; override with K6_FLAGS or SHOW_WEB_DASHBOARD=true (adds web-dashboard)
if [[ -n "${K6_FLAGS:-}" ]]; then
  # shellcheck disable=SC2206
  K6_FLAGS_ARR=(${K6_FLAGS})
elif [[ "${SHOW_WEB_DASHBOARD}" == "true" ]]; then
  K6_FLAGS_DEFAULT=(--quiet --out web-dashboard)
  K6_FLAGS_ARR=("${K6_FLAGS_DEFAULT[@]}")
else
  K6_FLAGS_DEFAULT=(--quiet)
  K6_FLAGS_ARR=("${K6_FLAGS_DEFAULT[@]}")
fi

_open_dashboard_browser() {
  local url="${1:-}"
  [[ -z "${url}" ]] && return
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "${url}" >/dev/null 2>&1
  elif command -v open >/dev/null 2>&1; then
    open "${url}" >/dev/null 2>&1
  fi
}

_free_k6_dashboard_ports_if_busy() {
  local busy=false
  if command -v fuser >/dev/null 2>&1; then
    fuser 5665/tcp 2>/dev/null | grep -q . && busy=true
    fuser 6565/tcp 2>/dev/null | grep -q . && busy=true
    if [[ "${busy}" == "true" ]] && [[ "${K6_FREE_DASHBOARD_PORT}" == "true" ]]; then
      echo "Freeing ports 5665/6565 (stale k6 — otherwise dashboard shows no data)." >&2
      fuser -k 5665/tcp 2>/dev/null || true
      fuser -k 6565/tcp 2>/dev/null || true
      sleep 0.5
    elif [[ "${busy}" == "true" ]]; then
      echo "Warning: ports 5665 or 6565 in use. Run: fuser -k 5665/tcp; fuser -k 6565/tcp  OR  K6_FREE_DASHBOARD_PORT=true" >&2
    fi
    return 0
  fi
  if command -v lsof >/dev/null 2>&1; then
    local p
    p=$(lsof -ti:5665 2>/dev/null || true)
    if [[ -n "${p}" ]]; then busy=true; fi
    p=$(lsof -ti:6565 2>/dev/null || true)
    if [[ -n "${p}" ]]; then busy=true; fi
    if [[ "${busy}" == "true" ]] && [[ "${K6_FREE_DASHBOARD_PORT}" == "true" ]]; then
      echo "Freeing ports 5665/6565 via lsof (stale k6)." >&2
      local pid
      for pid in $(lsof -ti:5665 2>/dev/null); do kill -9 "${pid}" 2>/dev/null || true; done
      for pid in $(lsof -ti:6565 2>/dev/null); do kill -9 "${pid}" 2>/dev/null || true; done
      sleep 0.5
    elif [[ "${busy}" == "true" ]]; then
      echo "Warning: 5665/6565 in use. Kill manually or set K6_FREE_DASHBOARD_PORT=true" >&2
    fi
  fi
}

printf "Capacity test configuration:\n"
printf "  BASE_URL=%s\n" "${BASE_URL}"
printf "  START_VUS=%s STEP_VUS=%s MAX_VUS=%s\n" "${START_VUS}" "${STEP_VUS}" "${MAX_VUS}"
printf "  STEP_RAMP=%s STEP_HOLD=%s\n" "${STEP_RAMP}" "${STEP_HOLD}"
printf "  MAX_P95_MS=%s MAX_P99_MS=%s MAX_FAIL_RATE=%s ABORT_DELAY=%s\n\n" "${MAX_P95_MS}" "${MAX_P99_MS}" "${MAX_FAIL_RATE}" "${ABORT_DELAY}"
printf "  MAX_REDIRECTS=%s HTTP_TIMEOUT=%s\n\n" "${MAX_REDIRECTS}" "${HTTP_TIMEOUT}"
printf "  PROFILE=%s COURSE_PATH=%s QUIZ_PATH=%s QUIZ_DO_SUBMIT=%s\n\n" "${PROFILE}" "${COURSE_PATH}" "${QUIZ_PATH}" "${QUIZ_DO_SUBMIT}"
if [[ "${PROFILE}" == "auth_quiz" || "${PROFILE}" == "mixed_roles" ]]; then
  printf "  AUTH_USER_PREFIX=%s AUTH_USER_START=%s AUTH_USER_COUNT=%s\n" "${AUTH_USER_PREFIX}" "${AUTH_USER_START}" "${AUTH_USER_COUNT}"
  printf "  QUIZ_TEXT_ANSWERS=%s\n" "${QUIZ_TEXT_ANSWERS}"
  if [[ "${PROFILE}" == "mixed_roles" ]]; then
    printf "  TEACHER_USER_PREFIX=%s TEACHER_USER_COUNT=%s TEACHER_RATIO_PCT=%s%%\n" "${TEACHER_USER_PREFIX}" "${TEACHER_USER_COUNT}" "${TEACHER_RATIO_PCT}"
  fi
  printf "  Think time (s): login [%s–%s] course [%s–%s] quiz_view [%s–%s] before_submit [%s–%s] iteration [%s–%s]\n\n" \
    "${THINK_AFTER_LOGIN_MIN_SEC}" "${THINK_AFTER_LOGIN_MAX_SEC}" \
    "${THINK_AFTER_COURSE_MIN_SEC}" "${THINK_AFTER_COURSE_MAX_SEC}" \
    "${THINK_AFTER_QUIZ_VIEW_MIN_SEC}" "${THINK_AFTER_QUIZ_VIEW_MAX_SEC}" \
    "${THINK_BEFORE_SUBMIT_MIN_SEC}" "${THINK_BEFORE_SUBMIT_MAX_SEC}" \
    "${THINK_ITERATION_MIN_SEC}" "${THINK_ITERATION_MAX_SEC}"
  if [[ -n "${STAIRCASE_PLAN_PRESET:-}" ]]; then
    printf "  Plan: STAIRCASE_PLAN_PRESET (1 user → %s VU ceiling in last stage)\n\n" "${MAX_VUS}"
  else
    STEPS=0
    for ((v = START_VUS; v <= MAX_VUS; v += STEP_VUS)); do STEPS=$((STEPS + 1)); done
    RAMP_SEC="$(echo "${STEP_RAMP}" | sed 's/s$//')"
    HOLD_SEC="$(echo "${STEP_HOLD}" | sed 's/s$//')"
    ESTIMATE_SEC=$(( STEPS * (RAMP_SEC + HOLD_SEC) ))
    printf "  ~Staircase duration: %s steps × (%s+%s) ≈ %ss (~%sm)\n\n" "${STEPS}" "${STEP_RAMP}" "${STEP_HOLD}" "${ESTIMATE_SEC}" "$(( (ESTIMATE_SEC + 59) / 60 ))"
  fi
fi
if [[ -n "${HOST_MAP}" ]]; then
  printf "  HOST_MAP=%s\n\n" "${HOST_MAP}"
fi

if [[ -z "${STAIRCASE_PLAN_PRESET:-}" ]]; then
  if (( START_VUS <= 0 || STEP_VUS <= 0 || MAX_VUS < START_VUS )); then
    echo "Invalid VU parameters: ensure START_VUS>0, STEP_VUS>0 and MAX_VUS>=START_VUS"
    exit 1
  fi
fi

# Staircase: STAIRCASE_PLAN_PRESET or built from START/STEP/MAX_VUS. Format: duration:target,...
STAIRCASE_PLAN=""
if [[ -n "${STAIRCASE_PLAN_PRESET:-}" ]]; then
  STAIRCASE_PLAN="${STAIRCASE_PLAN_PRESET}"
  LAST_STAGE="${STAIRCASE_PLAN##*,}"
  PLANNED_MAX_VUS="${LAST_STAGE##*:}"
else
  PLANNED_MAX_VUS="${MAX_VUS}"
  for ((vus=START_VUS; vus<=MAX_VUS; vus+=STEP_VUS)); do
    if [[ -n "${STAIRCASE_PLAN}" ]]; then
      STAIRCASE_PLAN+=","
    fi
    STAIRCASE_PLAN+="${STEP_RAMP}:${vus},${STEP_HOLD}:${vus}"
  done
fi

TS="$(date +%Y%m%d-%H%M%S)"
SUMMARY_JSON="${OUT_DIR}/summary-staircase-${TS}.json"
LOG_FILE="${OUT_DIR}/run-staircase-${TS}.log"

echo "=== Running staircase stress test (no ramp-down, no rerun) ==="
echo "Stage plan: ${STAIRCASE_PLAN}"
echo "Planned peak concurrent VUs (last stage target): ${PLANNED_MAX_VUS}"
if [[ "${LIVE_K6_OUTPUT}" == "true" ]]; then
  echo "k6 output: terminal + ${LOG_FILE}"
else
  echo "k6 output: ${LOG_FILE} only (terminal stays quiet). LIVE_K6_OUTPUT=true to stream here."
fi

if [[ "${SHOW_WEB_DASHBOARD}" == "true" ]]; then
  _free_k6_dashboard_ports_if_busy
  echo "k6 dashboard URL: ${K6_DASHBOARD_UI_URL}"
  echo "  (charts need ~15–45s after load starts; refresh if empty while test is still running)"
  ( sleep 6 && _open_dashboard_browser "${K6_DASHBOARD_UI_URL}" ) &
fi

set +e
# k6 inherits exported K6_WEB_DASHBOARD_* (e.g. K6_WEB_DASHBOARD_HOST=0.0.0.0 for LAN).
run_k6() {
  K6_WEB_DASHBOARD="${K6_WEB_DASHBOARD:-true}" \
  K6_WEB_DASHBOARD_PERIOD="${K6_WEB_DASHBOARD_PERIOD:-5s}" \
  BASE_URL="${BASE_URL}" \
  STAIRCASE_PLAN="${STAIRCASE_PLAN}" \
  MAX_P95_MS="${MAX_P95_MS}" \
  MAX_P99_MS="${MAX_P99_MS}" \
  MAX_FAIL_RATE="${MAX_FAIL_RATE}" \
  ABORT_DELAY="${ABORT_DELAY}" \
  MAX_REDIRECTS="${MAX_REDIRECTS}" \
  HTTP_TIMEOUT="${HTTP_TIMEOUT}" \
  PROFILE="${PROFILE}" \
  COURSE_PATH="${COURSE_PATH}" \
  QUIZ_PATH="${QUIZ_PATH}" \
  AUTH_USER_PREFIX="${AUTH_USER_PREFIX}" \
  AUTH_USER_START="${AUTH_USER_START}" \
  AUTH_USER_COUNT="${AUTH_USER_COUNT}" \
  AUTH_USER_PASSWORD="${AUTH_USER_PASSWORD}" \
  QUIZ_DO_SUBMIT="${QUIZ_DO_SUBMIT}" \
  QUIZ_TEXT_ANSWER="${QUIZ_TEXT_ANSWER}" \
  QUIZ_TEXT_ANSWERS="${QUIZ_TEXT_ANSWERS}" \
  THINK_AFTER_HOME_MIN_SEC="${THINK_AFTER_HOME_MIN_SEC}" \
  THINK_AFTER_HOME_MAX_SEC="${THINK_AFTER_HOME_MAX_SEC}" \
  THINK_AFTER_LOGIN_MIN_SEC="${THINK_AFTER_LOGIN_MIN_SEC}" \
  THINK_AFTER_LOGIN_MAX_SEC="${THINK_AFTER_LOGIN_MAX_SEC}" \
  THINK_AFTER_COURSE_MIN_SEC="${THINK_AFTER_COURSE_MIN_SEC}" \
  THINK_AFTER_COURSE_MAX_SEC="${THINK_AFTER_COURSE_MAX_SEC}" \
  THINK_AFTER_QUIZ_VIEW_MIN_SEC="${THINK_AFTER_QUIZ_VIEW_MIN_SEC}" \
  THINK_AFTER_QUIZ_VIEW_MAX_SEC="${THINK_AFTER_QUIZ_VIEW_MAX_SEC}" \
  THINK_BEFORE_SUBMIT_MIN_SEC="${THINK_BEFORE_SUBMIT_MIN_SEC}" \
  THINK_BEFORE_SUBMIT_MAX_SEC="${THINK_BEFORE_SUBMIT_MAX_SEC}" \
  THINK_AFTER_SUMMARY_MIN_SEC="${THINK_AFTER_SUMMARY_MIN_SEC}" \
  THINK_AFTER_SUMMARY_MAX_SEC="${THINK_AFTER_SUMMARY_MAX_SEC}" \
  THINK_ITERATION_MIN_SEC="${THINK_ITERATION_MIN_SEC}" \
  THINK_ITERATION_MAX_SEC="${THINK_ITERATION_MAX_SEC}" \
  LOGIN_USERS_CSV="${LOGIN_USERS_CSV}" \
  TEACHER_USER_PREFIX="${TEACHER_USER_PREFIX}" \
  TEACHER_USER_START="${TEACHER_USER_START}" \
  TEACHER_USER_COUNT="${TEACHER_USER_COUNT}" \
  TEACHER_USER_PASSWORD="${TEACHER_USER_PASSWORD}" \
  TEACHER_RATIO_PCT="${TEACHER_RATIO_PCT}" \
  THINK_AFTER_REPORT_MIN_SEC="${THINK_AFTER_REPORT_MIN_SEC}" \
  THINK_AFTER_REPORT_MAX_SEC="${THINK_AFTER_REPORT_MAX_SEC}" \
  THINK_AFTER_GRADEBOOK_MIN_SEC="${THINK_AFTER_GRADEBOOK_MIN_SEC}" \
  THINK_AFTER_GRADEBOOK_MAX_SEC="${THINK_AFTER_GRADEBOOK_MAX_SEC}" \
  HOST_MAP="${HOST_MAP}" \
  k6 run "${K6_FLAGS_ARR[@]}" "${K6_SCRIPT}" --summary-export "${SUMMARY_JSON}"
}

if [[ "${LIVE_K6_OUTPUT}" == "true" ]]; then
  run_k6 2>&1 | tee "${LOG_FILE}"
  K6_EXIT=${PIPESTATUS[0]}
else
  run_k6 > "${LOG_FILE}" 2>&1
  K6_EXIT=$?
fi

echo ""
echo "=== k6 finished at $(date -Iseconds) (exit code ${K6_EXIT}) ==="

TIMEOUT_COUNT=$(grep -ci 'request timeout' "${LOG_FILE}" 2>/dev/null || true)
REDIRECT_WARN_COUNT=$(grep -ci 'Stopped after 11 redirects' "${LOG_FILE}" 2>/dev/null || true)

SUMMARY_OK=false
if [[ -f "${SUMMARY_JSON}" ]] && jq -e . "${SUMMARY_JSON}" >/dev/null 2>&1; then
  SUMMARY_OK=true
  FAIL_RATE=$(jq -r '((.metrics.http_req_failed // {}) | .value // .values.rate // 1) | tonumber' "${SUMMARY_JSON}")
  P95_MS=$(jq -r '((.metrics.http_req_duration // {}) | .["p(95)"] // .values["p(95)"] // 999999) | tonumber' "${SUMMARY_JSON}")
  P99_MS=$(jq -r '((.metrics.http_req_duration // {}) | .["p(99)"] // .values["p(99)"] // 999999) | tonumber' "${SUMMARY_JSON}")
  MAX_VUS_REACHED=$(jq -r '((.metrics.vus // {}) | .max // .value // 0) | tonumber' "${SUMMARY_JSON}")
else
  FAIL_RATE="n/a"
  P95_MS="n/a"
  P99_MS="n/a"
  MAX_VUS_REACHED="n/a"
  echo "" >&2
  echo "Warning: no valid summary JSON — k6 exited before writing the report (startup error or crash)." >&2
  echo "  Log: ${LOG_FILE}" >&2
  if grep -q "invalid duration" "${LOG_FILE}" 2>/dev/null; then
    echo "  Hint: set K6_WEB_DASHBOARD_PERIOD to a duration like 10s, then rerun." >&2
  fi
fi

echo
echo "=========================================="
echo "CONCURRENT VUs (peak reached in this run): ${MAX_VUS_REACHED}"
echo "Planned ceiling (last stage target):       ${PLANNED_MAX_VUS}"
echo "=========================================="
echo "Final result: fail_rate=${FAIL_RATE}, p95_ms=${P95_MS}, p99_ms=${P99_MS}, k6_exit=${K6_EXIT}"
echo "Warnings: timeouts=${TIMEOUT_COUNT}, redirect_limit_hits=${REDIRECT_WARN_COUNT}"

if [[ "${SUMMARY_OK}" == "true" ]]; then
  if awk -v f="${FAIL_RATE}" -v lim="${MAX_FAIL_RATE}" 'BEGIN {exit !(f > lim)}' </dev/null; then
    echo "Abort reason (primary): fail rate exceeded threshold (${FAIL_RATE} > ${MAX_FAIL_RATE})."
  elif awk -v p="${P95_MS}" -v lim="${MAX_P95_MS}" 'BEGIN {exit !(p > lim)}' </dev/null; then
    echo "Abort reason (primary): p95 latency exceeded threshold (${P95_MS} > ${MAX_P95_MS})."
  elif awk -v p="${P99_MS}" -v lim="${MAX_P99_MS}" 'BEGIN {exit !(p > lim)}' </dev/null; then
    echo "Abort reason (primary): p99 latency exceeded threshold (${P99_MS} > ${MAX_P99_MS})."
  elif [[ ${K6_EXIT} -ne 0 ]]; then
    echo "Abort reason: threshold abort or runtime error; inspect ${LOG_FILE} for details."
  fi
elif [[ ${K6_EXIT} -ne 0 ]]; then
  echo "Abort reason: k6 did not complete — see ${LOG_FILE} (no metrics / dashboard will show no data)."
fi

echo
if [[ ${K6_EXIT} -eq 0 ]]; then
  echo "Status: completed full plan (thresholds not breached). Peak VUs=${MAX_VUS_REACHED} / planned=${PLANNED_MAX_VUS}."
else
  echo "Status: stopped early (threshold abort, error, or interrupt). Peak VUs reached=${MAX_VUS_REACHED} (planned ceiling=${PLANNED_MAX_VUS})."
fi

echo "Artifacts:"
echo "  Summary: ${SUMMARY_JSON}"
echo "  Log:     ${LOG_FILE}"
if [[ "${SHOW_WEB_DASHBOARD}" == "true" ]]; then
  echo "  k6 web UI: ${K6_DASHBOARD_UI_URL}"
fi

echo "Grafana (thesis export): set the time range to this run’s peak window and capture"
echo "  “Moodle — Operations, SLO & scale” and “Moodle — Stack saturation & cluster”."
echo "  ../grafana-connect.sh from this stress-test folder (imports dashboards + port-forward)."

if [[ "${HOLD_AFTER_RUN}" == "true" ]] && [[ -t 0 ]]; then
  echo
  echo "Stress test run completed (log saved above). Press Enter to close this session..."
  read -r _ || true
fi

if [[ "${EXIT_WITH_K6_CODE}" == "true" ]]; then
  exit ${K6_EXIT}
fi

exit 0
