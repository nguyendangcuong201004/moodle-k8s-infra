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
MAX_P95_MS="${MAX_P95_MS:-2000}"
MAX_FAIL_RATE="${MAX_FAIL_RATE:-0.02}"
ABORT_DELAY="${ABORT_DELAY:-0s}"
MAX_REDIRECTS="${MAX_REDIRECTS:-5}"
HTTP_TIMEOUT="${HTTP_TIMEOUT:-12s}"
HOST_MAP="${HOST_MAP:-}"
HOLD_AFTER_RUN="${HOLD_AFTER_RUN:-true}"
EXIT_WITH_K6_CODE="${EXIT_WITH_K6_CODE:-false}"

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

K6_FLAGS_DEFAULT=(--quiet --out web-dashboard)
if [[ -n "${K6_FLAGS:-}" ]]; then
  # shellcheck disable=SC2206
  K6_FLAGS_ARR=(${K6_FLAGS})
else
  K6_FLAGS_ARR=("${K6_FLAGS_DEFAULT[@]}")
fi

DASHBOARD_OPENED=false

printf "Capacity test configuration:\n"
printf "  BASE_URL=%s\n" "${BASE_URL}"
printf "  START_VUS=%s STEP_VUS=%s MAX_VUS=%s\n" "${START_VUS}" "${STEP_VUS}" "${MAX_VUS}"
printf "  STEP_RAMP=%s STEP_HOLD=%s\n" "${STEP_RAMP}" "${STEP_HOLD}"
printf "  MAX_P95_MS=%s MAX_FAIL_RATE=%s ABORT_DELAY=%s\n\n" "${MAX_P95_MS}" "${MAX_FAIL_RATE}" "${ABORT_DELAY}"
printf "  MAX_REDIRECTS=%s HTTP_TIMEOUT=%s\n\n" "${MAX_REDIRECTS}" "${HTTP_TIMEOUT}"
if [[ -n "${HOST_MAP}" ]]; then
  printf "  HOST_MAP=%s\n\n" "${HOST_MAP}"
fi

if (( START_VUS <= 0 || STEP_VUS <= 0 || MAX_VUS < START_VUS )); then
  echo "Invalid VU parameters: ensure START_VUS>0, STEP_VUS>0 and MAX_VUS>=START_VUS"
  exit 1
fi

# Build one staircase plan for a single k6 run.
# Format: "duration:target,duration:target,..."
STAIRCASE_PLAN=""
for ((vus=START_VUS; vus<=MAX_VUS; vus+=STEP_VUS)); do
  if [[ -n "${STAIRCASE_PLAN}" ]]; then
    STAIRCASE_PLAN+="," 
  fi
  STAIRCASE_PLAN+="${STEP_RAMP}:${vus},${STEP_HOLD}:${vus}"
done

TS="$(date +%Y%m%d-%H%M%S)"
SUMMARY_JSON="${OUT_DIR}/summary-staircase-${TS}.json"
LOG_FILE="${OUT_DIR}/run-staircase-${TS}.log"

echo "=== Running single staircase test (no ramp-down, no rerun) ==="
echo "Stage plan: ${STAIRCASE_PLAN}"

set +e
BASE_URL="${BASE_URL}" \
STAIRCASE_PLAN="${STAIRCASE_PLAN}" \
MAX_P95_MS="${MAX_P95_MS}" \
MAX_FAIL_RATE="${MAX_FAIL_RATE}" \
ABORT_DELAY="${ABORT_DELAY}" \
MAX_REDIRECTS="${MAX_REDIRECTS}" \
HTTP_TIMEOUT="${HTTP_TIMEOUT}" \
HOST_MAP="${HOST_MAP}" \
k6 run "${K6_FLAGS_ARR[@]}" "${K6_SCRIPT}" --summary-export "${SUMMARY_JSON}" > "${LOG_FILE}" 2>&1 &

K6_PID=$!

# Open web dashboard once, after k6 starts.
if [[ "${DASHBOARD_OPENED}" == "false" ]]; then
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "http://127.0.0.1:5665" >/dev/null 2>&1 || true
    DASHBOARD_OPENED=true
  fi
fi

wait "${K6_PID}"
K6_EXIT=$?

FAIL_RATE=$(jq -r '((.metrics.http_req_failed // {}) | .value // .values.rate // 1) | tonumber' "${SUMMARY_JSON}")
P95_MS=$(jq -r '((.metrics.http_req_duration // {}) | .["p(95)"] // .values["p(95)"] // 999999) | tonumber' "${SUMMARY_JSON}")
MAX_VUS_REACHED=$(jq -r '((.metrics.vus // {}) | .max // .value // 0) | tonumber' "${SUMMARY_JSON}")
TIMEOUT_COUNT=$(grep -ci 'request timeout' "${LOG_FILE}" 2>/dev/null || true)
REDIRECT_WARN_COUNT=$(grep -ci 'Stopped after 11 redirects' "${LOG_FILE}" 2>/dev/null || true)

echo
echo "Final result: fail_rate=${FAIL_RATE}, p95_ms=${P95_MS}, k6_exit=${K6_EXIT}"
echo "Reached VUs before stop: ${MAX_VUS_REACHED}"
echo "Warnings: timeouts=${TIMEOUT_COUNT}, redirect_limit_hits=${REDIRECT_WARN_COUNT}"

if awk "BEGIN {exit !(${P95_MS} > ${MAX_P95_MS})}"; then
  echo "Abort reason (primary): p95 latency exceeded threshold (${P95_MS} > ${MAX_P95_MS})."
elif awk "BEGIN {exit !(${FAIL_RATE} > ${MAX_FAIL_RATE})}"; then
  echo "Abort reason (primary): fail rate exceeded threshold (${FAIL_RATE} > ${MAX_FAIL_RATE})."
elif [[ ${K6_EXIT} -ne 0 ]]; then
  echo "Abort reason: threshold abort or runtime error; inspect ${LOG_FILE} for details."
fi

echo
if [[ ${K6_EXIT} -eq 0 ]]; then
  echo "Status: PASS to MAX_VUS=${MAX_VUS} (thresholds never breached)."
else
  echo "Status: ABORTED on first threshold breach (stopped immediately, no ramp-down)."
fi

echo "Artifacts:"
echo "  Summary: ${SUMMARY_JSON}"
echo "  Log:     ${LOG_FILE}"
echo "k6 dashboard (if enabled): http://127.0.0.1:5665"

if [[ "${HOLD_AFTER_RUN}" == "true" ]] && [[ -t 0 ]]; then
  echo
  echo "Press Enter to finish and close this stress-test session..."
  read -r _ || true
fi

if [[ "${EXIT_WITH_K6_CODE}" == "true" ]]; then
  exit ${K6_EXIT}
fi

exit 0
