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
K8S_YAML="${DO_DIR}/k8s-moodle.yaml"
KUBECONFIG_FILE="${DO_DIR}/kubeconfig-do"

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

echo "=== Pre-destroy: best-effort cleanup of Kubernetes resources ==="
if command -v kubectl >/dev/null 2>&1; then
  # If cluster still exists in state, use its kubeconfig so we can delete Service/PVC first.
  if terraform state list 2>/dev/null | grep -q "digitalocean_kubernetes_cluster\.moodle_cluster"; then
    KUBECONFIG_RAW="$(terraform output -raw kubeconfig 2>/dev/null || true)"
    if [[ -n "${KUBECONFIG_RAW}" ]]; then
      printf '%s' "${KUBECONFIG_RAW}" > "${KUBECONFIG_FILE}"
      export KUBECONFIG="${KUBECONFIG_FILE}"

      if [[ -f "${K8S_YAML}" ]]; then
        echo "Deleting objects from ${K8S_YAML} ..."
        kubectl delete -f "${K8S_YAML}" --ignore-not-found=true || true
      fi

      echo "Deleting known Moodle objects and transient setup objects..."
      # Scale down first so mounted volumes are detached before PVC/PV deletion.
      kubectl scale deployment moodle --replicas=0 --timeout=120s 2>/dev/null || true
      kubectl wait --for=delete pod -l app=moodle --timeout=180s 2>/dev/null || true

      PV_NAME="$(kubectl get pvc moodle-data-pvc -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)"
      kubectl delete deployment moodle --ignore-not-found=true || true
      kubectl delete service moodle-service --ignore-not-found=true || true
      kubectl delete pvc moodle-data-pvc --ignore-not-found=true || true
      kubectl delete secret do-db-admin-grant --ignore-not-found=true || true
      for job in $(kubectl get jobs -o name 2>/dev/null | grep '^job.batch/moodle-db-grant-schema-' || true); do
        kubectl delete "${job}" --ignore-not-found=true || true
      done

      echo "Waiting for Service/PVC to terminate..."
      for _ in {1..12}; do
        svc_left="$(kubectl get svc moodle-service --ignore-not-found -o name 2>/dev/null || true)"
        pvc_left="$(kubectl get pvc moodle-data-pvc --ignore-not-found -o name 2>/dev/null || true)"
        if [[ -z "${svc_left}" && -z "${pvc_left}" ]]; then
          break
        fi
        sleep 5
      done

      if [[ -n "${PV_NAME}" ]]; then
        echo "Waiting for PV ${PV_NAME} cleanup (this triggers DO volume deletion)..."
        for _ in {1..36}; do
          pv_left="$(kubectl get pv "${PV_NAME}" --ignore-not-found -o name 2>/dev/null || true)"
          if [[ -z "${pv_left}" ]]; then
            break
          fi
          sleep 5
        done

        pv_left="$(kubectl get pv "${PV_NAME}" --ignore-not-found -o name 2>/dev/null || true)"
        if [[ -n "${pv_left}" ]]; then
          reclaim_policy="$(kubectl get pv "${PV_NAME}" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}' 2>/dev/null || true)"
          echo "PV ${PV_NAME} still exists with reclaimPolicy=${reclaim_policy:-unknown}."
          echo "If reclaimPolicy is Retain, volume is intentionally kept by Kubernetes."
        fi
      fi
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
