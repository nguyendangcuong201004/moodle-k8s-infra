#!/usr/bin/env bash
# Restore Moodle PostgreSQL database from a backup file
# Usage:
#   ./restore.sh production backups/production-moodle-20260325-143500.sql.gz
#
# WARNING: This will DROP and recreate all tables in the target database.
#          Moodle pods will be scaled down during restore and back up after.
set -euo pipefail

WORKSPACE="${1:-}"
BACKUP_FILE="${2:-}"
if [[ "${WORKSPACE}" != "staging" && "${WORKSPACE}" != "production" ]]; then
  echo "Usage: $0 <staging|production> <backup-file.sql.gz>"
  exit 1
fi
if [[ -z "${BACKUP_FILE}" || ! -f "${BACKUP_FILE}" ]]; then
  echo "Backup file not found: ${BACKUP_FILE}"
  echo
  echo "Available backups:"
  ls -lh "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/backups/"*.sql.gz 2>/dev/null || echo "  (none)"
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
  exit 1
fi
export KUBECONFIG="${KUBECONFIG_FILE}"

# Get DB connection info
echo "=== Reading DB connection from Moodle deployment ==="
DB_HOST=$(kubectl get deployment moodle -n moodle -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MOODLE_DB_HOST")].value}')
DB_PORT=$(kubectl get deployment moodle -n moodle -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MOODLE_DB_PORT")].value}')
DB_NAME=$(kubectl get deployment moodle -n moodle -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MOODLE_DB_NAME")].value}')
DB_USER=$(kubectl get deployment moodle -n moodle -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MOODLE_DB_USER")].value}')
DB_PASS=$(kubectl get secret moodle-db -n moodle -o jsonpath='{.data.MOODLE_DB_PASSWORD}' | base64 -d)

echo "  Host: ${DB_HOST}"
echo "  DB:   ${DB_NAME}"
echo "  File: ${BACKUP_FILE}"

# Confirm
echo
echo "WARNING: This will DROP all existing data in '${DB_NAME}' and restore from backup."
read -rp "Type 'yes' to continue: " CONFIRM
if [[ "${CONFIRM}" != "yes" ]]; then
  echo "Aborted."
  exit 0
fi

# Scale down Moodle to prevent DB connections during restore
echo
echo "=== Step 1: Scale down Moodle pods ==="
ORIGINAL_REPLICAS=$(kubectl get deployment moodle -n moodle -o jsonpath='{.spec.replicas}')
kubectl scale deployment moodle -n moodle --replicas=0
echo "Waiting for pods to terminate..."
kubectl wait --for=delete pod -l app.kubernetes.io/name=moodle,role!=cron -n moodle --timeout=120s 2>/dev/null || true

# Suspend CronJob
echo "Suspending CronJob..."
kubectl patch cronjob moodle-cron -n moodle -p '{"spec":{"suspend":true}}' 2>/dev/null || true

# Create a temporary pod for restore
echo
echo "=== Step 2: Restore database ==="
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
POD_NAME="moodle-restore-${TIMESTAMP}"

# Create a ConfigMap from the backup file
echo "Uploading backup to cluster..."
TEMP_SQL="/tmp/moodle-restore-${TIMESTAMP}.sql"
gunzip -c "${BACKUP_FILE}" > "${TEMP_SQL}"

kubectl create configmap moodle-restore-data \
  --namespace moodle \
  --from-file=backup.sql="${TEMP_SQL}" \
  --dry-run=client -o yaml | kubectl apply -f -
rm -f "${TEMP_SQL}"

# Run restore pod
cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: moodle
spec:
  restartPolicy: Never
  containers:
    - name: restore
      image: postgres:16-alpine
      env:
        - name: PGPASSWORD
          value: "${DB_PASS}"
      command:
        - sh
        - -c
        - |
          echo "Dropping existing tables..."
          psql "host=${DB_HOST} port=${DB_PORT} dbname=${DB_NAME} user=${DB_USER} sslmode=require" -c "
            DO \\\$\\\$ DECLARE r RECORD;
            BEGIN
              FOR r IN (SELECT tablename FROM pg_tables WHERE schemaname = 'public') LOOP
                EXECUTE 'DROP TABLE IF EXISTS public.' || quote_ident(r.tablename) || ' CASCADE';
              END LOOP;
            END \\\$\\\$;
          "
          echo "Restoring from backup..."
          psql "host=${DB_HOST} port=${DB_PORT} dbname=${DB_NAME} user=${DB_USER} sslmode=require" < /restore/backup.sql
          echo "Restore complete."
      volumeMounts:
        - name: restore-data
          mountPath: /restore
  volumes:
    - name: restore-data
      configMap:
        name: moodle-restore-data
YAML

echo "Waiting for restore to complete (this may take several minutes)..."
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/"${POD_NAME}" -n moodle --timeout=600s 2>/dev/null || {
  echo "Restore pod did not succeed."
  echo "Pod logs:"
  kubectl logs "${POD_NAME}" -n moodle --tail=30
  # Don't exit — still need to scale back up
}

echo "Restore pod logs:"
kubectl logs "${POD_NAME}" -n moodle --tail=10

# Cleanup
kubectl delete pod "${POD_NAME}" -n moodle --ignore-not-found
kubectl delete configmap moodle-restore-data -n moodle --ignore-not-found

# Scale back up
echo
echo "=== Step 3: Scale Moodle back up ==="
kubectl patch cronjob moodle-cron -n moodle -p '{"spec":{"suspend":false}}' 2>/dev/null || true
kubectl scale deployment moodle -n moodle --replicas="${ORIGINAL_REPLICAS}"
echo "Scaled to ${ORIGINAL_REPLICAS} replicas."

echo "Waiting for pods to be ready..."
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=moodle -n moodle --timeout=300s 2>/dev/null || true

echo
echo "=== Restore complete ==="
echo "Moodle is back online. Verify at: $(kubectl get deployment moodle -n moodle -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MOODLE_WWWROOT")].value}')"
