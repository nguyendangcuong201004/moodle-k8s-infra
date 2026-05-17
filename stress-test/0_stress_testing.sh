#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Stress test: find the breaking point by stepping up to high concurrency.
export TEST_NAME="${TEST_NAME:-stress}"
export STAIRCASE_PLAN_PRESET="${STAIRCASE_PLAN_PRESET:-75s:100,75s:200,75s:300,75s:400,75s:500}"
export START_VUS="${START_VUS:-100}"
export STEP_VUS="${STEP_VUS:-100}"
export MAX_VUS="${MAX_VUS:-500}"

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
