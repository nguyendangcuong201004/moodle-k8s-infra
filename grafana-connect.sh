#!/usr/bin/env bash
# Connect to Grafana: start port-forward, import dashboards, print credentials.
# Usage: ./grafana-connect.sh [--import-only | --no-import]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASHBOARDS_DIR="${SCRIPT_DIR}/grafana/dashboards"
NAMESPACE="${NAMESPACE:-monitoring}"
GRAFANA_LOCAL_PORT="${GRAFANA_LOCAL_PORT:-3000}"
IMPORT="${1:-}"

# Auto-detect KUBECONFIG from repo
if [[ -z "${KUBECONFIG:-}" ]]; then
  for _kc in \
    "${SCRIPT_DIR}/digitalocean/kubeconfig-production" \
    "${SCRIPT_DIR}/digitalocean/kubeconfig-staging" \
    "${SCRIPT_DIR}/digitalocean/kubeconfig"; do
    if [[ -f "${_kc}" ]]; then
      export KUBECONFIG="${_kc}"
      echo "Auto-detected KUBECONFIG=${KUBECONFIG}"
      break
    fi
  done
fi

if [[ -z "${KUBECONFIG:-}" ]]; then
  echo "KUBECONFIG not set and no kubeconfig found in digitalocean/"; exit 1
fi

# Get credentials from k8s secret
GF_USER="$(kubectl -n "${NAMESPACE}" get secret kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-user}' | base64 -d 2>/dev/null)"
GF_PASS="$(kubectl -n "${NAMESPACE}" get secret kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d 2>/dev/null)"

if [[ -z "${GF_USER}" || -z "${GF_PASS}" ]]; then
  echo "Cannot read Grafana credentials from secret kube-prometheus-stack-grafana"; exit 1
fi

# Kill any existing port-forward on the port
OLD_PID="$(ss -tlnp 2>/dev/null | grep ":${GRAFANA_LOCAL_PORT}" | grep -oP 'pid=\K[0-9]+' | head -1 || true)"
if [[ -n "${OLD_PID}" ]]; then
  echo "Killing existing port-forward (pid=${OLD_PID})..."
  kill "${OLD_PID}" 2>/dev/null || true
  sleep 1
fi

_start_portforward() {
  kubectl -n "${NAMESPACE}" port-forward svc/kube-prometheus-stack-grafana \
    "${GRAFANA_LOCAL_PORT}:80" >/dev/null 2>&1 &
  PF_PID=$!
  sleep 3
}

_wait_auth() {
  local max="${1:-30}"
  for i in $(seq 1 "${max}"); do
    code="$(curl -sS -o /dev/null -w "%{http_code}" -u "${GF_USER}:${GF_PASS}" \
      "http://127.0.0.1:${GRAFANA_LOCAL_PORT}/api/user" 2>/dev/null)"
    if [[ "${code}" == "200" ]]; then return 0; fi
    sleep 1
  done
  return 1
}

echo "Starting Grafana port-forward on localhost:${GRAFANA_LOCAL_PORT}..."
_start_portforward

# Always reset the admin password to match the k8s secret.
# Grafana 13 may force a password-change on first login, making the secret's
# password invalid. Resetting here ensures credentials are predictable after
# any pod restart or OOMKill.
GF_POD="$(kubectl -n "${NAMESPACE}" get pod -l "app.kubernetes.io/name=grafana" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
kubectl -n "${NAMESPACE}" exec "${GF_POD}" -c grafana -- \
  grafana cli admin reset-admin-password "${GF_PASS}" >/dev/null 2>&1 || true

if ! _wait_auth 30; then
  # Grafana 13 disables basic auth by default. Enable it and retry.
  echo "Auth failed — enabling GF_AUTH_BASIC_ENABLED..."
  kubectl -n "${NAMESPACE}" set env deployment/kube-prometheus-stack-grafana \
    GF_AUTH_BASIC_ENABLED=true >/dev/null 2>&1 || true
  kubectl -n "${NAMESPACE}" rollout status deployment/kube-prometheus-stack-grafana \
    --timeout=90s 2>&1

  kill "${PF_PID}" 2>/dev/null || true; sleep 1
  _start_portforward

  GF_POD="$(kubectl -n "${NAMESPACE}" get pod -l "app.kubernetes.io/name=grafana" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  kubectl -n "${NAMESPACE}" exec "${GF_POD}" -c grafana -- \
    grafana cli admin reset-admin-password "${GF_PASS}" >/dev/null 2>&1 || true

  if ! _wait_auth 30; then
    echo "Grafana auth still failing after recovery — check pod logs"
    kill "${PF_PID}" 2>/dev/null || true; exit 1
  fi
fi

echo "Grafana ready."

if [[ "${IMPORT}" != "--no-import" && -d "${DASHBOARDS_DIR}" ]]; then
  echo "Importing dashboards from ${DASHBOARDS_DIR}..."
  for f in "${DASHBOARDS_DIR}"/*.json; do
    [ -f "${f}" ] || continue
    name="$(basename "${f}")"
    payload="$(jq -n --argjson d "$(cat "${f}")" '{dashboard:($d+{id:null}),overwrite:true,folderId:0}')"
    result="$(curl -sS -u "${GF_USER}:${GF_PASS}" \
      -X POST "http://127.0.0.1:${GRAFANA_LOCAL_PORT}/api/dashboards/db" \
      -H "Content-Type: application/json" -d "${payload}" 2>/dev/null)"
    import_status="$(echo "${result}" | python3 -c \
      "import sys,json; d=json.load(sys.stdin); print(d.get('status',d.get('message','?')))" 2>/dev/null || echo "?")"
    echo "  ${name}: ${import_status}"
  done
fi

echo ""
echo "=============================================="
echo "Grafana: http://localhost:${GRAFANA_LOCAL_PORT}"
echo "  user=${GF_USER}  pass=${GF_PASS}"
echo "=============================================="
echo "(Port-forward pid=${PF_PID} — keep this terminal open, or run in background)"

if [[ "${IMPORT}" == "--import-only" ]]; then
  kill "${PF_PID}" 2>/dev/null || true
  exit 0
fi

# Keep running until Ctrl+C
_cleanup() { kill "${PF_PID}" 2>/dev/null || true; echo "Port-forward stopped."; }
trap _cleanup EXIT INT TERM
wait "${PF_PID}" 2>/dev/null || true
