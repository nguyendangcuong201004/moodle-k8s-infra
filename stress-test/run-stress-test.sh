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
  # shellcheck disable=SC1090
  source "${PARAM_FILE}"
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

START_VUS="${START_VUS:-20}"
STEP_VUS="${STEP_VUS:-20}"
MAX_VUS="${MAX_VUS:-400}"
TEST_DURATION="${TEST_DURATION:-2m}"
MAX_P95_MS="${MAX_P95_MS:-2000}"
MAX_FAIL_RATE="${MAX_FAIL_RATE:-0.02}"
COOLDOWN_SEC="${COOLDOWN_SEC:-20}"

K6_FLAGS_DEFAULT=(--quiet --out web-dashboard)
if [[ -n "${K6_FLAGS:-}" ]]; then
  # shellcheck disable=SC2206
  K6_FLAGS_ARR=(${K6_FLAGS})
else
  K6_FLAGS_ARR=("${K6_FLAGS_DEFAULT[@]}")
fi

PASSING_VUS=0
FAILING_VUS=0
DASHBOARD_OPENED=false

printf "Capacity test configuration:\n"
printf "  BASE_URL=%s\n" "${BASE_URL}"
printf "  START_VUS=%s STEP_VUS=%s MAX_VUS=%s\n" "${START_VUS}" "${STEP_VUS}" "${MAX_VUS}"
printf "  TEST_DURATION=%s MAX_P95_MS=%s MAX_FAIL_RATE=%s\n\n" "${TEST_DURATION}" "${MAX_P95_MS}" "${MAX_FAIL_RATE}"

for ((vus=START_VUS; vus<=MAX_VUS; vus+=STEP_VUS)); do
  TS="$(date +%Y%m%d-%H%M%S)"
  SUMMARY_JSON="${OUT_DIR}/summary-${vus}vus-${TS}.json"
  LOG_FILE="${OUT_DIR}/run-${vus}vus-${TS}.log"

  echo "=== Running test at ${vus} concurrent users ==="
  set +e
  BASE_URL="${BASE_URL}" \
  TARGET_VUS="${vus}" \
  TEST_DURATION="${TEST_DURATION}" \
  MAX_P95_MS="${MAX_P95_MS}" \
  MAX_FAIL_RATE="${MAX_FAIL_RATE}" \
  k6 run "${K6_FLAGS_ARR[@]}" "${K6_SCRIPT}" --summary-export "${SUMMARY_JSON}" > "${LOG_FILE}" 2>&1 &

  K6_PID=$!

  # Open web dashboard in browser once, after k6 starts.
  if [[ "${DASHBOARD_OPENED}" == "false" ]]; then
    if command -v xdg-open >/dev/null 2>&1; then
      xdg-open "http://127.0.0.1:5665" >/dev/null 2>&1 || true
      DASHBOARD_OPENED=true
    fi
  fi

  wait "${K6_PID}"
  K6_EXIT=${PIPESTATUS[0]}

  FAIL_RATE=$(jq -r '.metrics.http_req_failed.values.rate // 1' "${SUMMARY_JSON}")
  P95_MS=$(jq -r '.metrics.http_req_duration.values["p(95)"] // 999999' "${SUMMARY_JSON}")

  echo "Result: fail_rate=${FAIL_RATE}, p95_ms=${P95_MS}, k6_exit=${K6_EXIT}"

  PASS=true
  awk "BEGIN {exit !(${FAIL_RATE} <= ${MAX_FAIL_RATE})}" || PASS=false
  awk "BEGIN {exit !(${P95_MS} <= ${MAX_P95_MS})}" || PASS=false
  if [[ ${K6_EXIT} -ne 0 ]]; then
    PASS=false
  fi

  if [[ "${PASS}" == "true" ]]; then
    PASSING_VUS="${vus}"
    echo "Status: PASS at ${vus} users"
  else
    FAILING_VUS="${vus}"
    echo "Status: FAIL at ${vus} users"
    break
  fi

  sleep "${COOLDOWN_SEC}"
done

echo
if [[ "${PASSING_VUS}" -eq 0 ]]; then
  echo "No passing level found. Environment failed at first step (${START_VUS} users)."
fi

if [[ "${FAILING_VUS}" -eq 0 ]]; then
  echo "No failure detected up to MAX_VUS=${MAX_VUS}."
  echo "Current tested capacity >= ${PASSING_VUS} concurrent users."
fi

echo "Estimated max stable capacity: ${PASSING_VUS} concurrent users"
echo "First failing level: ${FAILING_VUS} concurrent users"
echo "Detailed logs and summaries are in: ${OUT_DIR}"

echo
echo "Summary dashboard (per VU level):"
printf "%-8s %-12s %-12s\n" "VUs" "fail_rate" "p95_ms"
printf "%-8s %-12s %-12s\n" "--------" "--------" "--------"

for summary in "${OUT_DIR}"/summary-*vus-*.json; do
  [[ -e "${summary}" ]] || continue
  vus_val=$(basename "${summary}" | sed -E 's/summary-([0-9]+)vus-.+/\1/')
  fail_rate=$(jq -r '.metrics.http_req_failed.values.rate // 1' "${summary}")
  p95_ms=$(jq -r '.metrics.http_req_duration.values["p(95)"] // 999999' "${summary}")
  printf "%-8s %-12s %-12s\n" "${vus_val}" "${fail_rate}" "${p95_ms}"
done
echo
echo "k6 dashboard (if enabled): http://127.0.0.1:5665"
echo "Nhấn Enter để đóng script (dashboard sẽ dừng khi process kết thúc)..."
read -r _ || true
