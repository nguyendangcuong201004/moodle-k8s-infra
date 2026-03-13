#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${SCRIPT_DIR}/.env"
  set +a
fi

AWS_PROFILE="${AWS_PROFILE:-devops}"
AWS_REGION="${AWS_REGION:-ap-southeast-1}"
AWS_ROLE_ARN="${AWS_ROLE_ARN:-}"
CLUSTER_NAME="moodle-cluster"
K8S_DIR="k8s"

echo "=== Step 0: Check environment and AWS profile ==="
command -v terraform >/dev/null 2>&1 || { echo "terraform is required"; exit 1; }
command -v aws >/dev/null 2>&1 || { echo "awscli is required"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required"; exit 1; }
command -v envsubst >/dev/null 2>&1 || { echo "envsubst is required (usually from gettext)"; exit 1; }
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

if [[ -n "${AWS_ROLE_ARN}" ]]; then
  echo "Ensuring role_arn is set for profile '${AWS_PROFILE}' using AWS_ROLE_ARN from .env."
  if ! awk "/^\[profile ${AWS_PROFILE}\]/ {found=1} found && /role_arn/ {print; exit}" "${AWS_CONFIG_FILE}" >/dev/null 2>&1; then
    {
      echo
      echo "# Added by moodle-k8s-infra aws/setup.sh"
      echo "[profile ${AWS_PROFILE}]"
      echo "role_arn = ${AWS_ROLE_ARN}"
      echo "source_profile = default"
    } >> "${AWS_CONFIG_FILE}"
  fi
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
terraform apply -auto-approve

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
echo "=== Step 5: Scale CoreDNS down to 1 replica ==="
kubectl -n kube-system scale deployment coredns --replicas=1
kubectl -n kube-system rollout status deployment coredns || true

echo
echo "=== Step 6: Apply Kubernetes manifests ==="

# Prepare environment variables for envsubst
export EFS_ID
export EFS_AP_PROD_ID
export EFS_AP_STAGING_ID
export MOODLE_DB_HOST="${DB_HOST}"
export MOODLE_DB_NAME="${MOODLE_DB_NAME:-moodle}"
export MOODLE_DB_USER="${MOODLE_DB_USER:-moodleuser}"
export MOODLE_DB_PASSWORD="${MOODLE_DB_PASS:?Set MOODLE_DB_PASS in .env}"
export MOODLE_IMAGE_TAG="${MOODLE_IMAGE_TAG:-latest}"

# Apply namespaces
echo "Creating namespaces..."
kubectl apply -f "${K8S_DIR}/base/"

# Apply production manifests
echo "Applying production manifests..."
for f in "${K8S_DIR}/production/"*.yaml; do
  envsubst < "$f" | kubectl apply -f -
done

# Apply staging manifests
echo "Applying staging manifests..."
for f in "${K8S_DIR}/staging/"*.yaml; do
  envsubst < "$f" | kubectl apply -f -
done

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

echo "Waiting for production pod to be ready..."
kubectl -n moodle-production wait --for=condition=ready pod -l app=moodle --timeout=300s || true

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
fi

echo
echo "=== Step 9: Setup staging environment ==="
echo "Scaling staging to 1 replica for initial setup..."
kubectl -n moodle-staging scale deployment/moodle --replicas=1

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
kubectl -n moodle-staging scale deployment/moodle --replicas=0

echo
echo "=== Step 10: Service information for Cloudflare DNS ==="
echo
echo "Nginx Ingress Controller LoadBalancer:"
INGRESS_LB=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "PENDING")
echo "  LoadBalancer hostname: ${INGRESS_LB}"
echo
echo "Configure Cloudflare DNS:"
echo "  CNAME  lms          -> ${INGRESS_LB}  (Proxied)"
echo "  CNAME  staging-lms  -> ${INGRESS_LB}  (Proxied)"
echo
echo "=== AWS Moodle multi-environment deployment finished ==="
echo "Production: https://lms.ndcuong.online"
echo "Staging:    https://staging-lms.ndcuong.online (scale up via CI/CD or: kubectl -n moodle-staging scale deployment/moodle --replicas=1)"
