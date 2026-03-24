#!/usr/bin/env bash
# Usage:
#   ./destroy.sh staging     — destroy the staging environment
#   ./destroy.sh production  — destroy the production environment
#   ./destroy.sh             — destroy the current default workspace (legacy)
set -euo pipefail

WORKSPACE="${1:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${SCRIPT_DIR}/.env"
  set +a
fi

DO_DIR="${SCRIPT_DIR}/digitalocean"
KUBECONFIG_FILE="${DO_DIR}/kubeconfig-${WORKSPACE:-do}"

echo "=== DigitalOcean destroy (${DO_DIR}) ==="
command -v terraform >/dev/null 2>&1 || { echo "terraform is required"; exit 1; }

if [[ -z "${DO_TOKEN:-}" ]]; then
  echo "DO_TOKEN not set. Set it in .env (moodle-k8s-infra/.env) and re-run."
  exit 1
fi

export TF_VAR_do_token="${DO_TOKEN}"
cd "${DO_DIR}"

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
  # If cluster still exists in state, use its kubeconfig so we can delete Service/PVC first.
  if terraform state list 2>/dev/null | grep -q "digitalocean_kubernetes_cluster\.moodle_cluster"; then
    KUBECONFIG_RAW="$(terraform output -raw kubeconfig 2>/dev/null || true)"
    if [[ -n "${KUBECONFIG_RAW}" ]]; then
      printf '%s' "${KUBECONFIG_RAW}" > "${KUBECONFIG_FILE}"
      export KUBECONFIG="${KUBECONFIG_FILE}"

      # Uninstall Helm release (cleans up Deployment, Service, PVC, Secret, HPA, Ingress)
      echo "Uninstalling Helm release 'moodle'..."
      helm uninstall moodle -n moodle --wait 2>/dev/null || true

      # Clean up leftover resources not managed by Helm
      kubectl delete secret do-db-admin-grant --ignore-not-found=true 2>/dev/null || true
      for job in $(kubectl get jobs -o name 2>/dev/null | grep '^job.batch/moodle-db-grant-' || true); do
        kubectl delete "${job}" --ignore-not-found=true || true
      done
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

echo "=== Post-destroy: checking orphan DigitalOcean CSI volumes ==="
if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  VOLUMES_JSON="$(curl -sS -H "Authorization: Bearer ${DO_TOKEN}" "https://api.digitalocean.com/v2/volumes?page=1&per_page=200" || true)"
  ORPHAN_LIST="$(echo "${VOLUMES_JSON}" | jq -r '.volumes[]? | select((.name | startswith("pvc-")) and ((.description // "") | contains("DigitalOcean CSI driver")) and ((.droplet_ids | length) == 0)) | [.id, .name, .region.slug, .created_at] | @tsv' 2>/dev/null || true)"

  if [[ -n "${ORPHAN_LIST}" ]]; then
    echo "Found orphan PVC-backed block volumes:"
    while IFS=$'\t' read -r vol_id vol_name vol_region vol_created; do
      [[ -z "${vol_id}" ]] && continue
      echo "- ${vol_id}  ${vol_name}  region=${vol_region}  created_at=${vol_created}"
      if [[ "${DO_DELETE_ORPHAN_PVC_VOLUMES:-false}" == "true" ]]; then
        echo "  deleting volume ${vol_id} ..."
        curl -sS -X DELETE -H "Authorization: Bearer ${DO_TOKEN}" "https://api.digitalocean.com/v2/volumes/${vol_id}?region=${vol_region}" >/dev/null || true
      fi
    done <<< "${ORPHAN_LIST}"

    if [[ "${DO_DELETE_ORPHAN_PVC_VOLUMES:-false}" != "true" ]]; then
      echo "Set DO_DELETE_ORPHAN_PVC_VOLUMES=true to auto-delete these orphans during destroy."
    fi
  else
    echo "No orphan PVC-backed DO block volumes detected."
  fi
else
  echo "curl/jq not found; skipping orphan volume check."
fi

echo ""
echo "=== Destroy complete ==="
echo "If you had KUBECONFIG=${DO_DIR}/kubeconfig-do set, you may unset it: unset KUBECONFIG"
echo "Longhorn volumes go with the PVC; to uninstall Longhorn: kubectl delete -f https://raw.githubusercontent.com/longhorn/longhorn/v1.11.0/deploy/longhorn.yaml"
