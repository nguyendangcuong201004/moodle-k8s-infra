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
K8S_DIR="${DO_DIR}/k8s"

echo "=== Step 0: Check environment and required tools ==="
command -v terraform >/dev/null 2>&1 || { echo "terraform is required"; exit 1; }
command -v kubectl   >/dev/null 2>&1 || { echo "kubectl is required"; exit 1; }
command -v helm      >/dev/null 2>&1 || { echo "helm is required (https://helm.sh/docs/intro/install/)"; exit 1; }
command -v jq        >/dev/null 2>&1 || { echo "jq is required"; exit 1; }
command -v envsubst  >/dev/null 2>&1 || { echo "envsubst is required (apt-get install gettext)"; exit 1; }

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
  MOODLE_PVC_SIZE="20Gi"
else
  SITE_URL="${MOODLE_STAGING_WWWROOT:?Set MOODLE_STAGING_WWWROOT in .env}"
  MOODLE_PVC_SIZE="5Gi"
fi

# Derive ingress host from URL (strip https:// or http://)
INGRESS_HOST="${SITE_URL#https://}"
INGRESS_HOST="${INGRESS_HOST#http://}"

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

echo "Reading Terraform outputs..."
TF_JSON=$(terraform output -json)
DB_HOST=$(echo "${TF_JSON}"       | jq -r '.db_host.value')
DB_PORT=$(echo "${TF_JSON}"       | jq -r '.db_port.value')
DB_PASS=$(echo "${TF_JSON}"       | jq -r '.db_password.value')
DB_USER=$(echo "${TF_JSON}"       | jq -r '.db_user.value')
DB_NAME=$(echo "${TF_JSON}"       | jq -r '.db_name.value')
DB_CLUSTER_ID=$(echo "${TF_JSON}" | jq -r '.db_cluster_id.value')

[[ -z "${DB_HOST}" || "${DB_HOST}" == "null" ]]        && { echo "Missing db_host output.";       exit 1; }
[[ -z "${DB_PASS}" || "${DB_PASS}" == "null" ]]        && { echo "Missing db_password output.";   exit 1; }
[[ -z "${DB_CLUSTER_ID}" || "${DB_CLUSTER_ID}" == "null" ]] && { echo "Missing db_cluster_id output."; exit 1; }

KUBECONFIG_RAW=$(terraform output -raw kubeconfig)
KUBECONFIG_FILE="${DO_DIR}/kubeconfig-${WORKSPACE}"
printf '%s' "${KUBECONFIG_RAW}" > "${KUBECONFIG_FILE}"
export KUBECONFIG="${KUBECONFIG_FILE}"
echo "Kubeconfig saved to ${KUBECONFIG_FILE}"

echo
echo "=== Step 2: Install Nginx Ingress Controller ==="
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo update ingress-nginx 2>/dev/null || true

kubectl create namespace ingress-nginx --dry-run=client -o yaml | kubectl apply -f -

# Render values.yaml with WORKSPACE env var
INGRESS_VALUES_RENDERED=$(mktemp /tmp/ingress-values.XXXXXX.yaml)
export WORKSPACE
envsubst < "${K8S_DIR}/ingress-nginx/values.yaml" > "${INGRESS_VALUES_RENDERED}"

if helm -n ingress-nginx status ingress-nginx &>/dev/null; then
  echo "Nginx Ingress already installed, upgrading..."
  helm upgrade ingress-nginx ingress-nginx/ingress-nginx \
    -n ingress-nginx \
    -f "${INGRESS_VALUES_RENDERED}"
else
  echo "Installing Nginx Ingress Controller..."
  helm install ingress-nginx ingress-nginx/ingress-nginx \
    -n ingress-nginx \
    -f "${INGRESS_VALUES_RENDERED}"
fi
rm -f "${INGRESS_VALUES_RENDERED}"

echo "Waiting for Nginx Ingress LoadBalancer IP (up to 5 min)..."
NGINX_LB_IP=""
for i in $(seq 1 30); do
  NGINX_LB_IP=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [[ -n "${NGINX_LB_IP}" ]]; then
    echo "Nginx LB IP: ${NGINX_LB_IP}"
    break
  fi
  echo "Waiting... (${i}/30)"
  sleep 10
done
[[ -z "${NGINX_LB_IP}" ]] && { echo "Could not get Nginx LB IP. Check 'kubectl -n ingress-nginx get svc'."; exit 1; }

echo
echo "=== Step 3: Apply Moodle manifests ==="
export MOODLE_DB_HOST="${DB_HOST}"
export MOODLE_DB_PORT="${DB_PORT}"
export MOODLE_DB_NAME="${DB_NAME}"
export MOODLE_DB_USER="${DB_USER}"
export MOODLE_DB_PASSWORD="${DB_PASS}"
export MOODLE_WWWROOT="${SITE_URL}"
export MOODLE_INGRESS_HOST="${INGRESS_HOST}"
export MOODLE_PVC_SIZE

envsubst < "${K8S_DIR}/moodle.yaml" | kubectl apply -f -

echo
echo "=== Step 4: GRANT schema public to DB user ==="
doadmin_pass="${DO_DB_ADMIN_PASSWORD:-}"
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

echo "Waiting for GRANT job ${GRANT_JOB}..."
if kubectl wait --for=condition=complete "job/${GRANT_JOB}" --timeout=120s 2>/dev/null; then
  kubectl delete job "${GRANT_JOB}" --ignore-not-found=true
  kubectl delete secret do-db-admin-grant --ignore-not-found=true
  echo "GRANT done."
else
  kubectl logs "job/${GRANT_JOB}" 2>/dev/null || true
  kubectl delete job "${GRANT_JOB}" --ignore-not-found=true
  kubectl delete secret do-db-admin-grant --ignore-not-found=true
  echo "GRANT failed. Run manually: GRANT ALL ON SCHEMA public TO ${DB_USER};"
  exit 1
fi

echo
echo "=== Step 5: Wait for Moodle pod and install database ==="
echo "Waiting for Moodle pod to be Running (up to 5 min)..."
MOODLE_POD=""
for i in $(seq 1 60); do
  MOODLE_POD=$(kubectl get pods -l app=moodle \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -n "${MOODLE_POD}" ]]; then
    POD_PHASE=$(kubectl get pod "${MOODLE_POD}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || true)
    [[ "${POD_PHASE}" == "Running" ]] && { echo "Pod ${MOODLE_POD} is Running."; break; }
  fi
  echo "Waiting... (${i}/60)"
  sleep 5
done
[[ -z "${MOODLE_POD}" ]] && { echo "Pod not found. Check 'kubectl get pods'."; exit 1; }

kubectl exec "${MOODLE_POD}" -- chown -R www-data:www-data /var/www/moodledata
kubectl exec "${MOODLE_POD}" -- chmod -R 777 /var/www/moodledata

echo "Running database installation (5-10 min, please wait)..."
INSTALL_LOG=$(mktemp)
if kubectl exec "${MOODLE_POD}" -- \
    runuser -u www-data -- php admin/cli/install_database.php \
      --lang=en \
      --adminuser="${ADMIN_USER}" \
      --adminpass="${ADMIN_PASS}" \
      --adminemail="${ADMIN_EMAIL}" \
      --fullname="He thong E-learning HCMUT" \
      --shortname="HCMUT LMS" \
      --agree-license \
    > "${INSTALL_LOG}" 2>&1; then
  echo "Database installed successfully."
  kubectl exec "${MOODLE_POD}" -- \
    runuser -u www-data -- php admin/cli/cfg.php --name=enabledashboard --set=1 || true
elif grep -qi "already installed\|table.*exist\|Tables already exist" "${INSTALL_LOG}"; then
  echo "Database already installed, skipping."
else
  echo "Database installation FAILED."
  grep -i -E "SQLSTATE|ERROR|FATAL|cannot|permission|denied" "${INSTALL_LOG}" || true
  tail -30 "${INSTALL_LOG}"
  rm -f "${INSTALL_LOG}"
  exit 1
fi
rm -f "${INSTALL_LOG}"

echo
echo "=== Setup complete [${WORKSPACE}] ==="
echo ""
echo "Nginx Ingress IP: ${NGINX_LB_IP}"
echo "Site URL:         ${SITE_URL}"
echo ""
echo "Update Cloudflare DNS:"
echo "  A  ${INGRESS_HOST}  ${NGINX_LB_IP}  (Proxied)"
echo ""
echo "To use kubectl:"
echo "  export KUBECONFIG=${KUBECONFIG_FILE}"
