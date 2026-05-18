#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export TEST_NAME="${TEST_NAME:-burst}"

# Burst test: keep a small warm baseline, jump to a sudden spike, then drop back
# to baseline so DB/PgBouncer/PHP-FPM recovery is visible in Grafana.
#
# Format is k6 ramping-vus stages: duration:target,...
# Default: 50 VUs warmup -> 500 VUs in 5s -> hold 60s -> drop to 50 -> recover.
export BASELINE_VUS="${BASELINE_VUS:-50}"
export BURST_VUS="${BURST_VUS:-600}"
export WARMUP_DURATION="${WARMUP_DURATION:-60s}"
export BURST_RAMP_DURATION="${BURST_RAMP_DURATION:-5s}"
export BURST_HOLD_DURATION="${BURST_HOLD_DURATION:-60s}"
export RECOVERY_DURATION="${RECOVERY_DURATION:-120s}"
export COOLDOWN_DURATION="${COOLDOWN_DURATION:-30s}"

export STAIRCASE_PLAN_PRESET="${STAIRCASE_PLAN_PRESET:-${WARMUP_DURATION}:${BASELINE_VUS},${BURST_RAMP_DURATION}:${BURST_VUS},${BURST_HOLD_DURATION}:${BURST_VUS},${COOLDOWN_DURATION}:${BASELINE_VUS},${RECOVERY_DURATION}:${BASELINE_VUS},10s:0}"
export START_VUS="${START_VUS:-${BASELINE_VUS}}"
export STEP_VUS="${STEP_VUS:-${BURST_VUS}}"
export MAX_VUS="${MAX_VUS:-${BURST_VUS}}"

# Burst tests should usually complete the full spike + recovery plan. Keep the
# thresholds effectively disabled by default, then inspect the reported p95/p99,
# fail rate, and Grafana recovery curves after the run.
export MAX_P95_MS="${MAX_P95_MS:-999999}"
export MAX_P99_MS="${MAX_P99_MS:-999999}"
export MAX_FAIL_RATE="${MAX_FAIL_RATE:-1}"
export ABORT_DELAY="${ABORT_DELAY:-0s}"
export HTTP_TIMEOUT="${HTTP_TIMEOUT:-120s}"

export PROFILE="${PROFILE:-mixed_roles}"
export LIVE_K6_OUTPUT="${LIVE_K6_OUTPUT:-false}"
export SHOW_WEB_DASHBOARD="${SHOW_WEB_DASHBOARD:-true}"
export SHOW_GRAFANA_HINT="${SHOW_GRAFANA_HINT:-true}"
export HOLD_AFTER_RUN="${HOLD_AFTER_RUN:-false}"
export EXIT_WITH_K6_CODE="${EXIT_WITH_K6_CODE:-false}"

exec "${SCRIPT_DIR}/_run_k6_common.sh"
