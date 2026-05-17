#!/usr/bin/env bash
# Usage: ./setup.sh <staging|production>
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/config.sh" "$@"
source "${HERE}/lib/helpers.sh"
source "${HERE}/lib/steps.sh"

step_preflight
run_terraform

export KUBECONFIG="${KUBECONFIG_FILE}"

step_longhorn
step_metrics_server
if [[ "${ENABLE_OBSERVABILITY_STACK}" == "true" ]]; then
  step_prometheus
  step_grafana_dashboards
else
  echo "=== Observability ==="
  echo "Skipping Prometheus/Grafana for ${WORKSPACE}."
  step_disable_observability_components
fi

step_helm_deploy
step_external_dns

step_db_grant
step_wait_pods
step_install
step_configure_moodle
step_moodle_muc_cache_setup

echo "=== Restart Moodle deployment ==="
if kubectl -n "${MOODLE_NAMESPACE}" rollout restart "deployment/${MOODLE_RELEASE_NAME}"; then
  if ! _kubectl -n "${MOODLE_NAMESPACE}" rollout status "deployment/${MOODLE_RELEASE_NAME}" --timeout=300s; then
    echo "Warning: rollout status check failed (Kubernetes API may be temporarily unreachable)."
  fi
else
  echo "Warning: rollout restart skipped (Kubernetes API may be temporarily unreachable)."
fi
if [[ "${ENABLE_OBSERVABILITY_STACK}" == "true" ]]; then
  step_postgres_exporter
else
  echo "=== postgres-exporter ==="
  echo "Skipping postgres-exporter for ${WORKSPACE}."
  step_remove_postgres_exporter
fi

if [[ "${ENABLE_K6_SYNTHETIC_CLEANUP}" == "true" ]]; then
  step_remove_k6_synthetic_probe
fi

echo ""
echo "=== Done [${WORKSPACE}] ==="
echo "  Site : ${SITE_URL}"
LB_IP=$(kubectl -n "${MOODLE_NAMESPACE}" get svc moodle \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
LB_HOST=$(kubectl -n "${MOODLE_NAMESPACE}" get svc moodle \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
[[ -n "${LB_IP}"   ]] && echo "  DNS  : A     ${EXTERNAL_DNS_HOSTNAME} → ${LB_IP}"
[[ -n "${LB_HOST}" ]] && echo "  DNS  : CNAME ${EXTERNAL_DNS_HOSTNAME} → ${LB_HOST}"
echo "  kubectl: export KUBECONFIG=${KUBECONFIG_FILE}"

if [[ "${ENABLE_OBSERVABILITY_STACK}" == "true" ]]; then
  echo ""
  echo "=== Starting Grafana port-forward ==="
  start_grafana_port_forward monitoring 3000 kube-prometheus-stack-grafana 80
else
  echo ""
  echo "=== Grafana ==="
  echo "Skipped for ${WORKSPACE}."
fi
