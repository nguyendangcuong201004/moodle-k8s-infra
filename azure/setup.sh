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

AZURE_DIR="${SCRIPT_DIR}/azure"

echo "=== Step 0: Check environment and required tools ==="
command -v terraform >/dev/null 2>&1 || { echo "terraform is required"; exit 1; }
command -v az        >/dev/null 2>&1 || { echo "az CLI is required (https://docs.microsoft.com/en-us/cli/azure/install-azure-cli)"; exit 1; }
command -v kubectl   >/dev/null 2>&1 || { echo "kubectl is required"; exit 1; }
command -v helm      >/dev/null 2>&1 || { echo "helm is required (https://helm.sh/docs/intro/install/)"; exit 1; }
command -v jq        >/dev/null 2>&1 || { echo "jq is required"; exit 1; }

if [[ -z "${AZURE_SUBSCRIPTION_ID:-}" ]]; then
  echo "AZURE_SUBSCRIPTION_ID not set. Set it in .env."
  exit 1
fi
export TF_VAR_azure_subscription_id="${AZURE_SUBSCRIPTION_ID}"

# Verify Azure login
if ! az account show &>/dev/null; then
  echo "Not logged in to Azure. Running 'az login'..."
  az login
fi
az account set --subscription "${AZURE_SUBSCRIPTION_ID}"

ADMIN_USER="${MOODLE_ADMIN_USER:?Set MOODLE_ADMIN_USER in .env}"
ADMIN_PASS="${MOODLE_ADMIN_PASS:?Set MOODLE_ADMIN_PASS in .env}"
ADMIN_EMAIL="${MOODLE_ADMIN_EMAIL:?Set MOODLE_ADMIN_EMAIL in .env}"

# Determine site URL based on workspace
if [[ "${WORKSPACE}" == "production" ]]; then
  SITE_URL="${MOODLE_WWWROOT:?Set MOODLE_WWWROOT in .env}"
else
  SITE_URL="${MOODLE_STAGING_WWWROOT:?Set MOODLE_STAGING_WWWROOT in .env}"
fi

# Derive ingress host from URL (strip https:// or http://)
INGRESS_HOST="${SITE_URL#https://}"
INGRESS_HOST="${INGRESS_HOST#http://}"

echo
echo "=== Step 1: Terraform workspace + apply [workspace: ${WORKSPACE}] ==="
cd "${AZURE_DIR}"

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

echo "Running terraform apply (this may take 10-15 minutes)..."
export TF_IN_AUTOMATION=1
export TF_LOG=ERROR
terraform apply -auto-approve 2>&1 | grep -v "Still creating" || true
[[ ${PIPESTATUS[0]} -ne 0 ]] && exit "${PIPESTATUS[0]}"

TF_JSON=$(terraform output -json)
DB_HOST=$(echo "${TF_JSON}"  | jq -r '.db_host.value')
DB_PORT=$(echo "${TF_JSON}"  | jq -r '.db_port.value')
DB_PASS=$(echo "${TF_JSON}"  | jq -r '.db_password.value')
DB_USER=$(echo "${TF_JSON}"  | jq -r '.db_user.value // empty')
DB_NAME=$(echo "${TF_JSON}"  | jq -r '.db_name.value')
CLUSTER_NAME=$(echo "${TF_JSON}" | jq -r '.cluster_name.value')
RG_NAME=$(echo "${TF_JSON}"     | jq -r '.resource_group_name.value')
[[ -z "${DB_USER}" || "${DB_USER}" == "null" ]] && DB_USER="moodleuser"

[[ -z "${DB_HOST}" || "${DB_HOST}" == "null" ]] && { echo "Missing db_host output.";     exit 1; }
[[ -z "${DB_PASS}" || "${DB_PASS}" == "null" ]] && { echo "Missing db_password output."; exit 1; }

KUBECONFIG_RAW=$(terraform output -raw kubeconfig)
[[ -z "${KUBECONFIG_RAW}" ]] && { echo "Missing kubeconfig output."; exit 1; }
KUBECONFIG_FILE="${AZURE_DIR}/kubeconfig-${WORKSPACE}"
printf '%s' "${KUBECONFIG_RAW}" > "${KUBECONFIG_FILE}"
export KUBECONFIG="${KUBECONFIG_FILE}"

echo
echo "=== Step 2: Ingress Nginx (LoadBalancer) ==="
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo update

if ! helm list -n ingress-nginx -q 2>/dev/null | grep -q '^ingress-nginx$'; then
  helm install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx --create-namespace \
    --set controller.service.type=LoadBalancer \
    --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz \
    --wait --timeout 5m
fi

# Wait for LoadBalancer external IP
echo "Waiting for LoadBalancer external IP..."
for i in $(seq 1 30); do
  LB_IP=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [[ -n "${LB_IP}" ]]; then
    echo "LoadBalancer IP: ${LB_IP}"
    break
  fi
  [[ $i -eq 30 ]] && { echo "LoadBalancer IP not assigned in 150s. Check: kubectl -n ingress-nginx get svc"; exit 1; }
  sleep 5
done

echo
echo "=== Step 3: Metrics Server ==="
# AKS pre-installs metrics-server; verify it's running
if kubectl get deployment metrics-server -n kube-system &>/dev/null; then
  echo "Metrics server already installed (AKS default)."
else
  echo "Installing metrics-server..."
  kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
  kubectl -n kube-system rollout status deployment/metrics-server --timeout=120s || true
fi

echo
echo "=== Step 4: Prometheus + Adapter (custom metrics for HPA) ==="
# Grafana Cloud remote_write (optional — set GRAFANA_CLOUD_API_KEY in .env)
GRAFANA_REMOTE_WRITE_ARGS=""
if [[ -n "${GRAFANA_CLOUD_API_KEY:-}" ]]; then
  echo "Grafana Cloud integration enabled — configuring remote_write..."
  [[ -z "${GRAFANA_CLOUD_PROM_URL:-}" ]] && { echo "GRAFANA_CLOUD_PROM_URL required"; exit 1; }
  [[ -z "${GRAFANA_CLOUD_PROM_USERNAME:-}" ]] && { echo "GRAFANA_CLOUD_PROM_USERNAME required"; exit 1; }
  kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret generic grafana-cloud-credentials \
    --namespace monitoring \
    --from-literal=username="${GRAFANA_CLOUD_PROM_USERNAME}" \
    --from-literal=password="${GRAFANA_CLOUD_API_KEY}" \
    --dry-run=client -o yaml | kubectl apply -f -
  GRAFANA_REMOTE_WRITE_ARGS="\
    --set prometheus.prometheusSpec.remoteWrite[0].url=${GRAFANA_CLOUD_PROM_URL} \
    --set prometheus.prometheusSpec.remoteWrite[0].basicAuth.username.name=grafana-cloud-credentials \
    --set prometheus.prometheusSpec.remoteWrite[0].basicAuth.username.key=username \
    --set prometheus.prometheusSpec.remoteWrite[0].basicAuth.password.name=grafana-cloud-credentials \
    --set prometheus.prometheusSpec.remoteWrite[0].basicAuth.password.key=password"
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
echo "=== Step 4.5: Provision Grafana Cloud dashboards ==="
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
echo "=== Step 5: Deploy Moodle via Helm ==="
HELM_CHART="${SCRIPT_DIR}/helm/moodle"
[[ ! -d "${HELM_CHART}" ]] && { echo "Helm chart not found at ${HELM_CHART}"; exit 1; }

echo "Deploying with unified high-capacity profile (values.yaml)"
helm upgrade --install moodle "${HELM_CHART}" \
  --namespace moodle --create-namespace \
  -f "${HELM_CHART}/values.yaml" \
  --set db.host="${DB_HOST}" \
  --set db.port="${DB_PORT}" \
  --set db.name="${DB_NAME}" \
  --set db.user="${DB_USER}" \
  --set db.password="${DB_PASS}" \
  --set db.sslmode="" \
  --set moodle.wwwroot="${SITE_URL}" \
  --set persistence.storageClass=azurefile-csi \
  --set ingress.enabled=true \
  --set ingress.host="${INGRESS_HOST}"

echo
echo "=== Step 6: Wait for Moodle pods ==="
for i in $(seq 1 60); do
  MOODLE_POD=$(kubectl -n moodle get pods -l app=moodle -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -n "${MOODLE_POD}" ]]; then
    POD_PHASE=$(kubectl -n moodle get pod "${MOODLE_POD}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [[ "${POD_PHASE}" == "Running" ]]; then
      echo "Pod ${MOODLE_POD} is Running."
      break
    fi
  fi
  [[ $i -eq 60 ]] && { echo "Moodle pod not Running in 300s. Check: kubectl -n moodle get pods"; exit 1; }
  sleep 5
done

echo
echo "=== Step 7: moodledata permissions and install_database.php ==="
MOODLE_POD=$(kubectl -n moodle get pods -l app=moodle --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -z "${MOODLE_POD}" ]]; then
  echo "No Running Moodle pod. Check: kubectl -n moodle logs deployment/moodle --tail=100"
  exit 1
fi

if ! kubectl -n moodle exec "${MOODLE_POD}" -- chown -R www-data:www-data /var/www/moodledata; then
  echo "chown failed. Check: kubectl logs deployment/moodle --tail=80"
  exit 1
fi
kubectl -n moodle exec "${MOODLE_POD}" -- chmod -R 777 /var/www/moodledata

echo "Running database installation in background (5-10 min, please wait)..."
kubectl -n moodle exec -i "${MOODLE_POD}" -- bash -c 'cat > /tmp/moodle-install.sh && chmod +x /tmp/moodle-install.sh' << EOF
#!/bin/bash
exec > /tmp/install.log 2>&1
cd /var/www/html
rm -f /tmp/install.exit
runuser -u www-data -- php -d display_errors=1 admin/cli/install_database.php \
  --lang=en \
  --adminuser="${ADMIN_USER}" \
  --adminpass="${ADMIN_PASS}" \
  --adminemail="${ADMIN_EMAIL}" \
  --fullname="HCMUT E-learning" \
  --shortname="HCMUT LMS" \
  --agree-license
echo \$? > /tmp/install.exit
EOF

kubectl -n moodle exec "${MOODLE_POD}" -- bash -c "nohup /tmp/moodle-install.sh >/dev/null 2>&1 & disown"

# Poll for DB install completion (max 15 min)
for i in $(seq 1 60); do
  sleep 15
  CURRENT_POD=$(kubectl -n moodle get pods -l app=moodle --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "${MOODLE_POD}")
  DB_VERSION=$(kubectl -n moodle exec "${CURRENT_POD}" -- runuser -u www-data -- php admin/cli/cfg.php --name=version 2>/dev/null || echo "")
  if [[ "${DB_VERSION}" =~ ^[0-9] ]]; then
    echo "Database installed successfully (version: ${DB_VERSION})."
    break
  fi
  echo "[$(( i * 15 ))s] Installing..."
  [[ $i -eq 60 ]] && { echo "Install timeout (15min). Check: kubectl -n moodle exec ${CURRENT_POD} -- cat /tmp/install.log"; exit 1; }
done

kubectl -n moodle exec "${MOODLE_POD}" -- \
  runuser -u www-data -- php admin/cli/cfg.php --name=enabledashboard --set=1 || true

echo
echo "=== Setup complete [${WORKSPACE}] ==="
echo ""
echo "Site URL: ${SITE_URL}"
echo "LoadBalancer IP: ${LB_IP}"
echo ""
echo "DNS: Add A record in Cloudflare:"
echo "  ${INGRESS_HOST} -> ${LB_IP} (Proxied, orange cloud)"
echo "  SSL/TLS: Flexible"
echo ""
echo "Login: ${ADMIN_USER} / ${ADMIN_PASS}"
echo ""
echo "To use kubectl:"
echo "  export KUBECONFIG=${KUBECONFIG_FILE}"
