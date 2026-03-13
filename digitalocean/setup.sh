#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${SCRIPT_DIR}/.env"
  set +a
fi

DO_DIR="${SCRIPT_DIR}/digitalocean"
K8S_YAML="k8s-moodle.yaml"
CLUSTER_KUBECONFIG_OUTPUT_NAME="kubeconfig"

echo "=== Step 0: Check environment and required tools ==="
command -v terraform >/dev/null 2>&1 || { echo "terraform is required"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required"; exit 1; }
command -v envsubst >/dev/null 2>&1 || { echo "envsubst is required (install: apt-get install gettext)"; exit 1; }

if [[ -z "${DO_TOKEN:-}" ]]; then
  echo "DO_TOKEN not set. Set it in .env."
  exit 1
fi
export TF_VAR_do_token="${DO_TOKEN}"

SITE_URL="${MOODLE_WWWROOT:?Set MOODLE_WWWROOT in .env}"
ADMIN_USER="${MOODLE_ADMIN_USER:?Set MOODLE_ADMIN_USER in .env}"
ADMIN_PASS="${MOODLE_ADMIN_PASS:?Set MOODLE_ADMIN_PASS in .env}"
ADMIN_EMAIL="${MOODLE_ADMIN_EMAIL:?Set MOODLE_ADMIN_EMAIL in .env}"
DB_USER="${MOODLE_DB_USER:-moodleuser}"

echo
echo "=== Step 1: Terraform apply in ${DO_DIR} ==="
cd "${DO_DIR}"

if [[ ! -d ".terraform" ]]; then
  echo "Running terraform init..."
  terraform init
fi

echo "Running terraform apply (this may incur cost)..."
export TF_IN_AUTOMATION=1
export TF_LOG=ERROR
terraform apply -auto-approve 2>&1 | grep -v "Still creating" || true
[[ ${PIPESTATUS[0]} -ne 0 ]] && exit "${PIPESTATUS[0]}"

echo "Reading Terraform outputs..."
TF_JSON=$(terraform output -json)
DB_HOST=$(echo "${TF_JSON}" | jq -r '.db_host.value')
DB_PORT=$(echo "${TF_JSON}" | jq -r '.db_port.value')
DB_PASS=$(echo "${TF_JSON}" | jq -r '.db_password.value')
DB_CLUSTER_ID=$(echo "${TF_JSON}" | jq -r '.db_cluster_id.value')

[[ -z "${DB_HOST}" || "${DB_HOST}" == "null" ]] && { echo "Missing db_host output."; exit 1; }
[[ -z "${DB_PORT}" || "${DB_PORT}" == "null" ]] && { echo "Missing db_port output."; exit 1; }
[[ -z "${DB_PASS}" || "${DB_PASS}" == "null" ]] && { echo "Missing db_password output."; exit 1; }
[[ -z "${DB_CLUSTER_ID}" || "${DB_CLUSTER_ID}" == "null" ]] && { echo "Missing db_cluster_id output."; exit 1; }

KUBECONFIG_RAW=$(terraform output -raw "${CLUSTER_KUBECONFIG_OUTPUT_NAME}")
[[ -z "${KUBECONFIG_RAW}" ]] && { echo "Missing kubeconfig output."; exit 1; }

KUBECONFIG_FILE="${DO_DIR}/kubeconfig-do"
printf '%s' "${KUBECONFIG_RAW}" > "${KUBECONFIG_FILE}"
export KUBECONFIG="${KUBECONFIG_FILE}"
echo "Kubeconfig saved to ${KUBECONFIG_FILE}"

echo
echo "=== Step 2: Apply Kubernetes manifests ==="
if [[ ! -f "${K8S_YAML}" ]]; then
  echo "File ${K8S_YAML} not found. Aborting."
  exit 1
fi

export MOODLE_DB_HOST="${DB_HOST}"
export MOODLE_DB_USER="${DB_USER}"
export MOODLE_DB_PASSWORD="${DB_PASS}"
export MOODLE_DB_PORT="${DB_PORT}"
export MOODLE_WWWROOT="${SITE_URL}"

echo "Applying manifests..."
envsubst < "${K8S_YAML}" | kubectl apply -f -

echo
echo "=== Step 2.5: Grant schema public to DB user (required for Moodle install on DO Managed PostgreSQL) ==="
if [[ -z "${DO_DB_ADMIN_PASSWORD:-}" ]]; then
  echo "Fetching doadmin password from DigitalOcean API..."
  DO_ADMIN_RESP=$(curl -sS -H "Authorization: Bearer ${DO_TOKEN}" \
    "https://api.digitalocean.com/v2/databases/${DB_CLUSTER_ID}/users/doadmin" 2>/dev/null || true)
  DO_DB_ADMIN_PASSWORD=$(echo "${DO_ADMIN_RESP}" | jq -r '.user.password // empty' 2>/dev/null || true)
fi
if [[ -n "${DO_DB_ADMIN_PASSWORD:-}" ]]; then
  echo "Running GRANT as doadmin via one-off Job..."
  GRANT_JOB="moodle-db-grant-schema-$(date +%s)"
  kubectl create secret generic do-db-admin-grant --from-literal=PGPASSWORD="${DO_DB_ADMIN_PASSWORD}" --dry-run=client -o yaml | kubectl apply -f -
  GRANT_JOB_YAML=$(mktemp /tmp/moodle-grant-job.XXXXXX.yaml)
  cat <<EOF > "${GRANT_JOB_YAML}"
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
              psql -h ${DB_HOST} -p ${DB_PORT} -U doadmin -d moodle -v ON_ERROR_STOP=1 -c "GRANT ALL ON SCHEMA public TO ${DB_USER};" -c "GRANT CREATE ON SCHEMA public TO ${DB_USER};"
EOF
  kubectl apply -f "${GRANT_JOB_YAML}"
  rm -f "${GRANT_JOB_YAML}"
  echo "Waiting for Job ${GRANT_JOB} to complete..."
  if kubectl wait --for=condition=complete "job/${GRANT_JOB}" --timeout=120s 2>/dev/null; then
    kubectl delete job "${GRANT_JOB}" --ignore-not-found=true
    kubectl delete secret do-db-admin-grant --ignore-not-found=true
    echo "Schema public granted to ${DB_USER}."
  else
    kubectl logs "job/${GRANT_JOB}" 2>/dev/null || true
    kubectl delete job "${GRANT_JOB}" --ignore-not-found=true
    kubectl delete secret do-db-admin-grant --ignore-not-found=true
    echo "Grant job failed. Check DO DB firewall / doadmin password."
    exit 1
  fi
else
  echo "Could not get doadmin password. Moodle install will fail with 'permission denied for schema public'."
  echo "  - Ensure DO_TOKEN has scope database:view_credentials, or set DO_DB_ADMIN_PASSWORD in .env."
  echo "  - Or run as doadmin: GRANT ALL ON SCHEMA public TO ${DB_USER}; GRANT CREATE ON SCHEMA public TO ${DB_USER};"
  exit 1
fi

echo
echo "=== Step 3: Wait for Moodle pod and run database installation ==="
echo "Waiting for Moodle pod to be Running (up to 5 min)..."
MOODLE_POD=""
for i in $(seq 1 60); do
  MOODLE_POD=$(kubectl get pods -l app=moodle -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -n "${MOODLE_POD}" ]]; then
    POD_PHASE=$(kubectl get pod "${MOODLE_POD}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [[ "${POD_PHASE}" == "Running" ]]; then
      echo "Pod ${MOODLE_POD} is Running."
      break
    fi
  fi
  echo "Waiting... (${i}/60)"
  sleep 5
done
if [[ -z "${MOODLE_POD}" ]]; then
  echo "No pod found with label app=moodle. Please check 'kubectl get pods'."
  exit 1
fi

kubectl exec "${MOODLE_POD}" -- chown -R www-data:www-data /var/www/moodledata
kubectl exec "${MOODLE_POD}" -- chmod -R 777 /var/www/moodledata

echo "Running database installation (this takes 5-10 minutes, please wait)..."
MOODLE_INSTALL_LOG=$(mktemp)
if ! kubectl exec "${MOODLE_POD}" -- runuser -u www-data -- php -d display_errors=1 -d log_errors=1 admin/cli/install_database.php \
  --lang=en \
  --adminuser="${ADMIN_USER}" \
  --adminpass="${ADMIN_PASS}" \
  --adminemail="${ADMIN_EMAIL}" \
  --fullname="He thong E-learning HCMUT" \
  --shortname="HCMUT LMS" \
  --agree-license \
  > "${MOODLE_INSTALL_LOG}" 2>&1; then
  echo "Database installation failed."
  echo "--- Lines that may contain the real DB error: ---"
  grep -i -E "SQLSTATE|ERROR|FATAL|cannot|read-only|aborted|permission|denied|refused" "${MOODLE_INSTALL_LOG}" || true
  echo "--- Last 50 lines: ---"
  tail -50 "${MOODLE_INSTALL_LOG}"
  rm -f "${MOODLE_INSTALL_LOG}"
  exit 1
fi
rm -f "${MOODLE_INSTALL_LOG}"
echo "Database installation completed."

# Remove debug settings written during install
kubectl exec "${MOODLE_POD}" -- sed -i '/CFG->debug = E_ALL/d' /var/www/html/config.php || true
kubectl exec "${MOODLE_POD}" -- sed -i '/CFG->debugdisplay = 1/d' /var/www/html/config.php || true

# Enable dashboard
kubectl exec "${MOODLE_POD}" -- runuser -u www-data -- php admin/cli/cfg.php --name=enabledashboard --set=1 || true

echo
echo "=== Step 4: Service information for DNS update ==="
kubectl get svc
echo "Use the EXTERNAL-IP of the moodle-service LoadBalancer to update your DNS (e.g. Cloudflare A record)."

echo
echo "=== DigitalOcean Moodle deployment script finished ==="
echo "Verify pods, services, and access Moodle via the configured domain."
echo ""
echo "To use kubectl with this DigitalOcean cluster:"
echo "  export KUBECONFIG=${DO_DIR}/kubeconfig-do"
echo "To switch back to AWS:"
echo "  unset KUBECONFIG"
echo "  # or: aws eks update-kubeconfig --region <region> --name moodle-cluster"
