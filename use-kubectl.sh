#!/usr/bin/env bash
set -euo pipefail

# Helper to quickly configure kubectl for either:
# - AWS EKS (using aws cli + .env AWS_* settings)
# - DigitalOcean Kubernetes (using digitalocean/kubeconfig-<workspace>)
#
# Usage:
#   ./use-kubectl.sh aws
#   ./use-kubectl.sh do [staging|production]   # default: production
#
# DigitalOcean: after copying kubeconfig, sets default namespace to moodle
# (override with KUBECTL_DEFAULT_NAMESPACE in .env if needed).

if [[ $# -lt 1 ]]; then
  echo "Usage:"
  echo "  $0 aws   # use default or auto-detected EKS cluster"
  echo "  $0 do [staging|production]"
  exit 1
fi

PROVIDER="$1"
DO_WORKSPACE="${2:-production}"   # default production

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
DO_DIR="${SCRIPT_DIR}/digitalocean"
DO_KUBECONFIG="${DO_DIR}/kubeconfig-${DO_WORKSPACE}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Cannot find ${ENV_FILE}. Make sure you're in the correct repo root."
  exit 1
fi

set -a
source "${ENV_FILE}"
set +a

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required. Please install it first."
  exit 1
fi

case "${PROVIDER}" in
  aws)
    if ! command -v aws >/dev/null 2>&1; then
      echo "aws CLI is required. Please install it first."
      exit 1
    fi

    CLUSTER_NAME="${EKS_CLUSTER_NAME:-}"

    # Nếu .env có EKS_CLUSTER_NAME thì dùng luôn
    if [[ -n "${CLUSTER_NAME}" ]]; then
      :
    else
      echo "EKS_CLUSTER_NAME is not set in .env; trying to auto-detect..."

      AWS_PROFILE_ARG_LIST=()
      if [[ -n "${AWS_PROFILE:-}" ]]; then
        AWS_PROFILE_ARG_LIST=(--profile "${AWS_PROFILE}")
      fi

      CLUSTERS_JSON="$(aws eks list-clusters --region "${AWS_REGION}" "${AWS_PROFILE_ARG_LIST[@]}")"
      CLUSTER_COUNT="$(printf '%s\n' "${CLUSTERS_JSON}" | jq '.clusters | length')"

      if [[ "${CLUSTER_COUNT}" -eq 1 ]]; then
        CLUSTER_NAME="$(printf '%s\n' "${CLUSTERS_JSON}" | jq -r '.clusters[0]')"
        echo "Auto-detected EKS cluster: ${CLUSTER_NAME}"
      else
        echo "Cannot auto-detect a single EKS cluster."
        echo "Please set EKS_CLUSTER_NAME in .env."
        echo "Example:"
        echo "  EKS_CLUSTER_NAME=moodle-eks"
        exit 1
      fi
    fi

    if [[ -z "${AWS_REGION:-}" ]]; then
      echo "AWS_REGION is not set (check .env)."
      exit 1
    fi

    AWS_PROFILE_ARG=()
    if [[ -n "${AWS_PROFILE:-}" ]]; then
      AWS_PROFILE_ARG=(--profile "${AWS_PROFILE}")
    fi

    ROLE_ARN_ARG=()
    if [[ -n "${AWS_ROLE_ARN:-}" ]]; then
      ROLE_ARN_ARG=(--role-arn "${AWS_ROLE_ARN}")
    fi

    echo "Configuring kubectl for AWS EKS:"
    echo "  CLUSTER_NAME=${CLUSTER_NAME}"
    echo "  AWS_REGION=${AWS_REGION}"
    echo "  AWS_PROFILE=${AWS_PROFILE:-<none>}"
    echo "  AWS_ROLE_ARN=${AWS_ROLE_ARN:-<none>}"

    aws eks update-kubeconfig \
      --name "${CLUSTER_NAME}" \
      --region "${AWS_REGION}" \
      "${AWS_PROFILE_ARG[@]}" \
      "${ROLE_ARN_ARG[@]}"
    ;;

  do)
    if [[ "${DO_WORKSPACE}" != "staging" && "${DO_WORKSPACE}" != "production" ]]; then
      echo "DO workspace must be 'staging' or 'production'. Got: ${DO_WORKSPACE}"
      exit 1
    fi
    echo "Configuring kubectl for DigitalOcean Kubernetes (${DO_WORKSPACE})..."

    if [[ ! -f "${DO_KUBECONFIG}" ]]; then
      echo "DigitalOcean kubeconfig not found at ${DO_KUBECONFIG}."
      echo "Run: ./digitalocean/setup.sh ${DO_WORKSPACE}"
      exit 1
    fi

    mkdir -p "${HOME}/.kube"

    if [[ -f "${HOME}/.kube/config" ]]; then
      BACKUP="${HOME}/.kube/config.backup-$(date +%Y%m%d-%H%M%S)"
      echo "Backing up existing kubeconfig to ${BACKUP}"
      cp "${HOME}/.kube/config" "${BACKUP}"
    fi

    cp "${DO_KUBECONFIG}" "${HOME}/.kube/config"
    echo "Copied ${DO_KUBECONFIG} to ${HOME}/.kube/config (workspace: ${DO_WORKSPACE})"

    # Moodle Helm release lives in namespace moodle (see digitalocean/setup.sh)
    DO_DEFAULT_NS="${KUBECTL_DEFAULT_NAMESPACE:-moodle}"
    kubectl config set-context --current --namespace="${DO_DEFAULT_NS}"
    echo "Default namespace for current context: ${DO_DEFAULT_NS}"
    ;;

  *)
    echo "Unknown provider: ${PROVIDER}"
    echo "Supported: aws, do"
    exit 1
    ;;
esac

echo
echo "kubectl contexts:"
kubectl config get-contexts || true

