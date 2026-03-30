#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${SCRIPT_DIR}/.env"
  set +a
fi

AWS_PROFILE="${AWS_PROFILE:-moodle-aws}"
AWS_REGION="${AWS_REGION:-ap-southeast-1}"
CLUSTER_NAME="moodle-cluster"
K8S_DIR="k8s"

echo "=== Step 0: Check environment and AWS profile ==="
command -v terraform >/dev/null 2>&1 || { echo "terraform is required"; exit 1; }
command -v aws >/dev/null 2>&1 || { echo "awscli is required"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required"; exit 1; }
command -v helm >/dev/null 2>&1 || { echo "helm is required"; exit 1; }

AWS_CONFIG_FILE="${HOME}/.aws/config"
if [[ ! -f "${AWS_CONFIG_FILE}" ]]; then
  echo "AWS config file ${AWS_CONFIG_FILE} not found, creating a new one with profile '${AWS_PROFILE}'."
  mkdir -p "$(dirname "${AWS_CONFIG_FILE}")"
  cat > "${AWS_CONFIG_FILE}" <<EOF
[default]
region = ${AWS_REGION}

[profile ${AWS_PROFILE}]
region = ${AWS_REGION}
EOF
fi

if ! grep -q "^\[profile ${AWS_PROFILE}\]" "${AWS_CONFIG_FILE}"; then
  echo "Profile '${AWS_PROFILE}' not found in ${AWS_CONFIG_FILE}, appending it."
  {
    echo
    echo "[profile ${AWS_PROFILE}]"
    echo "region = ${AWS_REGION}"
  } >> "${AWS_CONFIG_FILE}"
fi

export AWS_PROFILE

echo
echo "=== Step 1: Terraform apply ==="

if [[ ! -d ".terraform" ]]; then
  echo "Running terraform init..."
  terraform init
fi

echo "Running terraform apply..."
export TF_IN_AUTOMATION=1
export TF_LOG=ERROR
terraform apply -auto-approve -var="aws_profile=${AWS_PROFILE}"

echo "Reading Terraform outputs..."
TF_JSON=$(terraform output -json)
EFS_ID=$(echo "${TF_JSON}" | jq -r '.efs_id.value')
EFS_AP_PROD_ID=$(echo "${TF_JSON}" | jq -r '.efs_access_point_prod_id.value')
EFS_AP_STAGING_ID=$(echo "${TF_JSON}" | jq -r '.efs_access_point_staging_id.value')
RDS_ENDPOINT=$(echo "${TF_JSON}" | jq -r '.rds_endpoint.value')
DB_HOST="${RDS_ENDPOINT%%:*}"

echo
echo "=== Step 2: Configure kubectl for EKS cluster ==="
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}"

echo
echo "=== Step 3: Install aws-efs-csi-driver addon ==="
aws eks create-addon \
  --cluster-name "${CLUSTER_NAME}" \
  --addon-name aws-efs-csi-driver \
  --resolve-conflicts OVERWRITE || true

echo
echo "=== Step 4: Install Nginx Ingress Controller ==="
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  -f "${K8S_DIR}/ingress-nginx/values.yaml"

echo
echo "=== Step 4.5: Open port 80/443 on EKS node security group (hostPort) ==="
# Wait briefly for nodes to appear
sleep 10
NODE_SG=$(aws ec2 describe-instances \
  --filters "Name=tag:eks:cluster-name,Values=${CLUSTER_NAME}" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' \
  --output text 2>/dev/null || true)

if [[ -n "${NODE_SG}" && "${NODE_SG}" != "None" ]]; then
  echo "Adding port 80/443 rules to node security group ${NODE_SG}..."
  aws ec2 authorize-security-group-ingress \
    --group-id "${NODE_SG}" \
    --ip-permissions \
      'IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0,Description="HTTP hostPort"}]' \
      'IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0,Description="HTTPS hostPort"}]' \
    2>&1 || echo "Rules may already exist, continuing..."
else
  echo "WARNING: Could not find node security group, add port 80/443 manually."
fi

echo
echo "=== Step 5: Scale CoreDNS down to 1 replica ==="
kubectl -n kube-system scale deployment coredns --replicas=1
kubectl -n kube-system rollout status deployment coredns || true

echo
echo "=== Step 5.1: Metrics Server (required for HPA) ==="
if ! kubectl get deployment metrics-server -n kube-system &>/dev/null; then
  kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
  kubectl -n kube-system rollout status deployment/metrics-server --timeout=120s || true
fi

echo
echo "=== Step 5.2: Prometheus + Adapter (monitoring + custom metrics) ==="

# Grafana Cloud remote_write (optional)
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
    --set "rules.custom[0].seriesQuery=container_network_receive_bytes_total{namespace=\"moodle-production\"}" \
    --set "rules.custom[0].resources.overrides.namespace.resource=namespace" \
    --set "rules.custom[0].resources.overrides.pod.resource=pod" \
    --set "rules.custom[0].name.as=http_requests_per_second" \
    --set "rules.custom[0].metricsQuery=sum(rate(container_network_receive_bytes_total{namespace=\"moodle-production\",container=\"moodle\"}[2m])) by (pod) / 1024" \
    --wait --timeout 3m || echo "Prometheus-adapter install failed, continuing..."
fi

echo
echo "=== Step 5.3: Provision Grafana Cloud dashboards ==="
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
echo "=== Step 6: Deploy Moodle via Helm ==="

export EFS_ID
export EFS_AP_PROD_ID
MOODLE_DB_HOST="${DB_HOST}"
MOODLE_DB_USER="${MOODLE_DB_USER:-moodleuser}"
MOODLE_DB_PASSWORD="${MOODLE_DB_PASS:?Set MOODLE_DB_PASS in .env}"
SIZE_PROFILE="${SIZE_PROFILE:-small}"
HELM_CHART="${SCRIPT_DIR}/helm/moodle"

# Create EFS StorageClass if not exists
kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs-sc
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: "${EFS_ID}"
  directoryPerms: "777"
  uid: "33"
  gid: "33"
mountOptions:
  - tls
EOF

# Deploy production
echo "Deploying production with size profile: ${SIZE_PROFILE}"
helm upgrade --install moodle "${HELM_CHART}" \
  --namespace moodle-production --create-namespace \
  -f "${HELM_CHART}/values-${SIZE_PROFILE}.yaml" \
  --set db.host="${MOODLE_DB_HOST}" \
  --set db.name="${MOODLE_DB_NAME:-moodle}" \
  --set db.user="${MOODLE_DB_USER}" \
  --set db.password="${MOODLE_DB_PASSWORD}" \
  --set db.sslmode="" \
  --set moodle.wwwroot="${MOODLE_WWWROOT:?Set MOODLE_WWWROOT in .env}" \
  --set persistence.storageClass=efs-sc \
  --set ingress.enabled=true \
  --set ingress.host="${MOODLE_WWWROOT#https://}"

# Deploy staging (0 replicas by default)
echo "Deploying staging..."
helm upgrade --install moodle-staging "${HELM_CHART}" \
  --namespace moodle-staging --create-namespace \
  -f "${HELM_CHART}/values-${SIZE_PROFILE}.yaml" \
  --set replicaCount=0 \
  --set db.host="${MOODLE_DB_HOST}" \
  --set db.name="${MOODLE_STAGING_DB_NAME:-moodle_staging}" \
  --set db.user="${MOODLE_DB_USER}" \
  --set db.password="${MOODLE_DB_PASSWORD}" \
  --set db.sslmode="" \
  --set moodle.wwwroot="${MOODLE_STAGING_WWWROOT:?Set MOODLE_STAGING_WWWROOT in .env}" \
  --set persistence.storageClass=efs-sc \
  --set ingress.enabled=true \
  --set ingress.host="${MOODLE_STAGING_WWWROOT#https://}"

echo
echo "=== Step 7: Create staging database ==="
echo "Creating moodle_staging database (if not exists)..."
kubectl run psql-client --rm -i --restart=Never \
  --image=postgres:16-alpine \
  --env="PGPASSWORD=${MOODLE_DB_PASSWORD}" \
  -- psql -h "${DB_HOST}" -U "${MOODLE_DB_USER}" -d moodle \
  -c "SELECT 'CREATE DATABASE moodle_staging OWNER ${MOODLE_DB_USER}' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'moodle_staging')\gexec" \
  || echo "Staging database may already exist, continuing..."

echo
echo "=== Step 8: Wait for production pod and install Moodle ==="

ADMIN_USER="${MOODLE_ADMIN_USER:?Set MOODLE_ADMIN_USER in .env}"
ADMIN_PASS="${MOODLE_ADMIN_PASS:?Set MOODLE_ADMIN_PASS in .env}"
ADMIN_EMAIL="${MOODLE_ADMIN_EMAIL:?Set MOODLE_ADMIN_EMAIL in .env}"

echo "Waiting for production pod to be ready (Helm --wait should have handled this)..."
PROD_POD=$(kubectl -n moodle-production get pods -l app=moodle -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -n "${PROD_POD}" ]]; then
  echo "Setting up moodledata permissions..."
  kubectl -n moodle-production exec "${PROD_POD}" -- chown -R www-data:www-data /var/www/moodledata
  kubectl -n moodle-production exec "${PROD_POD}" -- chmod -R 777 /var/www/moodledata

  echo "Running Moodle database install for production..."
  kubectl -n moodle-production exec "${PROD_POD}" -- runuser -u www-data -- php admin/cli/install_database.php \
    --lang=en \
    --adminuser="${ADMIN_USER}" \
    --adminpass="${ADMIN_PASS}" \
    --adminemail="${ADMIN_EMAIL}" \
    --fullname="He thong E-learning HCMUT" \
    --shortname="HCMUT LMS" \
    --agree-license || echo "Production database may already be installed."

  echo "Enabling Moodle dashboard..."
  kubectl -n moodle-production exec "${PROD_POD}" -- runuser -u www-data -- php admin/cli/cfg.php --name=enabledashboard --set=1 || true
fi

echo
echo "=== Step 9: Setup staging environment ==="
echo "Scaling staging to 1 replica for initial setup..."
kubectl -n moodle-staging scale deployment/moodle-staging --replicas=1

echo "Waiting for staging pod to be ready..."
kubectl -n moodle-staging wait --for=condition=ready pod -l app=moodle --timeout=300s || true

STG_POD=$(kubectl -n moodle-staging get pods -l app=moodle -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -n "${STG_POD}" ]]; then
  kubectl -n moodle-staging exec "${STG_POD}" -- chown -R www-data:www-data /var/www/moodledata
  kubectl -n moodle-staging exec "${STG_POD}" -- chmod -R 777 /var/www/moodledata

  echo "Running Moodle database install for staging..."
  kubectl -n moodle-staging exec "${STG_POD}" -- runuser -u www-data -- php admin/cli/install_database.php \
    --lang=en \
    --adminuser="${ADMIN_USER}" \
    --adminpass="${ADMIN_PASS}" \
    --adminemail="${ADMIN_EMAIL}" \
    --fullname="He thong E-learning HCMUT (Staging)" \
    --shortname="HCMUT LMS STG" \
    --agree-license || echo "Staging database may already be installed."
fi

echo "Scaling staging back to 0 (on-demand)..."
kubectl -n moodle-staging scale deployment/moodle-staging --replicas=0

echo
echo "=== Step 10: Service information for Cloudflare DNS ==="
echo
NODE_IPS=$(aws ec2 describe-instances \
  --filters "Name=tag:eks:cluster-name,Values=${CLUSTER_NAME}" "Name=instance-state-name,Values=running" \
  --query 'Reservations[*].Instances[*].PublicIpAddress' \
  --output text 2>/dev/null || true)

echo "Node public IPs:"
for IP in ${NODE_IPS}; do
  echo "  ${IP}"
done
echo
echo "Configure Cloudflare DNS (Type=A, both Proxied):"
for IP in ${NODE_IPS}; do
  echo "  A  lms          -> ${IP}  (Proxied)"
  echo "  A  staging-lms  -> ${IP}  (Proxied)"
done
echo
echo "=== AWS Moodle multi-environment deployment finished ==="
echo "Production: https://lms.ndcuong.online"
echo "Staging:    https://staging-lms.ndcuong.online (scale up via CI/CD or: kubectl -n moodle-staging scale deployment/moodle --replicas=1)"
