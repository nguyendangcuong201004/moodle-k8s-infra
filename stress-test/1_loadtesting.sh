#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export TEST_NAME="${TEST_NAME:-load}"

# Load test for the proposed Cloudflare Waiting Room threshold.
# Ramp gradually to avoid measuring a burst spike, then hold 150 VUs for 5 minutes.
export STAIRCASE_PLAN_PRESET="${STAIRCASE_PLAN_PRESET:-2m:150,5m:150}"
export START_VUS="${START_VUS:-150}"
export STEP_VUS="${STEP_VUS:-150}"
export MAX_VUS="${MAX_VUS:-150}"

export MAX_P95_MS="${MAX_P95_MS:-3000}"
export MAX_P99_MS="${MAX_P99_MS:-5000}"
export MAX_FAIL_RATE="${MAX_FAIL_RATE:-0.005}"
export ABORT_DELAY="${ABORT_DELAY:-30s}"
export HTTP_TIMEOUT="${HTTP_TIMEOUT:-120s}"

export PROFILE="${PROFILE:-mixed_roles}"
export LIVE_K6_OUTPUT="${LIVE_K6_OUTPUT:-false}"
export SHOW_WEB_DASHBOARD="${SHOW_WEB_DASHBOARD:-true}"
export HOLD_AFTER_RUN="${HOLD_AFTER_RUN:-false}"
export EXIT_WITH_K6_CODE="${EXIT_WITH_K6_CODE:-false}"

exec "${SCRIPT_DIR}/_run_k6_common.sh"
