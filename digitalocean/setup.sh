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
step_prometheus
step_grafana_dashboards
step_ingress_nginx

step_helm_deploy
step_external_dns

step_db_grant
step_wait_pods
step_install
step_configure_moodle
step_moodle_muc_cache_setup
kubectl -n "${MOODLE_NAMESPACE}" rollout restart "deployment/${MOODLE_RELEASE_NAME}"
kubectl -n "${MOODLE_NAMESPACE}" rollout status "deployment/${MOODLE_RELEASE_NAME}" --timeout=300s
step_postgres_exporter
step_remove_k6_synthetic_probe

echo ""
echo "=== Done [${WORKSPACE}] ==="
echo "  Site : ${SITE_URL}"
LB_IP=$(kubectl -n ingress-nginx get svc nginx-ingress-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
LB_HOST=$(kubectl -n ingress-nginx get svc nginx-ingress-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
[[ -n "${LB_IP}"   ]] && echo "  DNS  : A     ${EXTERNAL_DNS_HOSTNAME} → ${LB_IP}"
[[ -n "${LB_HOST}" ]] && echo "  DNS  : CNAME ${EXTERNAL_DNS_HOSTNAME} → ${LB_HOST}"
echo "  kubectl: export KUBECONFIG=${KUBECONFIG_FILE}"

echo ""
echo "=== Starting Grafana port-forward ==="
start_grafana_port_forward monitoring 3000 kube-prometheus-stack-grafana 80
