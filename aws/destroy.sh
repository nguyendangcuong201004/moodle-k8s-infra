#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${SCRIPT_DIR}/.env"
  set +a
fi

AWS_DIR="${SCRIPT_DIR}/aws"

echo "=== AWS destroy (${AWS_DIR}) ==="
command -v terraform >/dev/null 2>&1 || { echo "terraform is required"; exit 1; }
command -v aws >/dev/null 2>&1 || { echo "awscli is required"; exit 1; }

AWS_PROFILE="${AWS_PROFILE:-devops}"
AWS_REGION="${AWS_REGION:-ap-southeast-1}"
export AWS_PROFILE

echo "Using AWS_PROFILE='${AWS_PROFILE}' and AWS_REGION='${AWS_REGION}'"

cd "${AWS_DIR}"

if [[ ! -d ".terraform" ]]; then
  echo "Running terraform init..."
  terraform init
fi

echo "Running terraform destroy -auto-approve..."
export TF_IN_AUTOMATION=1
terraform destroy -auto-approve

echo ""
echo "=== AWS destroy complete ==="
echo "EKS kubeconfig contexts that were added earlier via aws/setup.sh will remain in ~/.kube/config; you can remove contexts manually if desired."

