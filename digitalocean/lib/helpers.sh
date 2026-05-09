#!/usr/bin/env bash
# K8s helpers and Terraform wrapper (sourced by setup.sh).

KUBECTL_RETRIES="${KUBECTL_RETRIES:-6}"
KUBECTL_RETRY_DELAY_SEC="${KUBECTL_RETRY_DELAY_SEC:-3}"

# ── K8s helpers ───────────────────────────────────────────────────────────────

_kubectl() {
  command kubectl "$@"
}

kubectl_retry() {
  local attempt=1 status=1
  while (( attempt <= KUBECTL_RETRIES )); do
    if _kubectl "$@"; then
      return 0
    fi
    status=$?
    if (( attempt >= KUBECTL_RETRIES )); then
      break
    fi
    echo "kubectl failed (${attempt}/${KUBECTL_RETRIES}), retrying in ${KUBECTL_RETRY_DELAY_SEC}s..." >&2
    sleep "${KUBECTL_RETRY_DELAY_SEC}"
    ((attempt++))
  done
  return "${status}"
}

kubectl() {
  kubectl_retry "$@"
}

# Decoded value from a Kubernetes secret key.
k8s_secret() {
  local ns="$1" name="$2" key="$3"
  kubectl -n "${ns}" get secret "${name}" -o "jsonpath={.data.${key}}" 2>/dev/null \
    | base64 -d 2>/dev/null || true
}

ensure_namespace() {
  # Avoid kubectl fetching OpenAPI schema for validation (timeouts on flaky paths to apiserver).
  kubectl create namespace "$1" --dry-run=client -o yaml | kubectl apply --validate=false -f -
}

# Web pod name where container "moodle" is Ready. Do not require pod phase=Running:
# a sidecar can leave the pod Pending while "moodle" is already exec-ready.
pick_ready_web_pod() {
  local pod
  pod=$(kubectl -n "${MOODLE_NAMESPACE}" get pods -l "${MOODLE_WEB_SELECTOR}" -o json 2>/dev/null \
    | jq -r '.items | sort_by(.metadata.creationTimestamp) | .[]
              | select(.metadata.deletionTimestamp == null)
              | select(any(.status.containerStatuses[]?; .name == "moodle" and .ready == true))
              | .metadata.name' | head -1)
  [[ -n "${pod}" ]] && { echo "${pod}"; return; }
  # Fallback: moodle container running but not yet marked Ready.
  kubectl -n "${MOODLE_NAMESPACE}" get pods -l "${MOODLE_WEB_SELECTOR}" -o json 2>/dev/null \
    | jq -r '.items | sort_by(.metadata.creationTimestamp) | .[]
              | select(.metadata.deletionTimestamp == null)
              | select(any(.status.containerStatuses[]?; .name == "moodle" and (.state.running != null)))
              | .metadata.name' | head -1
}

start_grafana_port_forward() {
  local u p
  u="$(k8s_secret monitoring kube-prometheus-stack-grafana admin-user)"
  p="$(k8s_secret monitoring kube-prometheus-stack-grafana admin-password)"
  [[ -z "${u}" ]] && return

  pkill -f "port-forward.*kube-prometheus-stack-grafana.*3000" 2>/dev/null || true

  (while true; do
    kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80 >/dev/null 2>&1
    sleep 3
  done) &
  disown

  local i
  for i in $(seq 1 15); do
    curl -fsS http://127.0.0.1:3000/api/health >/dev/null 2>&1 && break
    sleep 1
  done

  echo "Grafana: http://localhost:3000  user=${u}  pass=${p}"
}

exec_retry() {
  local attempt=0 pod=""
  while (( attempt++ < 8 )); do
    pod="$(pick_ready_web_pod)"
    [[ -z "${pod}" ]] && { echo "No pod (${attempt}/8)..."; sleep 3; continue; }
    if kubectl -n "${MOODLE_NAMESPACE}" exec "${pod}" -c "${MOODLE_EXEC_CONTAINER}" -- "$@"; then
      MOODLE_POD="${pod}"; return 0
    fi
    echo "exec fail on ${pod} (${attempt}/8)..."; sleep 3
  done
  return 1
}

exec_retry_stdin() {
  local cmd="$1" attempt=0 pod=""
  while (( attempt++ < 8 )); do
    pod="$(pick_ready_web_pod)"
    [[ -z "${pod}" ]] && { echo "No pod (${attempt}/8)..."; sleep 3; continue; }
    if kubectl -n "${MOODLE_NAMESPACE}" exec -i "${pod}" -c "${MOODLE_EXEC_CONTAINER}" -- sh -c "${cmd}"; then
      MOODLE_POD="${pod}"; return 0
    fi
    echo "exec -i fail on ${pod} (${attempt}/8)..."; sleep 3
  done
  return 1
}

get_moodle_version() {
  kubectl -n "${MOODLE_NAMESPACE}" exec "$1" -c "${MOODLE_EXEC_CONTAINER}" -- \
    runuser -u www-data -- php admin/cli/cfg.php --name=version 2>/dev/null | tr -d '\r\n' || true
}

run_terraform() {
  echo "=== Terraform: apply [${WORKSPACE}] ==="
  cd "${DO_DIR}"
  [[ ! -d ".terraform" ]] && terraform init -upgrade

  if terraform workspace list | grep -q "^[* ]*${WORKSPACE}$"; then
    terraform workspace select "${WORKSPACE}"
  else
    terraform workspace new "${WORKSPACE}"
  fi

  export TF_IN_AUTOMATION=1 TF_LOG=ERROR
  terraform apply -auto-approve 2>&1 | grep -v "Still creating" || true
  [[ ${PIPESTATUS[0]} -ne 0 ]] && exit 1

  # Parse outputs
  local j; j=$(terraform output -json)
  DB_HOST=$(echo "${j}" | jq -r '.db_host.value')
  DB_PORT=$(echo "${j}" | jq -r '.db_port.value')
  DB_PASS=$(echo "${j}" | jq -r '.db_password.value')
  DB_NAME=$(echo "${j}" | jq -r '.db_name.value')
  DB_CLUSTER_ID=$(echo "${j}" | jq -r '.db_cluster_id.value')
  LB_NAME=$(echo "${j}" | jq -r '.lb_name.value')
  local u; u=$(echo "${j}" | jq -r '.db_user.value // empty')
  [[ -n "${u}" && "${u}" != "null" ]] && DB_USER="${u}"
  DB_POOL_HOST=$(echo "${j}" | jq -r '.db_pool_host.value // empty')
  DB_POOL_NAME=$(echo "${j}" | jq -r '.db_pool_name.value // empty')
  DB_POOL_PORT=$(echo "${j}" | jq -r '.db_pool_port.value // 0')
  DB_POOL_PASS=$(echo "${j}" | jq -r '.db_pool_password.value // empty')

  # Validate
  for v in DB_HOST DB_PASS DB_CLUSTER_ID LB_NAME; do
    [[ -z "${!v}" || "${!v}" == "null" ]] && { echo "Missing terraform output: ${v}"; exit 1; }
  done

  # Direct DB + PgBouncer sidecar vs DO managed connection pool
  if [[ -n "${DB_POOL_HOST}" && "${DB_POOL_PORT}" != "0" && -n "${DB_POOL_PASS}" \
        && "${MOODLE_USE_MANAGED_POOL}" == "true" ]]; then
    USE_MANAGED_POOL="true"
    DB_APP_HOST="${DB_POOL_HOST}" DB_APP_PORT="${DB_POOL_PORT}"
    DB_APP_PASS="${DB_POOL_PASS}" DB_APP_NAME="${DB_POOL_NAME:-moodle-pool-${WORKSPACE}}"
    HELM_PGBOUNCER_ARGS=(--set pgbouncer.enabled=false)
    echo "Managed pool: ${DB_APP_HOST}:${DB_APP_PORT}"
  else
    DB_APP_HOST="${DB_HOST}" DB_APP_PORT="${DB_PORT}"
    DB_APP_PASS="${DB_PASS}" DB_APP_NAME="${DB_NAME}"
    HELM_PGBOUNCER_ARGS=(
      --set pgbouncer.enabled=true
      --set pgbouncer.authType="${PGBOUNCER_AUTH_TYPE}"
      --set pgbouncer.poolMode="${PGBOUNCER_POOL_MODE}"
      --set pgbouncer.defaultPoolSize="${PGBOUNCER_DEFAULT_POOL_SIZE}"
      --set pgbouncer.reservePoolSize="${PGBOUNCER_RESERVE_POOL_SIZE}"
      --set pgbouncer.maxClientConn="${PGBOUNCER_MAX_CLIENT_CONN}"
    )
    echo "Direct DB + PgBouncer (${PGBOUNCER_POOL_MODE}, pool=${PGBOUNCER_DEFAULT_POOL_SIZE})"
  fi

  # Read replica when read split is enabled
  if [[ "${USE_MANAGED_POOL}" != "true" && "${MOODLE_ENABLE_READ_SPLIT}" == "true" ]]; then
    local cr; cr=$(curl -sS -H "Authorization: Bearer ${DO_TOKEN}" \
      "https://api.digitalocean.com/v2/databases/${DB_CLUSTER_ID}" 2>/dev/null || true)
    DB_READONLY_HOST=$(echo "${cr}" | jq -r '.database.standby_connection.host // empty' || true)
    [[ -z "${DB_READONLY_HOST}" ]] && DB_READONLY_HOST="${MOODLE_DB_READONLY_HOST:-}"
  fi

  local raw; raw=$(terraform output -raw kubeconfig)
  [[ -z "${raw}" ]] && { echo "Missing kubeconfig output"; exit 1; }
  printf '%s' "${raw}" > "${KUBECONFIG_FILE}"
  export KUBECONFIG="${KUBECONFIG_FILE}"
}