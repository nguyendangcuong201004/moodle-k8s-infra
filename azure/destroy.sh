#!/usr/bin/env bash
# Usage:
#   ./destroy.sh staging     — destroy the staging environment
#   ./destroy.sh production  — destroy the production environment
set -euo pipefail

WORKSPACE="${1:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${SCRIPT_DIR}/.env"
  set +a
fi

AZURE_DIR="${SCRIPT_DIR}/azure"
KUBECONFIG_FILE="${AZURE_DIR}/kubeconfig-${WORKSPACE:-azure}"

echo "=== Azure destroy (${AZURE_DIR}) ==="
command -v terraform >/dev/null 2>&1 || { echo "terraform is required"; exit 1; }

if [[ -z "${AZURE_SUBSCRIPTION_ID:-}" ]]; then
  echo "AZURE_SUBSCRIPTION_ID not set. Set it in .env and re-run."
  exit 1
fi

export TF_VAR_azure_subscription_id="${AZURE_SUBSCRIPTION_ID}"
cd "${AZURE_DIR}"

if [[ ! -d ".terraform" ]]; then
  echo "Running terraform init..."
  terraform init
fi

# Switch workspace if specified
if [[ -n "${WORKSPACE}" ]]; then
  if terraform workspace list | grep -q "^[* ]*${WORKSPACE}$"; then
    terraform workspace select "${WORKSPACE}"
  else
    echo "Workspace '${WORKSPACE}' does not exist. Nothing to destroy."
    exit 0
  fi
fi

echo "=== Pre-destroy: best-effort cleanup of Kubernetes resources ==="
if command -v kubectl >/dev/null 2>&1; then
  if terraform state list 2>/dev/null | grep -q "azurerm_kubernetes_cluster\.moodle"; then
    KUBECONFIG_RAW="$(terraform output -raw kubeconfig 2>/dev/null || true)"
    if [[ -n "${KUBECONFIG_RAW}" ]]; then
      printf '%s' "${KUBECONFIG_RAW}" > "${KUBECONFIG_FILE}"
      export KUBECONFIG="${KUBECONFIG_FILE}"

      echo "Uninstalling Helm release 'moodle'..."
      helm uninstall moodle -n moodle --wait 2>/dev/null || true

      kubectl delete namespace moodle --ignore-not-found=true 2>/dev/null || true

      echo "Waiting for namespace cleanup..."
      for _ in {1..24}; do
        ns_left="$(kubectl get ns moodle --ignore-not-found -o name 2>/dev/null || true)"
        [[ -z "${ns_left}" ]] && break
        sleep 5
      done
    else
      echo "Could not read kubeconfig output; skipping kubectl cleanup."
    fi
  else
    echo "Cluster not found in Terraform state; skipping kubectl cleanup."
  fi
else
  echo "kubectl not found; skipping Kubernetes cleanup and continuing Terraform destroy."
fi

echo "Running terraform destroy -auto-approve..."
export TF_IN_AUTOMATION=1
terraform destroy -auto-approve

rm -f "${KUBECONFIG_FILE}"

echo ""
echo "=== Destroy complete ==="
echo "All Azure resources in the resource group have been deleted."
echo "If you had KUBECONFIG=${KUBECONFIG_FILE} set, you may unset it: unset KUBECONFIG"
