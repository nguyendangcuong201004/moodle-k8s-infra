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

echo "=== Step 0: Prerequisites ==="
command -v terraform >/dev/null 2>&1 || { echo "terraform required"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "kubectl required"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 1; }

if [[ -z "${DO_TOKEN:-}" ]]; then
  echo "DO_TOKEN not set. Set it in .env."
  exit 1
fi
export TF_VAR_do_token="${DO_TOKEN}"

SITE_URL="${MOODLE_WWWROOT:?Set MOODLE_WWWROOT in .env}"
EXTERNAL_DNS_HOSTNAME="${SITE_URL#*://}"
EXTERNAL_DNS_HOSTNAME="${EXTERNAL_DNS_HOSTNAME%%/*}"
ADMIN_USER="${MOODLE_ADMIN_USER:?Set MOODLE_ADMIN_USER in .env}"
ADMIN_PASS="${MOODLE_ADMIN_PASS:?Set MOODLE_ADMIN_PASS in .env}"
ADMIN_EMAIL="${MOODLE_ADMIN_EMAIL:?Set MOODLE_ADMIN_EMAIL in .env}"
DB_USER="${MOODLE_DB_USER:-moodleuser}"

echo
echo "=== Step 1: Terraform apply in ${DO_DIR} ==="
cd "${DO_DIR}"

terraform init -upgrade
export TF_IN_AUTOMATION=1
export TF_LOG=ERROR
terraform apply -auto-approve 2>&1 | grep -v "Still creating" || true
[[ ${PIPESTATUS[0]} -ne 0 ]] && exit "${PIPESTATUS[0]}"

TF_JSON=$(terraform output -json)
DB_HOST=$(echo "${TF_JSON}" | jq -r '.db_host.value')
DB_PORT=$(echo "${TF_JSON}" | jq -r '.db_port.value')
DB_PASS=$(echo "${TF_JSON}" | jq -r '.db_password.value')
DB_CLUSTER_ID=$(echo "${TF_JSON}" | jq -r '.db_cluster_id.value')

[[ -z "${DB_HOST}" || "${DB_HOST}" == "null" ]] && { echo "Missing db_host output."; exit 1; }
[[ -z "${DB_PORT}" || "${DB_PORT}" == "null" ]] && { echo "Missing db_port output."; exit 1; }
[[ -z "${DB_PASS}" || "${DB_PASS}" == "null" ]] && { echo "Missing db_password output."; exit 1; }
[[ -z "${DB_CLUSTER_ID}" || "${DB_CLUSTER_ID}" == "null" ]] && { echo "Missing db_cluster_id output."; exit 1; }

LB_NAME=$(echo "${TF_JSON}" | jq -r '.lb_name.value')
[[ -z "${LB_NAME}" || "${LB_NAME}" == "null" ]] && { echo "Missing lb_name output."; exit 1; }

KUBECONFIG_RAW=$(terraform output -raw "${CLUSTER_KUBECONFIG_OUTPUT_NAME}")
[[ -z "${KUBECONFIG_RAW}" ]] && { echo "Missing kubeconfig output."; exit 1; }

KUBECONFIG_FILE="${DO_DIR}/kubeconfig-do"
printf '%s' "${KUBECONFIG_RAW}" > "${KUBECONFIG_FILE}"
export KUBECONFIG="${KUBECONFIG_FILE}"

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
echo "=== Step 2: ConfigMap and manifests ==="
[[ ! -f "${K8S_YAML}" ]] && { echo "${K8S_YAML} not found."; exit 1; }

TMP_CONFIG="$(mktemp /tmp/moodle-config.php.XXXXXX)"
cat > "${TMP_CONFIG}" <<CONFIG_EOF
<?php
unset(\$CFG);
global \$CFG;
\$CFG = new stdClass();

\$CFG->dbtype    = 'pgsql';
\$CFG->dblibrary = 'native';
\$CFG->dbhost    = '${DB_HOST}';
\$CFG->dbname    = 'moodle';
\$CFG->dbuser    = '${DB_USER}';
\$CFG->dbpass    = '${DB_PASS}';
\$CFG->prefix    = 'mdl_';
\$CFG->dboptions = array (
  'dbpersist' => 0,
  'dbport' => '${DB_PORT}',
  'dbsocket' => '',
  'sslmode' => 'require',
  'connect_timeout' => 30,
);

\$CFG->wwwroot   = '${SITE_URL}';
\$CFG->sslproxy  = true;
\$CFG->dataroot  = '/var/www/moodledata';
\$CFG->admin     = '${ADMIN_USER}';
\$CFG->directorypermissions = 02777;

\$CFG->themedesignermode = 0;
\$CFG->cachejs = 1;

\$CFG->debug = E_ALL | E_STRICT;
\$CFG->debugdisplay = 1;

require_once(__DIR__ . '/lib/setup.php');
CONFIG_EOF
kubectl create configmap moodle-config --from-file=config.php="${TMP_CONFIG}" --dry-run=client -o yaml | kubectl apply -f -
rm -f "${TMP_CONFIG}"

echo "Applying manifests..."
sed -e "s/REPLACE_WITH_DO_DB_HOST/${DB_HOST}/g" \
    -e "s/REPLACE_WITH_DO_DB_PASSWORD/${DB_PASS}/g" \
    -e "s/DO_LOADBALANCER_NAME_PLACEHOLDER/${LB_NAME}/g" \
    -e "s/EXTERNAL_DNS_HOSTNAME_PLACEHOLDER/${EXTERNAL_DNS_HOSTNAME}/g" \
    "${K8S_YAML}" | kubectl apply -f -

status=""
for _ in $(seq 1 36); do
  status=$(kubectl get pvc moodle-data-pvc -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [[ "${status}" == "Bound" ]] && break
  sleep 5
done
if [[ "${status:-}" != "Bound" ]]; then
  echo "PVC not Bound in 180s. Check: kubectl get pvc moodle-data-pvc; kubectl -n longhorn-system get pods"
  exit 1
fi
sleep 30

echo
echo "=== ExternalDNS ==="
# Script only deploys External-DNS; the pod calls Cloudflare API to create/update DNS. On failure: kubectl logs -n external-dns deployment/external-dns
if [[ -n "${CF_API_TOKEN:-}" ]] && [[ -f "external-dns-cloudflare.yaml" ]]; then
  kubectl create namespace external-dns --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret generic cloudflare-external-dns-api \
    --from-literal=CF_API_TOKEN="${CF_API_TOKEN}" \
    -n external-dns \
    --dry-run=client -o yaml | kubectl apply -f -
  sed "s/EXTERNAL_DNS_DOMAIN_PLACEHOLDER/${EXTERNAL_DNS_HOSTNAME}/g" external-dns-cloudflare.yaml | kubectl apply -f -
  kubectl rollout restart deployment/external-dns -n external-dns 2>/dev/null || true
fi

if [[ -f "hpa-moodle.yaml" ]]; then
  kubectl apply -f "hpa-moodle.yaml" || true
fi

echo
echo "=== Step 2.5: Grant schema to DB user ==="
if [[ -z "${DO_DB_ADMIN_PASSWORD:-}" ]]; then
  DO_ADMIN_RESP=$(curl -sS -H "Authorization: Bearer ${DO_TOKEN}" \
    "https://api.digitalocean.com/v2/databases/${DB_CLUSTER_ID}/users/doadmin" 2>/dev/null || true)
  DO_DB_ADMIN_PASSWORD=$(echo "${DO_ADMIN_RESP}" | jq -r '.user.password // empty' 2>/dev/null || true)
fi
if [[ -n "${DO_DB_ADMIN_PASSWORD:-}" ]]; then
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
  if ! kubectl wait --for=condition=complete "job/${GRANT_JOB}" --timeout=120s 2>/dev/null; then
    kubectl logs "job/${GRANT_JOB}" 2>/dev/null || true
    kubectl delete job "${GRANT_JOB}" --ignore-not-found=true
    kubectl delete secret do-db-admin-grant --ignore-not-found=true
    echo "Grant job failed. Set DO_DB_ADMIN_PASSWORD in .env or run as doadmin: GRANT ALL ON SCHEMA public TO ${DB_USER}; GRANT CREATE ON SCHEMA public TO ${DB_USER};"
    exit 1
  fi
  kubectl delete job "${GRANT_JOB}" --ignore-not-found=true
  kubectl delete secret do-db-admin-grant --ignore-not-found=true
else
  echo "Could not get doadmin password. Set DO_DB_ADMIN_PASSWORD in .env or run GRANT as doadmin manually."
  exit 1
fi

echo
echo "=== Step 3: Wait for Moodle pods ==="
if ! kubectl wait --for=condition=Ready pod -l app=moodle --timeout=600s >/dev/null 2>&1; then
  echo "Moodle pod not Ready in 600s. Check: kubectl get pods; kubectl describe pvc moodle-data-pvc"
  exit 1
fi

MOODLE_POD=$(kubectl get pods -l app=moodle -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[[ -z "${MOODLE_POD}" ]] && { echo "No pod with label app=moodle."; exit 1; }

echo
echo "=== Step 4: Services ==="
kubectl get svc
LB_IP=$(kubectl get svc moodle-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
LB_HOST=$(kubectl get svc moodle-service -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
if [[ -n "${LB_IP}" ]]; then
  echo "DNS: Add A record ${EXTERNAL_DNS_HOSTNAME} -> ${LB_IP}"
elif [[ -n "${LB_HOST}" ]]; then
  echo "DNS: Add CNAME ${EXTERNAL_DNS_HOSTNAME} -> ${LB_HOST}"
fi

echo
echo "=== Step 5: moodledata permissions and install_database.php ==="
MOODLE_POD=$(kubectl get pods -l app=moodle --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -z "${MOODLE_POD}" ]]; then
  echo "No Running Moodle pod. Check: kubectl logs deployment/moodle --tail=100"
  exit 1
fi

if ! kubectl exec "${MOODLE_POD}" -- chown -R www-data:www-data /var/www/moodledata; then
  echo "chown failed. Check: kubectl logs deployment/moodle --tail=80"
  exit 1
fi
kubectl exec "${MOODLE_POD}" -- chmod -R 777 /var/www/moodledata

MOODLE_INSTALL_LOG=$(mktemp)
if ! kubectl exec "${MOODLE_POD}" -- runuser -u www-data -- php -d display_errors=1 -d log_errors=1 admin/cli/install_database.php \
  --lang=en \
  --adminuser="${ADMIN_USER}" \
  --adminpass="${ADMIN_PASS}" \
  --adminemail="${ADMIN_EMAIL}" \
  --fullname="HCMUT E-learning" \
  --shortname="HCMUT LMS" \
  --agree-license \
  > "${MOODLE_INSTALL_LOG}" 2>&1; then
  if ! grep -q "Database tables already present" "${MOODLE_INSTALL_LOG}" 2>/dev/null; then
    grep -i -E "SQLSTATE|ERROR|FATAL|cannot|permission|denied" "${MOODLE_INSTALL_LOG}" || true
    tail -50 "${MOODLE_INSTALL_LOG}"
    rm -f "${MOODLE_INSTALL_LOG}"
    exit 1
  fi
fi
rm -f "${MOODLE_INSTALL_LOG}"

echo "Updating ConfigMap..."
TMP_CONFIG_PROD="$(mktemp /tmp/moodle-config-prod.php.XXXXXX)"
cat > "${TMP_CONFIG_PROD}" <<CONFIG_EOF
<?php
unset(\$CFG);
global \$CFG;
\$CFG = new stdClass();

\$CFG->dbtype    = 'pgsql';
\$CFG->dblibrary = 'native';
\$CFG->dbhost    = '${DB_HOST}';
\$CFG->dbname    = 'moodle';
\$CFG->dbuser    = '${DB_USER}';
\$CFG->dbpass    = '${DB_PASS}';
\$CFG->prefix    = 'mdl_';
\$CFG->dboptions = array (
  'dbpersist' => 0,
  'dbport' => '${DB_PORT}',
  'dbsocket' => '',
  'sslmode' => 'require',
  'connect_timeout' => 30,
);

\$CFG->wwwroot   = '${SITE_URL}';
\$CFG->sslproxy  = true;
\$CFG->dataroot  = '/var/www/moodledata';
\$CFG->admin     = '${ADMIN_USER}';
\$CFG->directorypermissions = 02777;

\$CFG->themedesignermode = 0;
\$CFG->cachejs = 1;

require_once(__DIR__ . '/lib/setup.php');
CONFIG_EOF
kubectl create configmap moodle-config --from-file=config.php="${TMP_CONFIG_PROD}" --dry-run=client -o yaml | kubectl apply -f -
rm -f "${TMP_CONFIG_PROD}"
kubectl rollout restart deployment/moodle

echo
echo "=== Done ==="
FINAL_LB_IP=$(kubectl get svc moodle-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
FINAL_LB_HOST=$(kubectl get svc moodle-service -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
[[ -n "${FINAL_LB_IP}" ]] && echo "DNS: A ${EXTERNAL_DNS_HOSTNAME} -> ${FINAL_LB_IP}"
[[ -n "${FINAL_LB_HOST}" ]] && echo "DNS: CNAME ${EXTERNAL_DNS_HOSTNAME} -> ${FINAL_LB_HOST}"
echo "KUBECONFIG: export KUBECONFIG=${DO_DIR}/kubeconfig-do"

