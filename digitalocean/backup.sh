#!/usr/bin/env bash
# Backup Moodle PostgreSQL database using pg_dump
# Usage:
#   ./backup.sh production          — backup production DB
#   ./backup.sh staging             — backup staging DB
#   ./backup.sh production latest   — keep only latest backup
set -euo pipefail

WORKSPACE="${1:-}"
KEEP_LATEST="${2:-}"
if [[ "${WORKSPACE}" != "staging" && "${WORKSPACE}" != "production" ]]; then
  echo "Usage: $0 <staging|production> [latest]"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DO_DIR="${SCRIPT_DIR}/digitalocean"

# Load .env
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${SCRIPT_DIR}/.env"
  set +a
fi

# Set kubeconfig
KUBECONFIG_FILE="${DO_DIR}/kubeconfig-${WORKSPACE}"
if [[ ! -f "${KUBECONFIG_FILE}" ]]; then
  echo "Kubeconfig not found: ${KUBECONFIG_FILE}"
  echo "Run setup.sh first."
  exit 1
fi
export KUBECONFIG="${KUBECONFIG_FILE}"

# Get DB connection info from the running deployment
echo "=== Reading DB connection from Moodle deployment ==="
DB_HOST=$(kubectl get deployment moodle -n moodle -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MOODLE_DB_HOST")].value}')
DB_PORT=$(kubectl get deployment moodle -n moodle -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MOODLE_DB_PORT")].value}')
DB_NAME=$(kubectl get deployment moodle -n moodle -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MOODLE_DB_NAME")].value}')
DB_USER=$(kubectl get deployment moodle -n moodle -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MOODLE_DB_USER")].value}')
DB_PASS=$(kubectl get secret moodle-db -n moodle -o jsonpath='{.data.MOODLE_DB_PASSWORD}' | base64 -d)

[[ -z "${DB_HOST}" ]] && { echo "Cannot read DB_HOST from deployment"; exit 1; }

echo "  Host: ${DB_HOST}"
echo "  Port: ${DB_PORT}"
echo "  DB:   ${DB_NAME}"
echo "  User: ${DB_USER}"

# Create backup directory
BACKUP_DIR="${SCRIPT_DIR}/backups"
mkdir -p "${BACKUP_DIR}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/${WORKSPACE}-${DB_NAME}-${TIMESTAMP}.sql.gz"

# Run pg_dump from a temporary pod
echo
echo "=== Running pg_dump via temporary pod ==="
echo "This may take a few minutes depending on database size..."

kubectl run moodle-backup-"${TIMESTAMP}" \
  --namespace moodle \
  --image=postgres:16-alpine \
  --restart=Never \
  --env="PGPASSWORD=${DB_PASS}" \
  --command -- \
  pg_dump \
    "host=${DB_HOST} port=${DB_PORT} dbname=${DB_NAME} user=${DB_USER} sslmode=require" \
    --no-owner \
    --no-privileges \
    --format=plain \
    --compress=0

POD_NAME="moodle-backup-${TIMESTAMP}"

# Wait for pod to complete
echo "Waiting for backup pod to complete..."
if ! kubectl wait --for=condition=Ready pod/"${POD_NAME}" -n moodle --timeout=30s 2>/dev/null; then
  true  # pod might finish before Ready
fi
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/"${POD_NAME}" -n moodle --timeout=600s 2>/dev/null || {
  echo "Backup pod did not succeed in 10 minutes."
  echo "Pod status:"
  kubectl get pod "${POD_NAME}" -n moodle
  echo "Pod logs:"
  kubectl logs "${POD_NAME}" -n moodle --tail=20
  kubectl delete pod "${POD_NAME}" -n moodle --ignore-not-found
  exit 1
}

# Copy backup from pod logs (pg_dump output goes to stdout)
echo "Downloading backup..."
kubectl logs "${POD_NAME}" -n moodle | gzip > "${BACKUP_FILE}"

# Cleanup pod
kubectl delete pod "${POD_NAME}" -n moodle --ignore-not-found

# Verify backup
BACKUP_SIZE=$(du -h "${BACKUP_FILE}" | cut -f1)
echo
echo "=== Backup complete ==="
echo "  File: ${BACKUP_FILE}"
echo "  Size: ${BACKUP_SIZE}"

# Optionally keep only latest
if [[ "${KEEP_LATEST}" == "latest" ]]; then
  echo "Cleaning old backups (keeping latest only)..."
  # shellcheck disable=SC2012
  ls -t "${BACKUP_DIR}/${WORKSPACE}-${DB_NAME}"-*.sql.gz 2>/dev/null | tail -n +2 | xargs -r rm -f
fi

# List all backups
echo
echo "Available backups:"
ls -lh "${BACKUP_DIR}/"*.sql.gz 2>/dev/null || echo "  (none)"
