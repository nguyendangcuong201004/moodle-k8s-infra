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

echo "Running terraform destroy -auto-approve..."
export TF_IN_AUTOMATION=1
terraform destroy -auto-approve

echo ""
echo "=== Destroy complete ==="
echo "If you had KUBECONFIG=${DO_DIR}/kubeconfig-do set, you may unset it: unset KUBECONFIG"
