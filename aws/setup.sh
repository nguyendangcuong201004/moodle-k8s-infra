#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  # Load shared environment variables from .env at moodle-k8s-infra/
  set -a
  # shellcheck disable=SC1090
  source "${SCRIPT_DIR}/.env"
  set +a
fi

AWS_PROFILE="${AWS_PROFILE:-devops}"
AWS_REGION="${AWS_REGION:-ap-southeast-1}"
AWS_ROLE_ARN="${AWS_ROLE_ARN:-}"
CLUSTER_NAME="moodle-cluster"
AWS_DIR="moodle-k8s-infra/aws"
K8S_YAML="k8s-moodle.yaml"

echo "=== Step 0: Check environment and AWS profile ==="
echo "Using AWS_PROFILE (set from .env or default)"
command -v terraform >/dev/null 2>&1 || { echo "terraform is required"; exit 1; }
command -v aws >/dev/null 2>&1 || { echo "awscli is required"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required"; exit 1; }
command -v envsubst >/dev/null 2>&1 || { echo "envsubst is required (usually from gettext)"; exit 1; }

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

# If AWS_ROLE_ARN is provided in .env, ensure the profile has role_arn + source_profile
if [[ -n "${AWS_ROLE_ARN}" ]]; then
  echo "Ensuring role_arn is set for profile '${AWS_PROFILE}' using AWS_ROLE_ARN from .env."
  # If role_arn not present in this profile block, append it (simple check)
  if ! awk "/^\[profile ${AWS_PROFILE}\]/ {found=1} found && /role_arn/ {print; exit}" "${AWS_CONFIG_FILE}" >/dev/null 2>&1; then
    # Append role_arn and source_profile at the end of the file (after existing profile block)
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
echo "=== Step 1: Terraform apply in ${AWS_DIR} ==="

if [[ ! -d ".terraform" ]]; then
  echo "Running terraform init..."
  terraform init
fi

echo "Running terraform apply (this may incur cost)..."
export TF_IN_AUTOMATION=1
export TF_LOG=ERROR
terraform apply -auto-approve

echo "Reading Terraform outputs..."
TF_JSON=$(terraform output -json)
EFS_ID=$(echo "${TF_JSON}" | jq -r '.efs_id.value')
RDS_ENDPOINT=$(echo "${TF_JSON}" | jq -r '.rds_endpoint.value')
DB_HOST="${RDS_ENDPOINT%%:*}"

echo
echo "=== Step 2.1: Configure kubectl for EKS cluster ==="
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}"

echo
echo "=== Step 2.2: Install aws-efs-csi-driver addon ==="
aws eks create-addon \
  --cluster-name "${CLUSTER_NAME}" \
  --addon-name aws-efs-csi-driver \
  --resolve-conflicts OVERWRITE || true

echo
echo "=== Step 2.3: Render ${K8S_YAML} with EFS_ID and DB envs, then apply ==="
if [[ ! -f "${K8S_YAML}" ]]; then
  echo "File ${K8S_YAML} not found. Aborting."
  exit 1
fi

echo "Preparing environment variables for Kubernetes manifest..."
export EFS_ID
export MOODLE_DB_HOST="${DB_HOST}"
export MOODLE_DB_NAME="${MOODLE_DB_NAME:-moodle}"
export MOODLE_DB_USER="${MOODLE_DB_USER:-moodleuser}"
export MOODLE_DB_PASSWORD="${MOODLE_DB_PASS:?Set MOODLE_DB_PASS in .env}"

echo "Applying Kubernetes manifests with envsubst..."
envsubst < "${K8S_YAML}" | kubectl apply -f -

echo
echo "=== Step 3: Scale CoreDNS down to 1 replica ==="
kubectl -n kube-system scale deployment coredns --replicas=1
echo "Waiting for coredns rollout..."
kubectl -n kube-system rollout status deployment coredns || true

echo
echo "=== Step 4: Create config.php inside Moodle pod ==="

MOODLE_POD=$(kubectl get pods -l app=moodle -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -z "${MOODLE_POD}" ]]; then
  echo "No pod found with label app=moodle. Please check 'kubectl get pods'."
  exit 1
fi

DB_PASS="${MOODLE_DB_PASS:?Set MOODLE_DB_PASS in .env}"
SITE_URL="${MOODLE_WWWROOT:?Set MOODLE_WWWROOT in .env}"
ADMIN_USER="${MOODLE_ADMIN_USER:?Set MOODLE_ADMIN_USER in .env}"
ADMIN_PASS="${MOODLE_ADMIN_PASS:?Set MOODLE_ADMIN_PASS in .env}"
ADMIN_EMAIL="${MOODLE_ADMIN_EMAIL:?Set MOODLE_ADMIN_EMAIL in .env}"
DB_USER="${MOODLE_DB_USER:-moodleuser}"

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
  'dbport' => '',
  'dbsocket' => '',
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

echo "Copying config.php to pod ${MOODLE_POD}..."
kubectl cp "${TMP_CONFIG}" "${MOODLE_POD}:/var/www/html/config.php"
rm -f "${TMP_CONFIG}"

kubectl exec "${MOODLE_POD}" -- chown www-data:www-data /var/www/html/config.php || true

echo
echo "=== Step 5: Service information for Cloudflare update ==="
kubectl get svc
echo "Use the EXTERNAL-IP of the Moodle service to update DNS in Cloudflare."

echo
echo "=== Step 6: Prepare permissions on /var/www/moodledata and run install_database.php ==="

kubectl exec "${MOODLE_POD}" -- chown -R www-data:www-data /var/www/moodledata
kubectl exec "${MOODLE_POD}" -- chmod -R 777 /var/www/moodledata

kubectl exec "${MOODLE_POD}" -- runuser -u www-data -- php admin/cli/install_database.php \
  --lang=en \
  --adminuser="${ADMIN_USER}" \
  --adminpass="${ADMIN_PASS}" \
  --adminemail="${ADMIN_EMAIL}" \
  --fullname="He thong E-learning HCMUT" \
  --shortname="HCMUT LMS" \
  --agree-license

echo
echo "=== AWS Moodle deployment script finished ==="
echo "You can now verify pods, services, and access Moodle via the configured domain."
