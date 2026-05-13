#!/usr/bin/env bash
# Single source of config; sourced by setup.sh (do not execute directly).

WORKSPACE="${1:-}"
[[ "${WORKSPACE}" != "staging" && "${WORKSPACE}" != "production" ]] \
  && { echo "Usage: setup.sh <staging|production>"; exit 1; }

DO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${DO_DIR}/.." && pwd)"
HELM_CHART="${INFRA_DIR}/helm/moodle"
DASHBOARDS_DIR="${INFRA_DIR}/grafana/dashboards"
KUBECONFIG_FILE="${DO_DIR}/kubeconfig-${WORKSPACE}"

[[ -f "${INFRA_DIR}/.env" ]] && { set -a; source "${INFRA_DIR}/.env"; set +a; }

: "${DO_TOKEN:?Set DO_TOKEN in .env}"
export TF_VAR_do_token="${DO_TOKEN}"

ADMIN_USER="${MOODLE_ADMIN_USER:?Set MOODLE_ADMIN_USER in .env}"
ADMIN_PASS="${MOODLE_ADMIN_PASS:?Set MOODLE_ADMIN_PASS in .env}"
ADMIN_EMAIL="${MOODLE_ADMIN_EMAIL:?Set MOODLE_ADMIN_EMAIL in .env}"

[[ "${WORKSPACE}" == "production" ]] \
  && SITE_URL="${MOODLE_WWWROOT:?Set MOODLE_WWWROOT in .env}" \
  || SITE_URL="${MOODLE_STAGING_WWWROOT:?Set MOODLE_STAGING_WWWROOT in .env}"

INGRESS_HOST="${SITE_URL#https://}"; INGRESS_HOST="${INGRESS_HOST#http://}"
EXTERNAL_DNS_HOSTNAME="${INGRESS_HOST%%/*}"

# DB — filled after terraform apply (helpers.sh)
DB_HOST="" DB_PORT="" DB_PASS="" DB_NAME="" DB_CLUSTER_ID="" LB_NAME=""
DB_USER="${MOODLE_DB_USER:-moodleuser}"
DB_POOL_HOST="" DB_POOL_NAME="" DB_POOL_PORT="0" DB_POOL_PASS=""
DB_APP_HOST="" DB_APP_PORT="" DB_APP_PASS="" DB_APP_NAME="" DB_READONLY_HOST=""
USE_MANAGED_POOL="false"
MOODLE_USE_MANAGED_POOL="${MOODLE_USE_MANAGED_POOL:-false}"
# Read replica wiring (standby host from DO API) requires sidecar PgBouncer, not DO managed pool.
MOODLE_ENABLE_READ_SPLIT="${MOODLE_ENABLE_READ_SPLIT:-true}"

# PgBouncer sidecar when not using managed pool
PGBOUNCER_POOL_MODE="${PGBOUNCER_POOL_MODE:-session}"
PGBOUNCER_AUTH_TYPE="${PGBOUNCER_AUTH_TYPE:-scram-sha-256}"
# Per-pod upstream limit; ~floor(85/replicaCount) for 97-conn tier when using sidecar (not managed pool).
PGBOUNCER_DEFAULT_POOL_SIZE="${PGBOUNCER_DEFAULT_POOL_SIZE:-13}"
PGBOUNCER_RESERVE_POOL_SIZE="${PGBOUNCER_RESERVE_POOL_SIZE:-5}"
PGBOUNCER_MAX_CLIENT_CONN="${PGBOUNCER_MAX_CLIENT_CONN:-2000}"

# Grafana Cloud (optional)
GRAFANA_CLOUD_API_KEY="${GRAFANA_CLOUD_API_KEY:-}"
GRAFANA_CLOUD_PROM_URL="${GRAFANA_CLOUD_PROM_URL:-}"
GRAFANA_CLOUD_PROM_USERNAME="${GRAFANA_CLOUD_PROM_USERNAME:-}"
GRAFANA_CLOUD_TOKEN="${GRAFANA_CLOUD_TOKEN:-}"
GRAFANA_CLOUD_URL="${GRAFANA_CLOUD_URL:-}"

# Kubernetes
MOODLE_NAMESPACE="moodle"
MOODLE_RELEASE_NAME="${MOODLE_RELEASE_NAME:-moodle}"
MOODLE_REDIS_HOST="${MOODLE_REDIS_HOST:-${MOODLE_RELEASE_NAME}-redis-cache}"
MOODLE_REDIS_PORT="${MOODLE_REDIS_PORT:-6379}"
MOODLE_EXEC_CONTAINER="${MOODLE_K8S_MAIN_CONTAINER:-moodle}"
# Optional CLI prefix for MUC cache script (see step_moodle_muc_cache_setup): default empty = run `php` as
# container user (usually root on php-fpm images) so K8s env + DB secret are visible. Example override:
# MOODLE_MUC_PHP_WRAPPER='runuser -m -u www-data --'
# role=web excludes CronJob pods (role=cron); otherwise wait/exec may hit a cron pod first.
MOODLE_WEB_SELECTOR="app.kubernetes.io/instance=moodle,app.kubernetes.io/name=moodle,role=web"
MOODLE_POD=""

# Workspace-specific capacity controls.
# Keep production defaults from Terraform variables, but allow staging to be
# intentionally smaller to fit tighter droplet limits while retaining autoscale.
if [[ "${WORKSPACE}" == "staging" ]]; then
  export TF_VAR_enable_node_autoscale="${STAGING_ENABLE_NODE_AUTOSCALE:-true}"
  export TF_VAR_node_pool_count="${STAGING_NODE_POOL_COUNT:-3}"
  export TF_VAR_node_pool_min_nodes="${STAGING_NODE_POOL_MIN_NODES:-3}"
  export TF_VAR_node_pool_max_nodes="${STAGING_NODE_POOL_MAX_NODES:-3}"
  export TF_VAR_node_pool_size="${STAGING_NODE_POOL_SIZE:-s-2vcpu-4gb}"

  # Optional Helm/Longhorn downsize for staging app pods (cost/CICD only).
  # Defaults are intentionally small so staging can co-exist with production under tight quotas.
  STAGING_MOODLE_REPLICA_COUNT="${STAGING_MOODLE_REPLICA_COUNT:-1}"
  STAGING_MOODLEDATA_SIZE="${STAGING_MOODLEDATA_SIZE:-20Gi}"
  STAGING_LONGHORN_SC_REPLICA_COUNT="${STAGING_LONGHORN_SC_REPLICA_COUNT:-1}"
  STAGING_LONGHORN_STORAGECLASS="${STAGING_LONGHORN_STORAGECLASS:-longhorn-staging-r1}"
  STAGING_MOODLE_CPU_REQUEST="${STAGING_MOODLE_CPU_REQUEST:-500m}"
  STAGING_MOODLE_MEMORY_REQUEST="${STAGING_MOODLE_MEMORY_REQUEST:-1024Mi}"
  STAGING_PGBOUNCER_CPU_REQUEST="${STAGING_PGBOUNCER_CPU_REQUEST:-120m}"
  STAGING_PGBOUNCER_MEMORY_REQUEST="${STAGING_PGBOUNCER_MEMORY_REQUEST:-96Mi}"
fi

# Timing
STEP4_MAX_WAIT_SEC="${MOODLE_STEP4_MAX_WAIT_SEC:-1800}"
STEP4_POLL_SEC="${MOODLE_STEP4_POLL_SEC:-10}"

# Helm → apiserver (same path as kubectl; helps flaky networks during long setup.sh runs)
HELM_RETRIES="${HELM_RETRIES:-8}"
HELM_RETRY_DELAY_SEC="${HELM_RETRY_DELAY_SEC:-15}"

# Plugins to disable (keep e.g. quiz, resource/page, folder, url, assign, h5p)
MOODLE_DISABLED_PLUGINS=(
  mod_chat mod_scorm mod_workshop mod_data mod_wiki mod_glossary
  mod_survey mod_choice mod_lesson mod_imscp mod_lti mod_feedback
  mod_bigbluebuttonbn
)
