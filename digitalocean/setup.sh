#!/usr/bin/env bash
# Usage:
#   ./setup.sh staging     — set up the staging environment
#   ./setup.sh production  — set up the production environment
set -euo pipefail

WORKSPACE="${1:-}"
if [[ "${WORKSPACE}" != "staging" && "${WORKSPACE}" != "production" ]]; then
  echo "Usage: $0 <staging|production>"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${SCRIPT_DIR}/.env"
  set +a
fi

DO_DIR="${SCRIPT_DIR}/digitalocean"

echo "=== Step 0: Check environment and required tools ==="
command -v terraform >/dev/null 2>&1 || { echo "terraform is required"; exit 1; }
command -v kubectl   >/dev/null 2>&1 || { echo "kubectl is required"; exit 1; }
command -v helm      >/dev/null 2>&1 || { echo "helm is required (https://helm.sh/docs/intro/install/)"; exit 1; }
command -v jq        >/dev/null 2>&1 || { echo "jq is required"; exit 1; }


if [[ -z "${DO_TOKEN:-}" ]]; then
  echo "DO_TOKEN not set. Set it in .env."
  exit 1
fi
export TF_VAR_do_token="${DO_TOKEN}"

ADMIN_USER="${MOODLE_ADMIN_USER:?Set MOODLE_ADMIN_USER in .env}"
ADMIN_PASS="${MOODLE_ADMIN_PASS:?Set MOODLE_ADMIN_PASS in .env}"
ADMIN_EMAIL="${MOODLE_ADMIN_EMAIL:?Set MOODLE_ADMIN_EMAIL in .env}"

# Determine site URL and PVC size based on workspace
if [[ "${WORKSPACE}" == "production" ]]; then
  SITE_URL="${MOODLE_WWWROOT:?Set MOODLE_WWWROOT in .env}"
else
  SITE_URL="${MOODLE_STAGING_WWWROOT:?Set MOODLE_STAGING_WWWROOT in .env}"
fi

# Derive ingress host from URL (strip https:// or http://)
INGRESS_HOST="${SITE_URL#https://}"
INGRESS_HOST="${INGRESS_HOST#http://}"
EXTERNAL_DNS_HOSTNAME="${INGRESS_HOST%%/*}"

echo
echo "=== Step 1: Terraform workspace + apply [workspace: ${WORKSPACE}] ==="
cd "${DO_DIR}"

if [[ ! -d ".terraform" ]]; then
  echo "Running terraform init..."
  terraform init -upgrade
fi

# Switch to the target workspace (create it if it doesn't exist)
if terraform workspace list | grep -q "^[* ]*${WORKSPACE}$"; then
  terraform workspace select "${WORKSPACE}"
else
  terraform workspace new "${WORKSPACE}"
fi

echo "Running terraform apply (this may incur cost)..."
export TF_IN_AUTOMATION=1
export TF_LOG=ERROR
terraform apply -auto-approve 2>&1 | grep -v "Still creating" || true
[[ ${PIPESTATUS[0]} -ne 0 ]] && exit "${PIPESTATUS[0]}"

TF_JSON=$(terraform output -json)
DB_HOST=$(echo "${TF_JSON}"       | jq -r '.db_host.value')
DB_PORT=$(echo "${TF_JSON}"       | jq -r '.db_port.value')
DB_PASS=$(echo "${TF_JSON}"       | jq -r '.db_password.value')
DB_USER=$(echo "${TF_JSON}"       | jq -r '.db_user.value // empty')
DB_NAME=$(echo "${TF_JSON}"       | jq -r '.db_name.value')
DB_CLUSTER_ID=$(echo "${TF_JSON}" | jq -r '.db_cluster_id.value')
DB_POOL_HOST=$(echo "${TF_JSON}"  | jq -r '.db_pool_host.value // empty')
DB_POOL_NAME=$(echo "${TF_JSON}"  | jq -r '.db_pool_name.value // empty')
DB_POOL_PORT=$(echo "${TF_JSON}"  | jq -r '.db_pool_port.value // 0')
DB_POOL_PASS=$(echo "${TF_JSON}"  | jq -r '.db_pool_password.value // empty')
[[ -z "${DB_USER}" || "${DB_USER}" == "null" ]] && DB_USER="${MOODLE_DB_USER:-moodleuser}"

USE_MANAGED_POOL="false"
if [[ -n "${DB_POOL_HOST}" && "${DB_POOL_PORT}" != "0" && -n "${DB_POOL_PASS}" ]]; then
  USE_MANAGED_POOL="true"
fi

# Moodle can hit intermittent dmlreadexception with some managed pool setups.
# Default to direct DB endpoint; opt in to managed pool explicitly when desired.
MOODLE_USE_MANAGED_POOL="${MOODLE_USE_MANAGED_POOL:-false}"
if [[ "${MOODLE_USE_MANAGED_POOL}" != "true" ]]; then
  USE_MANAGED_POOL="false"
fi

DB_APP_HOST="${DB_HOST}"
DB_APP_PORT="${DB_PORT}"
DB_APP_PASS="${DB_PASS}"
DB_APP_NAME="${DB_NAME}"
# Default: enable per-pod PgBouncer sidecar for direct DB connectivity.
# Keep pool sizing conservative for max 8 web pods and ~397 DB connections.
PGBOUNCER_POOL_MODE="${PGBOUNCER_POOL_MODE:-session}"
PGBOUNCER_AUTH_TYPE="${PGBOUNCER_AUTH_TYPE:-scram-sha-256}"
PGBOUNCER_DEFAULT_POOL_SIZE="${PGBOUNCER_DEFAULT_POOL_SIZE:-35}"
PGBOUNCER_RESERVE_POOL_SIZE="${PGBOUNCER_RESERVE_POOL_SIZE:-5}"
PGBOUNCER_MAX_CLIENT_CONN="${PGBOUNCER_MAX_CLIENT_CONN:-2000}"
HELM_PGBOUNCER_ARGS=(
  --set pgbouncer.enabled=true
  --set pgbouncer.authType="${PGBOUNCER_AUTH_TYPE}"
  --set pgbouncer.poolMode="${PGBOUNCER_POOL_MODE}"
  --set pgbouncer.defaultPoolSize="${PGBOUNCER_DEFAULT_POOL_SIZE}"
  --set pgbouncer.reservePoolSize="${PGBOUNCER_RESERVE_POOL_SIZE}"
  --set pgbouncer.maxClientConn="${PGBOUNCER_MAX_CLIENT_CONN}"
)
if [[ "${USE_MANAGED_POOL}" == "true" ]]; then
  # Avoid double pooling: when managed pool is available, app should use it directly.
  DB_APP_HOST="${DB_POOL_HOST}"
  DB_APP_PORT="${DB_POOL_PORT}"
  DB_APP_PASS="${DB_POOL_PASS}"
  # DigitalOcean pool expects DB name to match the pool name (not the original database name).
  if [[ -n "${DB_POOL_NAME}" ]]; then
    DB_APP_NAME="${DB_POOL_NAME}"
  else
    DB_APP_NAME="moodle-pool-${WORKSPACE}"
  fi
  HELM_PGBOUNCER_ARGS=(--set pgbouncer.enabled=false)
  echo "DigitalOcean managed connection pool detected: ${DB_POOL_HOST}:${DB_POOL_PORT} (db=${DB_APP_NAME})"
else
  if [[ -n "${DB_POOL_HOST}" && "${DB_POOL_PORT}" != "0" ]]; then
    echo "Managed pool is available but disabled for Moodle (MOODLE_USE_MANAGED_POOL=false)."
  fi
  echo "Using direct DB endpoint for Moodle."
  echo "PgBouncer sidecar enabled: auth_type=${PGBOUNCER_AUTH_TYPE}, mode=${PGBOUNCER_POOL_MODE}, default_pool_size=${PGBOUNCER_DEFAULT_POOL_SIZE}, reserve_pool_size=${PGBOUNCER_RESERVE_POOL_SIZE}, max_client_conn=${PGBOUNCER_MAX_CLIENT_CONN}"
fi

# Optional read-replica host for Moodle readonly routing.
DB_READONLY_HOST=""
if [[ -n "${DO_TOKEN:-}" && -n "${DB_CLUSTER_ID}" ]]; then
  DB_CLUSTER_JSON=$(curl -sS -H "Authorization: Bearer ${DO_TOKEN}" \
    "https://api.digitalocean.com/v2/databases/${DB_CLUSTER_ID}" 2>/dev/null || true)
  DB_READONLY_HOST=$(echo "${DB_CLUSTER_JSON}" | jq -r '.database.standby_connection.host // empty' 2>/dev/null || true)
  if [[ -z "${DB_READONLY_HOST}" ]]; then
    # Allow manual override if standby endpoint is not exposed by API.
    DB_READONLY_HOST="${MOODLE_DB_READONLY_HOST:-}"
  fi
fi

[[ -z "${DB_HOST}" || "${DB_HOST}" == "null" ]]        && { echo "Missing db_host output.";       exit 1; }
[[ -z "${DB_PASS}" || "${DB_PASS}" == "null" ]]        && { echo "Missing db_password output.";   exit 1; }
[[ -z "${DB_CLUSTER_ID}" || "${DB_CLUSTER_ID}" == "null" ]] && { echo "Missing db_cluster_id output."; exit 1; }

LB_NAME=$(echo "${TF_JSON}" | jq -r '.lb_name.value')
[[ -z "${LB_NAME}" || "${LB_NAME}" == "null" ]] && { echo "Missing lb_name output."; exit 1; }

KUBECONFIG_RAW=$(terraform output -raw kubeconfig)
[[ -z "${KUBECONFIG_RAW}" ]] && { echo "Missing kubeconfig output."; exit 1; }
KUBECONFIG_FILE="${DO_DIR}/kubeconfig-${WORKSPACE}"
printf '%s' "${KUBECONFIG_RAW}" > "${KUBECONFIG_FILE}"
export KUBECONFIG="${KUBECONFIG_FILE}"

# Read a decoded value from an existing Kubernetes secret. Returns empty on any error.
get_k8s_secret_value() {
  local namespace="$1"
  local secret_name="$2"
  local secret_key="$3"

  kubectl -n "${namespace}" get secret "${secret_name}" -o "jsonpath={.data.${secret_key}}" 2>/dev/null \
    | base64 -d 2>/dev/null || true
}

# Read raw base64 value from an existing Kubernetes secret key.
get_k8s_secret_b64() {
  local namespace="$1"
  local secret_name="$2"
  local secret_key="$3"

  kubectl -n "${namespace}" get secret "${secret_name}" -o "jsonpath={.data.${secret_key}}" 2>/dev/null || true
}

echo
echo "=== Step 1.5: Longhorn ==="
LONGHORN_URL="https://raw.githubusercontent.com/longhorn/longhorn/v1.11.0/deploy/longhorn.yaml"
if ! kubectl get ns longhorn-system &>/dev/null; then
  kubectl apply -f "${LONGHORN_URL}"
  if ! kubectl -n longhorn-system wait --for=condition=Ready pod -l app=longhorn-manager --timeout=300s 2>/dev/null; then
    echo "Longhorn not ready in 300s. Check: kubectl -n longhorn-system get pods"
    exit 1
  fi
fi

echo
echo "=== Step 1.6: Metrics Server (required for HPA) ==="
if ! kubectl get deployment metrics-server -n kube-system &>/dev/null; then
  kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
  # DO kubelet uses self-signed certs — metrics-server needs --kubelet-insecure-tls
  kubectl -n kube-system patch deployment metrics-server --type='json' \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
  kubectl -n kube-system rollout status deployment/metrics-server --timeout=120s || true
fi

echo
echo "=== Step 1.7: Prometheus + Adapter (custom metrics for HPA) ==="
# Prometheus collects metrics, prometheus-adapter exposes them to HPA

# Grafana Cloud remote_write (optional — set GRAFANA_CLOUD_API_KEY in .env)
GRAFANA_REMOTE_WRITE_ARGS=""
EXISTING_GRAFANA_USER=""
EXISTING_GRAFANA_PASS=""
if [[ -z "${GRAFANA_CLOUD_API_KEY:-}" ]]; then
  EXISTING_GRAFANA_USER="$(get_k8s_secret_value monitoring grafana-cloud-credentials username)"
  EXISTING_GRAFANA_PASS="$(get_k8s_secret_value monitoring grafana-cloud-credentials password)"
  if [[ -n "${EXISTING_GRAFANA_USER}" && -n "${EXISTING_GRAFANA_PASS}" ]]; then
    GRAFANA_CLOUD_PROM_USERNAME="${GRAFANA_CLOUD_PROM_USERNAME:-${EXISTING_GRAFANA_USER}}"
    GRAFANA_CLOUD_API_KEY="${EXISTING_GRAFANA_PASS}"
    echo "Using existing secret monitoring/grafana-cloud-credentials for Grafana Cloud auth."
  fi
fi

GRAFANA_SHOW_USER="${GRAFANA_CLOUD_PROM_USERNAME:-${EXISTING_GRAFANA_USER}}"
GRAFANA_SHOW_PASS="${GRAFANA_CLOUD_API_KEY:-${EXISTING_GRAFANA_PASS}}"
if [[ -n "${GRAFANA_SHOW_USER}" && -n "${GRAFANA_SHOW_PASS}" ]]; then
  echo "Grafana credentials (copy to login):"
  echo "  username: ${GRAFANA_SHOW_USER}"
  echo "  password: ${GRAFANA_SHOW_PASS}"
fi

if [[ -n "${GRAFANA_CLOUD_API_KEY:-}" ]]; then
  if [[ -z "${GRAFANA_CLOUD_PROM_URL:-}" || -z "${GRAFANA_CLOUD_PROM_USERNAME:-}" ]]; then
    echo "Grafana Cloud credentials found but remote_write config is incomplete."
    echo "Skipping remote_write (set GRAFANA_CLOUD_PROM_URL and GRAFANA_CLOUD_PROM_USERNAME to enable)."
  else
    echo "Grafana Cloud integration enabled — configuring remote_write..."
    kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
    kubectl create secret generic grafana-cloud-credentials \
      --namespace monitoring \
      --from-literal=username="${GRAFANA_CLOUD_PROM_USERNAME}" \
      --from-literal=password="${GRAFANA_CLOUD_API_KEY}" \
      --dry-run=client -o yaml | kubectl apply -f -
    echo "Grafana secret ensured in namespace: monitoring"
    GRAFANA_REMOTE_WRITE_ARGS="\
      --set prometheus.prometheusSpec.remoteWrite[0].url=${GRAFANA_CLOUD_PROM_URL} \
      --set prometheus.prometheusSpec.remoteWrite[0].basicAuth.username.name=grafana-cloud-credentials \
      --set prometheus.prometheusSpec.remoteWrite[0].basicAuth.username.key=username \
      --set prometheus.prometheusSpec.remoteWrite[0].basicAuth.password.name=grafana-cloud-credentials \
      --set prometheus.prometheusSpec.remoteWrite[0].basicAuth.password.key=password"
  fi
fi

if ! helm list -n monitoring -q 2>/dev/null | grep -q '^kube-prometheus-stack$'; then
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
  helm repo update
  # shellcheck disable=SC2086
  helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
    --namespace monitoring --create-namespace \
    --set prometheus.prometheusSpec.retention=6h \
    --set prometheus.prometheusSpec.resources.requests.cpu=100m \
    --set prometheus.prometheusSpec.resources.requests.memory=256Mi \
    --set prometheus.prometheusSpec.resources.limits.cpu=500m \
    --set prometheus.prometheusSpec.resources.limits.memory=512Mi \
    --set grafana.resources.requests.cpu=50m \
    --set grafana.resources.requests.memory=128Mi \
    --set grafana.resources.limits.cpu=200m \
    --set grafana.resources.limits.memory=256Mi \
    --set alertmanager.enabled=false \
    --set nodeExporter.enabled=true \
    --set kubeStateMetrics.enabled=true \
    ${GRAFANA_REMOTE_WRITE_ARGS} \
    --wait --timeout 5m || echo "Prometheus install failed, continuing..."
fi

if ! helm list -n monitoring -q 2>/dev/null | grep -q '^prometheus-adapter$'; then
  helm install prometheus-adapter prometheus-community/prometheus-adapter \
    --namespace monitoring \
    --set prometheus.url=http://kube-prometheus-stack-prometheus.monitoring.svc \
    --set prometheus.port=9090 \
    --set rules.default=false \
    --set "rules.custom[0].seriesQuery=container_network_receive_bytes_total{namespace=\"moodle\"}" \
    --set "rules.custom[0].resources.overrides.namespace.resource=namespace" \
    --set "rules.custom[0].resources.overrides.pod.resource=pod" \
    --set "rules.custom[0].name.as=http_requests_per_second" \
    --set "rules.custom[0].metricsQuery=sum(rate(container_network_receive_bytes_total{namespace=\"moodle\",container=\"moodle\"}[2m])) by (pod) / 1024" \
    --wait --timeout 3m || echo "Prometheus-adapter install failed, continuing..."
fi

echo
echo "=== Grafana UI Access ==="
GRAFANA_UI_USER="$(get_k8s_secret_value monitoring kube-prometheus-stack-grafana admin-user)"
GRAFANA_UI_PASS="$(get_k8s_secret_value monitoring kube-prometheus-stack-grafana admin-password)"
if [[ -n "${GRAFANA_UI_USER}" && -n "${GRAFANA_UI_PASS}" ]]; then
  echo "Grafana URL: http://localhost:3000"
  echo "Grafana username: ${GRAFANA_UI_USER}"
  echo "Grafana password: ${GRAFANA_UI_PASS}"
  echo "Run port-forward in another terminal:"
  echo "  kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80"
else
  echo "Could not read Grafana UI credentials from secret monitoring/kube-prometheus-stack-grafana."
  echo "Check manually: kubectl -n monitoring get secret kube-prometheus-stack-grafana -o yaml"
fi

echo
echo "=== Step 1.8: Provision Grafana Cloud dashboards ==="
if [[ -n "${GRAFANA_CLOUD_TOKEN:-}" && -n "${GRAFANA_CLOUD_URL:-}" ]]; then
  DASHBOARDS_DIR="${SCRIPT_DIR}/grafana/dashboards"
  if [[ -d "${DASHBOARDS_DIR}" ]]; then
    for dashboard_file in "${DASHBOARDS_DIR}"/*.json; do
      [ -f "${dashboard_file}" ] || continue
      dashboard_name=$(basename "${dashboard_file}" .json)
      echo "Importing dashboard: ${dashboard_name}"
      PAYLOAD=$(jq -n --argjson dashboard "$(cat "${dashboard_file}")" \
        '{dashboard: ($dashboard + {id: null}), overwrite: true, folderId: 0}')
      curl -sS -X POST "${GRAFANA_CLOUD_URL}/api/dashboards/db" \
        -H "Authorization: Bearer ${GRAFANA_CLOUD_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "${PAYLOAD}" || echo "  Failed to import ${dashboard_name}"
    done
  fi
else
  echo "Skipped (GRAFANA_CLOUD_TOKEN or GRAFANA_CLOUD_URL not set)"
fi

echo
echo "=== Step 2: Deploy Moodle via Helm ==="
HELM_CHART="${SCRIPT_DIR}/helm/moodle"
[[ ! -d "${HELM_CHART}" ]] && { echo "Helm chart not found at ${HELM_CHART}"; exit 1; }

echo "Deploying with unified high-capacity profile (values.yaml)"
HELM_READONLY_ARGS=()
MOODLE_ENABLE_READ_SPLIT="${MOODLE_ENABLE_READ_SPLIT:-false}"
if [[ "${USE_MANAGED_POOL}" == "true" ]]; then
  echo "DB read/write split skipped because managed connection pool is enabled."
elif [[ "${MOODLE_ENABLE_READ_SPLIT}" != "true" ]]; then
  echo "DB read/write split disabled by default (set MOODLE_ENABLE_READ_SPLIT=true to enable)."
elif [[ -n "${DB_READONLY_HOST}" && "${DB_READONLY_HOST}" != "${DB_HOST}" ]]; then
  echo "DB read/write split enabled: write=${DB_HOST}, read=${DB_READONLY_HOST}"
  HELM_READONLY_ARGS+=(--set-string "db.readonlyHosts[0]=${DB_READONLY_HOST}")
else
  echo "DB read/write split not enabled (no standby host detected)."
fi

helm upgrade --install moodle "${HELM_CHART}" \
  --namespace moodle --create-namespace \
  -f "${HELM_CHART}/values.yaml" \
  --set db.host="${DB_APP_HOST}" \
  --set db.port="${DB_APP_PORT}" \
  --set db.name="${DB_APP_NAME}" \
  --set db.user="${DB_USER}" \
  --set db.password="${DB_APP_PASS}" \
  --set db.sslmode=require \
  --set moodle.wwwroot="${SITE_URL}" \
  --set persistence.storageClass=longhorn \
  --set service.type=LoadBalancer \
  --set ingress.enabled=false \
  --set "service.annotations.service\.beta\.kubernetes\.io/do-loadbalancer-name=${LB_NAME}" \
  --set "service.annotations.external-dns\.alpha\.kubernetes\.io/hostname=${EXTERNAL_DNS_HOSTNAME}" \
  "${HELM_PGBOUNCER_ARGS[@]}" \
  "${HELM_READONLY_ARGS[@]}"

echo
echo "=== ExternalDNS ==="
if [[ -n "${CF_API_TOKEN:-}" ]] && [[ -f "k8s/external-dns-cloudflare.yaml" ]]; then
  kubectl create namespace external-dns --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret generic cloudflare-external-dns-api \
    --from-literal=CF_API_TOKEN="${CF_API_TOKEN}" \
    -n external-dns \
    --dry-run=client -o yaml | kubectl apply -f -
  sed "s/EXTERNAL_DNS_DOMAIN_PLACEHOLDER/${EXTERNAL_DNS_HOSTNAME}/g" k8s/external-dns-cloudflare.yaml | kubectl apply -f -
  kubectl rollout restart deployment/external-dns -n external-dns 2>/dev/null || true
fi

echo
echo "=== Step 3: GRANT schema public to DB user ==="
# GRANT runs in default namespace (not moodle namespace) for simplicity
doadmin_pass="${DO_DB_ADMIN_PASSWORD:-}"
if [[ -z "${doadmin_pass}" ]]; then
  # Reuse existing secret if available (from prior run), then fall back to DO API.
  doadmin_pass="$(get_k8s_secret_value default do-db-admin-grant PGPASSWORD)"
fi
if [[ -z "${doadmin_pass}" ]]; then
  echo "Fetching doadmin password from DigitalOcean API..."
  DO_ADMIN_RESP=$(curl -sS -H "Authorization: Bearer ${DO_TOKEN}" \
    "https://api.digitalocean.com/v2/databases/${DB_CLUSTER_ID}/users/doadmin" 2>/dev/null || true)
  doadmin_pass=$(echo "${DO_ADMIN_RESP}" | jq -r '.user.password // empty' 2>/dev/null || true)
fi
[[ -z "${doadmin_pass}" ]] && { echo "Cannot get doadmin password. Run GRANT manually."; exit 1; }

GRANT_JOB="moodle-db-grant-$(date +%s)"
kubectl create secret generic do-db-admin-grant \
  --from-literal=PGPASSWORD="${doadmin_pass}" \
  --dry-run=client -o yaml | kubectl apply -f -

GRANT_YAML=$(mktemp /tmp/grant-job.XXXXXX.yaml)
cat > "${GRANT_YAML}" <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${GRANT_JOB}
spec:
  activeDeadlineSeconds: 90
  ttlSecondsAfterFinished: 60
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: grant
          image: postgres:15-alpine
          env:
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef:
                  name: do-db-admin-grant
                  key: PGPASSWORD
          command:
            - sh
            - -c
            - |
              psql -h ${DB_HOST} -p ${DB_PORT} -U doadmin -d ${DB_NAME} -v ON_ERROR_STOP=1 \
                -c "GRANT ALL ON SCHEMA public TO ${DB_USER};" \
                -c "GRANT CREATE ON SCHEMA public TO ${DB_USER};"
EOF
kubectl apply -f "${GRANT_YAML}"
rm -f "${GRANT_YAML}"

echo "Waiting for GRANT job ${GRANT_JOB} (max 120s, image pull may be slow on first run)..."
if kubectl wait --for=condition=complete "job/${GRANT_JOB}" --timeout=120s 2>/dev/null; then
  kubectl delete job "${GRANT_JOB}" --ignore-not-found=true
  kubectl delete secret do-db-admin-grant --ignore-not-found=true
  echo "GRANT done."
else
  echo "GRANT job did not complete in time. Pod status:"
  kubectl get pods -l "job-name=${GRANT_JOB}" 2>/dev/null || true
  kubectl logs "job/${GRANT_JOB}" 2>/dev/null || true
  kubectl delete job "${GRANT_JOB}" --ignore-not-found=true
  kubectl delete secret do-db-admin-grant --ignore-not-found=true
  echo "GRANT failed. If pod was ImagePullBackOff: first run on this cluster can be slow. Retry or run manually as doadmin: GRANT ALL ON SCHEMA public TO ${DB_USER};"
  exit 1
fi

echo
echo "=== Step 4: Wait for Moodle pods (Running — probes may still fail until DB/config) ==="
# FPM chart: init copy-moodle-app copies the full Moodle tree to emptyDir; image pull can be minutes.
STEP4_MAX_WAIT_SEC="${MOODLE_STEP4_MAX_WAIT_SEC:-1800}"
STEP4_POLL_SEC="${MOODLE_STEP4_POLL_SEC:-10}"
STEP4_ITER=$(( (STEP4_MAX_WAIT_SEC + STEP4_POLL_SEC - 1) / STEP4_POLL_SEC ))
[[ "${STEP4_ITER}" -lt 1 ]] && STEP4_ITER=1
echo "  Max wait: ${STEP4_MAX_WAIT_SEC}s (env MOODLE_STEP4_MAX_WAIT_SEC). Poll every ${STEP4_POLL_SEC}s (MOODLE_STEP4_POLL_SEC)."
echo "  Expect several minutes on first run (pull ~350MB+ image + large cp in init)."

MOODLE_EXEC_CONTAINER="${MOODLE_K8S_MAIN_CONTAINER:-moodle}"
# Use Helm app labels for web pods; legacy !role selector misses current deployments.
MOODLE_WEB_SELECTOR="app.kubernetes.io/instance=moodle,app.kubernetes.io/name=moodle"

for i in $(seq 1 "${STEP4_ITER}"); do
  ELAPSED=$(( (i - 1) * STEP4_POLL_SEC ))
  echo ""
  echo "--- Step 4 [${ELAPSED}s elapsed, cap ${STEP4_MAX_WAIT_SEC}s] #${i}/${STEP4_ITER} ---"

  MOODLE_POD=$(kubectl -n moodle get pods -l "${MOODLE_WEB_SELECTOR}" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -z "${MOODLE_POD}" ]]; then
    MOODLE_POD=$(kubectl -n moodle get pods -l "${MOODLE_WEB_SELECTOR}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  fi

  if [[ -z "${MOODLE_POD}" ]]; then
    echo "  No web pod found yet (selector: ${MOODLE_WEB_SELECTOR})."
    kubectl -n moodle get deploy -o wide 2>/dev/null | head -20 || true
    kubectl -n moodle get rs -l "${MOODLE_WEB_SELECTOR}" 2>/dev/null | head -8 || true
  else
    POD_PHASE=$(kubectl -n moodle get pod "${MOODLE_POD}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    echo "  Pod: ${MOODLE_POD}  phase=${POD_PHASE:-unknown}"

    if [[ -n "${POD_PHASE}" && "${POD_PHASE}" != "Running" ]]; then
      kubectl -n moodle get pod "${MOODLE_POD}" -o json 2>/dev/null | jq -r '.status.conditions[]? | "  cond \(.type): \(.status) \(.message // "")"' 2>/dev/null | head -8 || true
    fi

    kubectl -n moodle get pod "${MOODLE_POD}" -o json 2>/dev/null | jq -r '
      .status.initContainerStatuses[]?
      | "  init \(.name): ready=\(.ready) restart=\(.restartCount) "
        + (if .state.waiting then "waiting reason=\(.state.waiting.reason // "?") message=\(.state.waiting.message // "-")"
           elif .state.running then "running startedAt=\(.state.running.startedAt // "-")"
           elif .state.terminated then "terminated exit=\(.state.terminated.exitCode) reason=\(.state.terminated.reason // "-")"
           else "state=?" end)
    ' 2>/dev/null || true

    kubectl -n moodle get pod "${MOODLE_POD}" -o json 2>/dev/null | jq -r '.status.containerStatuses[]? | "  container \(.name): ready=\(.ready) restart=\(.restartCount)"' 2>/dev/null || true

    INIT_RUNNING=$(kubectl -n moodle get pod "${MOODLE_POD}" -o json 2>/dev/null | jq -r '.status.initContainerStatuses[]? | select(.state.running != null) | .name' | head -1)
    if [[ -n "${INIT_RUNNING}" ]]; then
      echo "  Init log tail (-c ${INIT_RUNNING}):"
      kubectl -n moodle logs "${MOODLE_POD}" -c "${INIT_RUNNING}" --tail=8 2>/dev/null || true
    fi

    if [[ "${POD_PHASE}" == "Running" ]]; then
      echo "  OK: Pod ${MOODLE_POD} is Running (Ready bit may still be false until probes/install)."
      break
    fi

    if (( i % 6 == 0 )); then
      echo "  Recent web pod list:"
      kubectl -n moodle get pods -l "${MOODLE_WEB_SELECTOR}" --no-headers 2>/dev/null | head -6 || true
    fi
  fi

  if [[ "${i}" -eq "${STEP4_ITER}" ]]; then
    echo ""
    echo "ERROR: No Moodle pod reached Running within ${STEP4_MAX_WAIT_SEC}s."
    echo "Increase wait: MOODLE_STEP4_MAX_WAIT_SEC=3600 ./setup.sh ${WORKSPACE}"
    kubectl -n moodle get pods -l "${MOODLE_WEB_SELECTOR}" -o yaml 2>/dev/null | tail -80 || true
    if [[ -n "${MOODLE_POD:-}" ]]; then
      echo "--- describe pod ${MOODLE_POD} (tail) ---"
      kubectl -n moodle describe pod "${MOODLE_POD}" 2>/dev/null | tail -70 || true
    fi
    exit 1
  fi

  sleep "${STEP4_POLL_SEC}"
done

echo
echo "=== Step 4.5: Services ==="
kubectl -n moodle get svc
LB_IP=$(kubectl -n moodle get svc moodle -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
LB_HOST=$(kubectl -n moodle get svc moodle -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
if [[ -n "${LB_IP}" ]]; then
  echo "DNS: Add A record ${EXTERNAL_DNS_HOSTNAME} -> ${LB_IP}"
elif [[ -n "${LB_HOST}" ]]; then
  echo "DNS: Add CNAME ${EXTERNAL_DNS_HOSTNAME} -> ${LB_HOST}"
fi

echo
echo "=== Step 5: moodledata permissions and install_database.php ==="
pick_ready_web_pod() {
  local pod
  pod=$(kubectl -n moodle get pods -l "${MOODLE_WEB_SELECTOR}" --field-selector=status.phase=Running -o json 2>/dev/null \
    | jq -r '.items
      | sort_by(.metadata.creationTimestamp)
      | .[]
      | select(.metadata.deletionTimestamp == null)
      | select(any(.status.containerStatuses[]?; .name == "moodle" and .ready == true))
      | .metadata.name' \
    | head -1)
  if [[ -n "${pod}" ]]; then
    echo "${pod}"
    return 0
  fi

  kubectl -n moodle get pods -l "${MOODLE_WEB_SELECTOR}" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

exec_with_retry() {
  local attempt=0
  local max_attempts=8
  local pod=""
  while (( attempt < max_attempts )); do
    attempt=$((attempt + 1))
    pod="$(pick_ready_web_pod)"
    if [[ -z "${pod}" ]]; then
      echo "No ready web pod found (attempt ${attempt}/${max_attempts}), retrying..."
      sleep 3
      continue
    fi
    if kubectl -n moodle exec "${pod}" -c "${MOODLE_EXEC_CONTAINER}" -- "$@"; then
      MOODLE_POD="${pod}"
      return 0
    fi
    echo "kubectl exec failed on pod ${pod} (attempt ${attempt}/${max_attempts}), retrying..."
    sleep 3
  done
  return 1
}

exec_with_retry_stdin() {
  local remote_cmd="$1"
  local attempt=0
  local max_attempts=8
  local pod=""
  while (( attempt < max_attempts )); do
    attempt=$((attempt + 1))
    pod="$(pick_ready_web_pod)"
    if [[ -z "${pod}" ]]; then
      echo "No ready web pod found (attempt ${attempt}/${max_attempts}), retrying..."
      sleep 3
      continue
    fi
    if kubectl -n moodle exec -i "${pod}" -c "${MOODLE_EXEC_CONTAINER}" -- sh -c "${remote_cmd}"; then
      MOODLE_POD="${pod}"
      return 0
    fi
    echo "kubectl exec -i failed on pod ${pod} (attempt ${attempt}/${max_attempts}), retrying..."
    sleep 3
  done
  return 1
}

get_moodle_db_version() {
  local pod="$1"
  kubectl -n moodle exec "${pod}" -c "${MOODLE_EXEC_CONTAINER}" -- \
    runuser -u www-data -- php admin/cli/cfg.php --name=version 2>/dev/null | tr -d '\r\n' || true
}

MOODLE_POD="$(pick_ready_web_pod)"
if [[ -z "${MOODLE_POD}" ]]; then
  echo "No Running/Ready Moodle web pod. Check: kubectl -n moodle get pods -l ${MOODLE_WEB_SELECTOR}"
  exit 1
fi

if ! exec_with_retry chown -R www-data:www-data /var/www/moodledata; then
  echo "chown failed after retries. Check: kubectl -n moodle logs deployment/moodle --tail=120"
  exit 1
fi
if ! exec_with_retry chmod -R 777 /var/www/moodledata; then
  echo "chmod failed after retries."
  exit 1
fi

echo "Using pod-generated config.php from Helm env (keeps proxy/redis/db settings consistent across replicas)."

INSTALL_DONE=false
PRECHECK_DB_VERSION="$(get_moodle_db_version "${MOODLE_POD}")"
if [[ "${PRECHECK_DB_VERSION}" =~ ^[0-9] ]]; then
  echo "Moodle already installed (version: ${PRECHECK_DB_VERSION}); skipping install_database.php."
  INSTALL_DONE=true
fi

if [[ "${INSTALL_DONE}" != "true" ]]; then
  echo "Running database installation in background (5-10 min, please wait)..."
  # Keep installer artifacts on shared PVC so pod restarts do not lose progress logs.
  INSTALL_DIR="/var/www/moodledata/.install"
  INSTALL_SCRIPT_PATH="${INSTALL_DIR}/moodle-install.sh"
  INSTALL_LOG_PATH="${INSTALL_DIR}/install.log"
  INSTALL_EXIT_PATH="${INSTALL_DIR}/install.exit"
  INSTALL_RELAUNCHED=false

  if ! exec_with_retry sh -c "mkdir -p ${INSTALL_DIR} && rm -f ${INSTALL_LOG_PATH} ${INSTALL_EXIT_PATH}"; then
    echo "Failed to prepare installer workspace in moodledata."
    exit 1
  fi

  # Write install script into pod to avoid kubectl exec streaming timeout (DO API proxy drops long connections)
  if ! exec_with_retry_stdin "cat > ${INSTALL_SCRIPT_PATH} && chmod +x ${INSTALL_SCRIPT_PATH}" << EOF
#!/bin/bash
exec > ${INSTALL_LOG_PATH} 2>&1
cd /var/www/html
rm -f ${INSTALL_EXIT_PATH}
echo "[\$(date -Iseconds)] install_database.php started"
runuser -u www-data -- php -d display_errors=1 admin/cli/install_database.php \
  --lang=en \
  --adminuser="${ADMIN_USER}" \
  --adminpass="${ADMIN_PASS}" \
  --adminemail="${ADMIN_EMAIL}" \
  --fullname="HCMUT E-learning" \
  --shortname="HCMUT LMS" \
  --agree-license
RC=\$?
echo "[\$(date -Iseconds)] install_database.php finished with exit=\${RC}"
echo \${RC} > ${INSTALL_EXIT_PATH}
EOF
  then
    echo "Failed to stage installer script after retries."
    exit 1
  fi

  # Launch in background — kubectl exec returns immediately, no long-lived connection
  if ! exec_with_retry sh -c "nohup sh ${INSTALL_SCRIPT_PATH} >/dev/null 2>&1 &"; then
    echo "Failed to launch installer script after retries."
    exit 1
  fi

  # Poll for DB install completion (max 15 min).
  # We do three checks: install exit code file, DB version, and short log tail every 60s.
  LAST_LOG_SIZE=0
  for i in $(seq 1 60); do
    sleep 15
    ELAPSED=$(( i * 15 ))

    # Re-resolve pod name in case of restart.
    CURRENT_POD=$(kubectl -n moodle get pods -l "${MOODLE_WEB_SELECTOR}" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    [[ -z "${CURRENT_POD}" ]] && CURRENT_POD="${MOODLE_POD}"

    if [[ -z "${CURRENT_POD}" ]]; then
      echo "[${ELAPSED}s] Waiting for running Moodle web pod..."
      [[ $i -eq 60 ]] && { echo "Install timeout (15min): no running Moodle web pod."; exit 1; }
      continue
    fi

    INSTALL_EXIT=$(kubectl -n moodle exec "${CURRENT_POD}" -c "${MOODLE_EXEC_CONTAINER}" -- sh -c "cat ${INSTALL_EXIT_PATH} 2>/dev/null || true" 2>/dev/null | tr -d '\r\n' || true)
    if [[ "${INSTALL_EXIT}" == "0" ]]; then
      DB_VERSION="$(get_moodle_db_version "${CURRENT_POD}")"
      if [[ "${DB_VERSION}" =~ ^[0-9] ]]; then
        echo "Database installed successfully (version: ${DB_VERSION})."
        INSTALL_DONE=true
        break
      fi
    elif [[ "${INSTALL_EXIT}" =~ ^[1-9][0-9]*$ ]]; then
      INSTALL_LOG_TAIL=$(kubectl -n moodle exec "${CURRENT_POD}" -c "${MOODLE_EXEC_CONTAINER}" -- sh -c "tail -n 40 ${INSTALL_LOG_PATH} 2>/dev/null || echo '(no installer log)'" 2>/dev/null || true)
      if echo "${INSTALL_LOG_TAIL}" | grep -qi 'Database tables already present'; then
        DB_VERSION="$(get_moodle_db_version "${CURRENT_POD}")"
        echo "Database already initialized; skipping installer (version: ${DB_VERSION:-unknown})."
        INSTALL_DONE=true
        break
      fi
      echo "Install failed (exit=${INSTALL_EXIT}). Last install log lines:"
      echo "${INSTALL_LOG_TAIL}"
      exit 1
    fi

    LOG_META=$(kubectl -n moodle exec "${CURRENT_POD}" -c "${MOODLE_EXEC_CONTAINER}" -- sh -c "if [ -f ${INSTALL_LOG_PATH} ]; then bytes=\$(wc -c < ${INSTALL_LOG_PATH} 2>/dev/null || echo 0); mtime=\$(date -r ${INSTALL_LOG_PATH} +%H:%M:%S 2>/dev/null || echo n/a); echo \"\${bytes}:\${mtime}\"; else echo '0:none'; fi" 2>/dev/null || echo "0:none")
    LOG_SIZE=${LOG_META%%:*}
    LOG_MTIME=${LOG_META#*:}
    [[ -z "${LOG_SIZE}" ]] && LOG_SIZE=0
    echo "[${ELAPSED}s] Installing... pod=${CURRENT_POD} log_bytes=${LOG_SIZE} log_mtime=${LOG_MTIME}"

    # Show installer output more frequently when there is new content.
    if (( LOG_SIZE > LAST_LOG_SIZE )) || (( i % 2 == 0 )); then
      kubectl -n moodle exec "${CURRENT_POD}" -c "${MOODLE_EXEC_CONTAINER}" -- sh -c "tail -n 12 ${INSTALL_LOG_PATH} 2>/dev/null || echo '(no installer log yet)'" 2>/dev/null || true
      LAST_LOG_SIZE=${LOG_SIZE}
    fi

    # If no log and no exit for a full minute, installer likely did not start. Relaunch once.
    if (( ELAPSED >= 60 )) && (( LOG_SIZE == 0 )) && [[ -z "${INSTALL_EXIT}" ]] && [[ "${INSTALL_RELAUNCHED}" == "false" ]]; then
      echo "No installer progress detected after ${ELAPSED}s. Relaunching installer once..."
      if exec_with_retry sh -c "nohup sh ${INSTALL_SCRIPT_PATH} >/dev/null 2>&1 &"; then
        INSTALL_RELAUNCHED=true
      fi
    fi

    if [[ $i -eq 60 ]]; then
      echo "Install timeout (15min). Last install log lines:"
      kubectl -n moodle exec "${CURRENT_POD}" -c "${MOODLE_EXEC_CONTAINER}" -- sh -c "tail -n 40 ${INSTALL_LOG_PATH} 2>/dev/null || echo '(no installer log)'" 2>/dev/null || true
      exit 1
    fi
  done
fi

if [[ "${INSTALL_DONE}" != "true" ]]; then
  echo "Install did not complete successfully."
  exit 1
fi

kubectl -n moodle exec "${MOODLE_POD}" -c "${MOODLE_EXEC_CONTAINER}" -- \
  runuser -u www-data -- php admin/cli/cfg.php --name=enabledashboard --set=1 || true

echo
echo "=== Step 6: Configure Redis MUC mappings ==="
if exec_with_retry sh -c 'test -n "${MOODLE_REDIS_HOST:-}"'; then
  if ! exec_with_retry_stdin 'cat > /tmp/configure-redis-muc.php' <<'PHP'
<?php
define('CLI_SCRIPT', true);
require('/var/www/html/config.php');

$host = getenv('MOODLE_REDIS_HOST') ?: '';
$port = getenv('MOODLE_REDIS_PORT') ?: '6379';
if ($host === '') {
    fwrite(STDOUT, "MOODLE_REDIS_HOST is empty, skipping MUC Redis mapping.\n");
    exit(0);
}

$storename = 'redis_app_shared';
$config = [
    'server' => $host . ':' . $port,
    'prefix' => 'moodlecache_',
    'connectiontimeout' => 2,
    'lockwait' => 60,
    'locktimeout' => 600,
];

try {
    $writer = \core_cache\config_writer::instance();
    $stores = $writer->get_all_stores();
    if (!array_key_exists($storename, $stores)) {
        $writer->add_store_instance($storename, 'redis', $config);
        fwrite(STDOUT, "Created Redis cache store instance: {$storename}.\n");
    }

    $writer->set_mode_mappings([
        \core_cache\store::MODE_APPLICATION => [$storename, 'default_application'],
        \core_cache\store::MODE_SESSION => [$storename, 'default_session'],
        \core_cache\store::MODE_REQUEST => ['default_request'],
    ]);
    fwrite(STDOUT, "Mapped application/session cache modes to Redis store: {$storename}.\n");
} catch (Throwable $e) {
    fwrite(STDERR, "Redis MUC setup failed: " . $e->getMessage() . "\n");
    exit(1);
}
PHP
  then
    echo "Failed to stage Redis MUC configurator script."
    exit 1
  fi

  if ! exec_with_retry runuser -u www-data -- php /tmp/configure-redis-muc.php; then
    echo "Failed to apply Redis MUC mappings."
    exit 1
  fi
  exec_with_retry runuser -u www-data -- php admin/cli/purge_caches.php || true
else
  echo "Redis is not enabled in this release; skipping MUC Redis mapping."
fi

echo
echo "=== Setup complete [${WORKSPACE}] ==="
echo ""
echo "Site URL: ${SITE_URL}"
FINAL_LB_IP=$(kubectl -n moodle get svc moodle -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
FINAL_LB_HOST=$(kubectl -n moodle get svc moodle -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
[[ -n "${FINAL_LB_IP}" ]] && echo "DNS: A ${EXTERNAL_DNS_HOSTNAME} -> ${FINAL_LB_IP}"
[[ -n "${FINAL_LB_HOST}" ]] && echo "DNS: CNAME ${EXTERNAL_DNS_HOSTNAME} -> ${FINAL_LB_HOST}"
echo ""
echo "To use kubectl:"
echo "  export KUBECONFIG=${KUBECONFIG_FILE}"
