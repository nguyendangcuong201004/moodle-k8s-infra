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
[[ -z "${DB_USER}" || "${DB_USER}" == "null" ]] && DB_USER="${MOODLE_DB_USER:-moodleuser}"

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
echo "=== Step 2: Deploy Moodle via Helm ==="
HELM_CHART="${SCRIPT_DIR}/helm/moodle"
SIZE_PROFILE="${SIZE_PROFILE:-small}"
[[ ! -d "${HELM_CHART}" ]] && { echo "Helm chart not found at ${HELM_CHART}"; exit 1; }

echo "Deploying with size profile: ${SIZE_PROFILE}"
helm upgrade --install moodle "${HELM_CHART}" \
  --namespace moodle --create-namespace \
  -f "${HELM_CHART}/values-${SIZE_PROFILE}.yaml" \
  --set db.host="${DB_HOST}" \
  --set db.port="${DB_PORT}" \
  --set db.name="${DB_NAME}" \
  --set db.user="${DB_USER}" \
  --set db.password="${DB_PASS}" \
  --set db.sslmode=require \
  --set moodle.wwwroot="${SITE_URL}" \
  --set persistence.storageClass=longhorn \
  --set service.type=LoadBalancer \
  --set ingress.enabled=false \
  --set "service.annotations.service\.beta\.kubernetes\.io/do-loadbalancer-name=${LB_NAME}" \
  --set "service.annotations.external-dns\.alpha\.kubernetes\.io/hostname=${EXTERNAL_DNS_HOSTNAME}"

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
echo "=== Step 4: Wait for Moodle pods (Running phase, not Ready — DB not installed yet) ==="
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
# Write install script into pod to avoid kubectl exec streaming timeout (DO API proxy drops long connections)
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

# Launch in background — kubectl exec returns immediately, no long-lived connection
kubectl -n moodle exec "${MOODLE_POD}" -- bash -c "nohup /tmp/moodle-install.sh >/dev/null 2>&1 & disown"

# Poll for DB install completion (max 15 min)
# Check DB version — works even if pod restarts and /tmp/ is cleared
for i in $(seq 1 60); do
  sleep 15
  # Re-resolve pod name in case of restart
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
FINAL_LB_IP=$(kubectl -n moodle get svc moodle -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
FINAL_LB_HOST=$(kubectl -n moodle get svc moodle -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
[[ -n "${FINAL_LB_IP}" ]] && echo "DNS: A ${EXTERNAL_DNS_HOSTNAME} -> ${FINAL_LB_IP}"
[[ -n "${FINAL_LB_HOST}" ]] && echo "DNS: CNAME ${EXTERNAL_DNS_HOSTNAME} -> ${FINAL_LB_HOST}"
echo ""
echo "To use kubectl:"
echo "  export KUBECONFIG=${KUBECONFIG_FILE}"
