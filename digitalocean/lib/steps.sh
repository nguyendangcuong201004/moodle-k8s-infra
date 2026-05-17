#!/usr/bin/env bash
# Deployment steps (sourced by setup.sh).

# Step 0: preflight
step_preflight() {
  for t in terraform kubectl helm jq curl; do
    if [[ "${t}" == "kubectl" ]]; then
      type -P kubectl >/dev/null || { echo "Missing binary: kubectl"; exit 1; }
    else
      command -v "${t}" >/dev/null || { echo "Missing: ${t}"; exit 1; }
    fi
  done
  [[ -d "${HELM_CHART}" ]] || { echo "Helm chart not found: ${HELM_CHART}"; exit 1; }
}

# Step 1: Longhorn
step_longhorn() {
  echo "=== Longhorn ==="
  local need_apply=false
  local desired ready

  # Do not skip install by namespace existence alone; verify Longhorn is actually usable.
  kubectl get sc longhorn >/dev/null 2>&1 || need_apply=true
  kubectl -n longhorn-system get daemonset longhorn-manager >/dev/null 2>&1 || need_apply=true

  if [[ "${need_apply}" == "false" ]]; then
    desired="$(kubectl -n longhorn-system get daemonset longhorn-manager -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)"
    ready="$(kubectl -n longhorn-system get daemonset longhorn-manager -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)"
    [[ "${desired}" -gt 0 && "${ready}" -eq "${desired}" ]] || need_apply=true
  fi

  if [[ "${need_apply}" == "true" ]]; then
    echo "Installing or repairing Longhorn..."
    kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/v1.7.2/deploy/longhorn.yaml
  fi

  _kubectl -n longhorn-system rollout status daemonset/longhorn-manager --timeout=600s \
    || { echo "Longhorn manager daemonset not ready"; exit 1; }

  # Wait until the longhorn StorageClass appears before deploying workloads.
  local i
  for i in {1..60}; do
    kubectl get sc longhorn >/dev/null 2>&1 && break
    sleep 2
  done
  kubectl get sc longhorn >/dev/null 2>&1 \
    || { echo "StorageClass 'longhorn' not found after install"; exit 1; }
}

# Step 2: metrics-server (for HPA)
step_metrics_server() {
  echo "=== Metrics Server ==="
  kubectl get deployment metrics-server -n kube-system &>/dev/null && return
  kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
  kubectl -n kube-system patch deployment metrics-server --type='json' \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
  _kubectl -n kube-system rollout status deployment/metrics-server --timeout=120s || true
}

# Step 3: kube-prometheus-stack + prometheus-adapter
step_prometheus() {
  echo "=== Prometheus + Adapter ==="
  local rw_args=""

  if [[ -z "${GRAFANA_CLOUD_API_KEY}" ]]; then
    local u p
    u="$(k8s_secret monitoring grafana-cloud-credentials username)"
    p="$(k8s_secret monitoring grafana-cloud-credentials password)"
    [[ -n "${u}" && -n "${p}" ]] \
      && GRAFANA_CLOUD_PROM_USERNAME="${GRAFANA_CLOUD_PROM_USERNAME:-${u}}" \
      && GRAFANA_CLOUD_API_KEY="${p}" \
      && echo "Reusing secret: monitoring/grafana-cloud-credentials"
  fi

  if [[ -n "${GRAFANA_CLOUD_API_KEY}" && -n "${GRAFANA_CLOUD_PROM_URL}" && -n "${GRAFANA_CLOUD_PROM_USERNAME}" ]]; then
    ensure_namespace monitoring
    kubectl create secret generic grafana-cloud-credentials -n monitoring \
      --from-literal=username="${GRAFANA_CLOUD_PROM_USERNAME}" \
      --from-literal=password="${GRAFANA_CLOUD_API_KEY}" \
      --dry-run=client -o yaml | kubectl apply -f -
    rw_args="--set prometheus.prometheusSpec.remoteWrite[0].url=${GRAFANA_CLOUD_PROM_URL} \
      --set prometheus.prometheusSpec.remoteWrite[0].basicAuth.username.name=grafana-cloud-credentials \
      --set prometheus.prometheusSpec.remoteWrite[0].basicAuth.username.key=username \
      --set prometheus.prometheusSpec.remoteWrite[0].basicAuth.password.name=grafana-cloud-credentials \
      --set prometheus.prometheusSpec.remoteWrite[0].basicAuth.password.key=password"
  fi

  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
  helm repo update
  # shellcheck disable=SC2086
  helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
    --namespace monitoring --create-namespace \
    --set prometheus.prometheusSpec.retention=6h \
    --set prometheus.prometheusSpec.enableRemoteWriteReceiver=true \
    --set prometheus.prometheusSpec.resources.requests.cpu=100m \
    --set prometheus.prometheusSpec.resources.requests.memory=256Mi \
    --set prometheus.prometheusSpec.resources.limits.cpu=500m \
    --set prometheus.prometheusSpec.resources.limits.memory=512Mi \
    --set grafana.resources.requests.cpu=50m \
    --set grafana.resources.requests.memory=128Mi \
    --set grafana.resources.limits.cpu=200m \
    --set grafana.resources.limits.memory=512Mi \
    --set grafana.persistence.enabled=false \
    --set grafana.env.GF_LOG_LEVEL=error \
    --set grafana.env.GF_LOG_MODE=console \
    --set grafana.env.GF_PATHS_LOGS=/dev/null \
    --set grafana.env.GF_AUTH_BASIC_ENABLED=true \
    --set grafana.defaultDashboardsEnabled=false \
    --set alertmanager.enabled=false \
    --set nodeExporter.enabled=true \
    --set kubeStateMetrics.enabled=true \
    ${rw_args} --wait --timeout 5m || echo "Prometheus install failed, continuing..."

  helm upgrade --install prometheus-adapter prometheus-community/prometheus-adapter \
    --namespace monitoring \
    --set prometheus.url=http://kube-prometheus-stack-prometheus.monitoring.svc \
    --set prometheus.port=9090 \
    --set rules.default=false \
    --set "rules.custom[0].seriesQuery=container_network_receive_bytes_total{namespace=\"moodle\"}" \
    --set "rules.custom[0].resources.overrides.namespace.resource=namespace" \
    --set "rules.custom[0].resources.overrides.pod.resource=pod" \
    --set "rules.custom[0].name.as=http_requests_per_second" \
    --set "rules.custom[0].metricsQuery=sum(rate(container_network_receive_bytes_total{namespace=\"moodle\",container=\"moodle\"}[2m])) by (pod) / 1024" \
    --wait --timeout 3m || echo "Adapter install failed, continuing..."

  # In Grafana UI credentials
  local u p
  u="$(k8s_secret monitoring kube-prometheus-stack-grafana admin-user)"
  p="$(k8s_secret monitoring kube-prometheus-stack-grafana admin-password)"
  [[ -n "${u}" ]] && echo "Grafana: http://localhost:3000  user=${u}  pass=${p}"
}

# DO Managed Postgres: DATA_SOURCE_NAME secret, manifest apply, rollout wait.
step_postgres_exporter() {
  local manifest="${DO_DIR}/k8s/postgres-exporter.yaml"
  [[ -f "${manifest}" ]] || { echo "Missing postgres-exporter manifest: ${manifest}"; return; }
  echo "=== postgres-exporter ==="
  ensure_namespace monitoring

  local pw="${DO_DB_ADMIN_PASSWORD:-}"
  [[ -z "${pw}" ]] && pw="$(k8s_secret monitoring postgres-exporter-credentials PGPASSWORD 2>/dev/null || true)"
  if [[ -z "${pw}" ]]; then
    local r; r=$(curl -sS -H "Authorization: Bearer ${DO_TOKEN}" \
      "https://api.digitalocean.com/v2/databases/${DB_CLUSTER_ID}/users/doadmin" 2>/dev/null || true)
    pw=$(echo "${r}" | jq -r '.user.password // empty')
  fi
  [[ -z "${pw}" ]] && { echo "Cannot get doadmin password; skipping postgres-exporter"; return; }

  local dsn
  dsn="postgresql://doadmin:${pw}@${DB_HOST}:${DB_PORT}/${DB_NAME}?sslmode=require"

  kubectl create secret generic postgres-exporter-credentials -n monitoring \
    --from-literal=DATA_SOURCE_NAME="${dsn}" \
    --from-literal=PGPASSWORD="${pw}" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl apply -f "${manifest}"
  kubectl -n monitoring rollout restart deployment/postgres-exporter 2>/dev/null || true
  # Use _kubectl: rollout timeouts must not multiply by KUBECTL_RETRIES (kubectl is wrapped in helpers.sh).
  _kubectl -n monitoring rollout status deployment/postgres-exporter --timeout=120s \
    || echo "postgres-exporter not ready (continuing)"

  # Standby metrics (replication lag from standby POV: pg_stat_wal_receiver, DB load on replica)
  local standby_manifest="${DO_DIR}/k8s/postgres-exporter-standby.yaml"
  if [[ -n "${DB_READONLY_HOST:-}" && "${DB_READONLY_HOST}" != "${DB_HOST:-}" && -f "${standby_manifest}" ]]; then
    local ro_dsn
    ro_dsn="postgresql://doadmin:${pw}@${DB_READONLY_HOST}:${DB_PORT}/${DB_NAME}?sslmode=require"
    kubectl create secret generic postgres-exporter-standby-credentials -n monitoring \
      --from-literal=DATA_SOURCE_NAME="${ro_dsn}" \
      --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -f "${standby_manifest}"
    kubectl -n monitoring rollout restart deployment/postgres-exporter-standby 2>/dev/null || true
    # Standby rollout can wait on old pod termination; longer timeout, no kubectl_retry wrapping.
    _kubectl -n monitoring rollout status deployment/postgres-exporter-standby --timeout=300s \
      || echo "postgres-exporter-standby not ready (continuing); check: kubectl -n monitoring get pods -l app.kubernetes.io/name=postgres-exporter-standby -o wide"
  else
    kubectl delete deployment/postgres-exporter-standby -n monitoring --ignore-not-found=true >/dev/null 2>&1 || true
    kubectl delete svc/postgres-exporter-standby -n monitoring --ignore-not-found=true >/dev/null 2>&1 || true
    kubectl delete servicemonitor/postgres-exporter-standby -n monitoring --ignore-not-found=true >/dev/null 2>&1 || true
    kubectl delete secret/postgres-exporter-standby-credentials -n monitoring --ignore-not-found=true >/dev/null 2>&1 || true
  fi
}

step_remove_k6_synthetic_probe() {
  echo "=== remove k6 synthetic probe ==="
  ensure_namespace monitoring
  kubectl -n monitoring delete deployment/k6-synthetic-probe --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl -n monitoring delete configmap/k6-synthetic-probe-script --ignore-not-found=true >/dev/null 2>&1 || true
}

step_grafana_dashboards() {
  # Import dashboards to Grafana Cloud if configured
  if [[ -n "${GRAFANA_CLOUD_TOKEN:-}" && -n "${GRAFANA_CLOUD_URL:-}" && -d "${DASHBOARDS_DIR:-}" ]]; then
    echo "=== Grafana Cloud dashboards ==="
    local f
    for f in "${DASHBOARDS_DIR}"/*.json; do
      [ -f "${f}" ] || continue
      local payload; payload=$(jq -n --argjson d "$(cat "${f}")" '{dashboard:($d+{id:null}),overwrite:true,folderId:0}')
      curl -sS -X POST "${GRAFANA_CLOUD_URL}/api/dashboards/db" \
        -H "Authorization: Bearer ${GRAFANA_CLOUD_TOKEN}" -H "Content-Type: application/json" \
        -d "${payload}" || echo "Failed: $(basename "${f}")"
    done
    return
  fi

  # If no Grafana Cloud, try importing into local Grafana deployed by kube-prometheus-stack.
  # We will port-forward the Grafana service temporarily and POST dashboards using admin creds from k8s secret.
  if [[ -d "${DASHBOARDS_DIR:-}" ]]; then
    echo "=== Local Grafana dashboards ==="
    local u p pf_pid
    u="$(k8s_secret monitoring kube-prometheus-stack-grafana admin-user)"
    p="$(k8s_secret monitoring kube-prometheus-stack-grafana admin-password)"
    if [[ -z "${u}" || -z "${p}" ]]; then
      echo "Grafana admin credentials not found in cluster; skipping local import."; return
    fi

    # Start port-forward in background
    kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80 >/dev/null 2>&1 &
    pf_pid=$!
    
    # Wait for Grafana to be ready (max 30 seconds)
    echo "Waiting for Grafana port-forward to be ready..."
    local ready=false
    for i in {1..30}; do
      if curl -sS -f -u "${u}:${p}" http://127.0.0.1:3000/api/health >/dev/null 2>&1; then
        echo "Grafana ready."
        ready=true
        break
      fi
      echo "  [${i}s] Grafana not ready yet..."
      sleep 1
    done

    if [[ "${ready}" == "true" ]]; then
      local f
      for f in "${DASHBOARDS_DIR}"/*.json; do
        [ -f "${f}" ] || continue
        local payload; payload=$(jq -n --argjson d "$(cat "${f}")" '{dashboard:($d+{id:null}),overwrite:true,folderId:0}')
        curl -sS -u "${u}:${p}" -X POST "http://127.0.0.1:3000/api/dashboards/db" \
          -H "Content-Type: application/json" -d "${payload}" || echo "Failed: $(basename "${f}")"
      done
    else
      echo "Grafana port-forward timeout; skipping dashboard import."
    fi

    # Clean up port-forward
    kill ${pf_pid} >/dev/null 2>&1 || true
    sleep 1
  fi
}

step_ingress_nginx() {
  echo "=== Ingress Nginx ==="
  # Use F5/NGINX Ingress Controller here because the community ingress-nginx
  # controller does not support the NGINX least_conn upstream method.
  local uninstall_output
  if ! uninstall_output=$(_helm -n ingress-nginx uninstall ingress-nginx 2>&1); then
    case "${uninstall_output}" in
      *"Release not loaded"*|*"release: not found"*)
        ;;
      *)
        printf '%s\n' "${uninstall_output}" >&2
        return 1
        ;;
    esac
  fi

  helm upgrade --install nginx-ingress oci://ghcr.io/nginx/charts/nginx-ingress \
    --namespace ingress-nginx --create-namespace \
    --set controller.kind=daemonset \
    --set controller.service.type=LoadBalancer \
    --set controller.service.externalTrafficPolicy=Local \
    --set "controller.service.annotations.service\.beta\.kubernetes\.io/do-loadbalancer-name=${LB_NAME}-ingress" \
    --set "controller.service.annotations.service\.beta\.kubernetes\.io/do-loadbalancer-type=REGIONAL_NETWORK" \
    --set-string controller.config.entries.lb-method=least_conn \
    --set-string controller.config.entries.keepalive=16 \
    --set-string controller.config.entries.keepalive-requests=100 \
    --set-string controller.config.entries.keepalive-timeout=30s \
    --set controller.prometheus.create=true \
    --wait --timeout 5m
}

# Step 4: Helm
step_helm_deploy() {
  echo "=== Helm deploy Moodle ==="
  kubectl get sc longhorn >/dev/null 2>&1 \
    || { echo "Missing StorageClass 'longhorn'. Run Longhorn install first."; exit 1; }

  local ro_args=()
  if [[ "${USE_MANAGED_POOL}" != "true" && "${MOODLE_ENABLE_READ_SPLIT}" == "true" \
        && -n "${DB_READONLY_HOST}" && "${DB_READONLY_HOST}" != "${DB_HOST}" ]]; then
    ro_args=(
      --set-string "db.readonlyHosts[0]=${DB_READONLY_HOST}"
      --set pgbouncer.readReplica.enabled=true
      --set "pgbouncer.readReplica.defaultPoolSize=${PGBOUNCER_DEFAULT_POOL_SIZE}"
    )
    echo "Read split: write=${DB_HOST} read=${DB_READONLY_HOST} (PgBouncer read sidecar :6433)"
  fi

  helm upgrade --install moodle "${HELM_CHART}" \
    --namespace "${MOODLE_NAMESPACE}" --create-namespace \
    -f "${HELM_CHART}/values.yaml" \
    --set db.host="${DB_APP_HOST}" --set db.port="${DB_APP_PORT}" \
    --set db.name="${DB_APP_NAME}" --set db.user="${DB_USER}" \
    --set db.password="${DB_APP_PASS}" --set db.sslmode=require \
    --set moodle.wwwroot="${SITE_URL}" \
    --set persistence.storageClass=longhorn \
    --set service.type=ClusterIP \
    --set ingress.enabled=true \
    --set ingress.className=nginx \
    --set ingress.host="${EXTERNAL_DNS_HOSTNAME}" \
    --set-string "ingress.annotations.nginx\.org/lb-method=least_conn" \
    --set-string "ingress.annotations.nginx\.org/client-max-body-size=100m" \
    --set-string "ingress.annotations.nginx\.org/proxy-read-timeout=300s" \
    --set-string "ingress.annotations.nginx\.org/proxy-send-timeout=300s" \
    --set-string "ingress.annotations.nginx\.org/proxy-next-upstream-tries=1" \
    --set "ingress.annotations.external-dns\.alpha\.kubernetes\.io/hostname=${EXTERNAL_DNS_HOSTNAME}" \
    "${HELM_PGBOUNCER_ARGS[@]}" "${ro_args[@]}"
}

# Apply MUC caches from Helm-rendered ConfigMap after Moodle exists in DB (cannot run sooner).
# Idempotent: safe on every ./setup.sh run (fresh install or after Helm chart changes).
#
# IMPORTANT: helpers.sh replaces `kubectl` with kubectl_retry(). Do not use kubectl cp/exec -i + stdin
# with that wrapper: retries rerun only kubectl and consume stdin once — file never appears on repeats.
# Use _kubectl (no retry per call) here and retry the whole upload+exec block ourselves if needed.
step_moodle_muc_cache_setup() {
  echo "=== Moodle MUC caches (ConfigMap script in web pod) ==="
  local cm pod scratch attempt retries ok rpath
  cm="${MOODLE_CACHE_SETUP_CONFIGMAP:-${MOODLE_RELEASE_NAME}-cache-setup}"
  if ! kubectl -n "${MOODLE_NAMESPACE}" get configmap "${cm}" >/dev/null 2>&1; then
    echo "ConfigMap '${cm}' not found (Redis or cacheSetup disabled in chart). Skipping MUC wiring."
    return 0
  fi

  scratch="$(mktemp)"
  kubectl -n "${MOODLE_NAMESPACE}" get configmap "${cm}" \
    -o jsonpath='{.data.setup-cache\.php}' > "${scratch}"
  if [[ "$(wc -c < "${scratch}")" -lt 32 ]]; then
    rm -f "${scratch}"
    echo "cache-setup ConfigMap '${cm}' has empty setup-cache.php"
    exit 1
  fi

  retries="${MOODLE_MUC_EXEC_RETRIES:-4}"
  ok=0
  attempt=1
  while [[ "${attempt}" -le "${retries}" ]]; do
    pod="$(pick_ready_web_pod)"
    [[ -z "${pod}" ]] && {
      echo "No ready Moodle web pod (${attempt}/${retries})..."
      attempt=$((attempt + 1))
      sleep 2
      continue
    }

    # Stream script into pod in one exec (no kubectl cp / tar).
    # rpath is expanded locally; keep it under /tmp with no shell metacharacters.
    rpath="/tmp/moodle-muc-setup.${RANDOM}${RANDOM}.php"
    # Run `php` as the container UID (php-fpm images are usually root): full K8s env + envFrom secret,
    # so MOODLE_REDIS_* and MOODLE_DB_PASSWORD are visible. Using `runuser www-data` clears or thins
    # env on several images so MUC never saw Redis and exited "success" paths before.
    # -d apc.enable_cli=1: register APCu instance from CLI when extension is present.
    # If you must use www-data only, set MOODLE_MUC_PHP_WRAPPER='runuser -m -u www-data --' in .env.
    _muc_wrap="${MOODLE_MUC_PHP_WRAPPER:-}"
    if cat "${scratch}" | _kubectl -n "${MOODLE_NAMESPACE}" exec "${pod}" -c "${MOODLE_EXEC_CONTAINER}" -i -- \
      sh -c "cat > ${rpath} && chmod 0644 ${rpath} && ${_muc_wrap} php -d apc.enable_cli=1 ${rpath}; ec=\$?; rm -f ${rpath}; exit \$ec"; then
      ok=1
      break
    fi
    echo "MUC sync+run failed (${attempt}/${retries}), retrying..."
    attempt=$((attempt + 1))
    sleep 2
  done
  rm -f "${scratch}"
  if [[ "${ok}" -ne 1 ]]; then
    echo "MUC apply failed after ${retries} attempts."
    exit 1
  fi
  echo "Moodle MUC caches applied OK."
}

# ExternalDNS + Cloudflare (skipped without CF_API_TOKEN)
step_external_dns() {
  local manifest="${DO_DIR}/k8s/external-dns-cloudflare.yaml"
  if [[ -z "${CF_API_TOKEN:-}" ]]; then
    echo "=== ExternalDNS ==="
    echo "CF_API_TOKEN is not set; skipping Cloudflare DNS automation."
    return
  fi

  [[ -f "${manifest}" ]] || { echo "Missing external-dns manifest: ${manifest}"; exit 1; }
  echo "=== ExternalDNS ==="
  ensure_namespace external-dns
  kubectl create secret generic cloudflare-external-dns-api \
    --from-literal=CF_API_TOKEN="${CF_API_TOKEN}" -n external-dns \
    --dry-run=client -o yaml | kubectl apply -f -
  # Render to a file: avoids breaking YAML when EXTERNAL_DNS_HOSTNAME contains '/' or '&',
  # and allows kubectl_retry (helpers.sh) to re-read the manifest on each attempt—pipes + stdin would not.
  local _extdns_rendered
  _extdns_rendered="$(mktemp)"
  sed "s#EXTERNAL_DNS_DOMAIN_PLACEHOLDER#${EXTERNAL_DNS_HOSTNAME}#g" "${manifest}" > "${_extdns_rendered}"
  kubectl apply -f "${_extdns_rendered}"
  rm -f "${_extdns_rendered}"
  kubectl rollout restart deployment/external-dns -n external-dns 2>/dev/null || true
}

# Step 5: GRANT on schema public + ensure pg_stat_statements
step_db_grant() {
  echo "=== DB GRANT ==="
  # Flaky paths to DOKS: skip OpenAPI validation (fewer apiserver round-trips), bound HTTP wait,
  # and use --wait=false on deletes to avoid extra watch traffic. See helpers ensure_namespace / helm apply.
  local -a k=(--request-timeout="${KUBECTL_REQUEST_TIMEOUT:-120s}")
  local pw="${DO_DB_ADMIN_PASSWORD:-}"
  [[ -z "${pw}" ]] && pw="$(k8s_secret default do-db-admin-grant PGPASSWORD)"
  if [[ -z "${pw}" ]]; then
    local r; r=$(curl -sS -H "Authorization: Bearer ${DO_TOKEN}" \
      "https://api.digitalocean.com/v2/databases/${DB_CLUSTER_ID}/users/doadmin" 2>/dev/null || true)
    pw=$(echo "${r}" | jq -r '.user.password // empty')
  fi
  [[ -z "${pw}" ]] && { echo "Cannot get doadmin password"; exit 1; }

  # Warm discovery/cache with the same retry wrapper as other kubectl calls.
  kubectl "${k[@]}" get ns default -o name >/dev/null 2>&1 || true

  kubectl create secret generic do-db-admin-grant \
    --from-literal=PGPASSWORD="${pw}" --dry-run=client -o yaml \
    | kubectl apply "${k[@]}" --validate=false -f -

  local job="moodle-db-grant-$(date +%s)"
  kubectl apply "${k[@]}" --validate=false -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job}
spec:
  activeDeadlineSeconds: 90
  ttlSecondsAfterFinished: 60
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: grant
          image: postgres:15-alpine
          env:
            - name: PGPASSWORD
              valueFrom: { secretKeyRef: { name: do-db-admin-grant, key: PGPASSWORD } }
          command: [sh, -c, "psql -h ${DB_HOST} -p ${DB_PORT} -U doadmin -d ${DB_NAME} -v ON_ERROR_STOP=1
            -c 'CREATE EXTENSION IF NOT EXISTS pg_stat_statements;'
            -c 'GRANT ALL ON SCHEMA public TO ${DB_USER};'
            -c 'GRANT CREATE ON SCHEMA public TO ${DB_USER};'"]
EOF

  kubectl "${k[@]}" wait --for=condition=complete "job/${job}" --timeout=120s \
    || { kubectl "${k[@]}" logs "job/${job}" --tail=200 2>/dev/null || true
         kubectl "${k[@]}" delete job "${job}" --ignore-not-found --wait=false
         kubectl "${k[@]}" delete secret do-db-admin-grant --ignore-not-found --wait=false
         exit 1; }
  kubectl "${k[@]}" delete job "${job}" --ignore-not-found --wait=false
  kubectl "${k[@]}" delete secret do-db-admin-grant --ignore-not-found --wait=false
  echo "GRANT done."
}

# Step 6: wait for web pod with moodle container Ready (not merely Running).
step_wait_pods() {
  echo "=== Wait for Moodle web pod (max ${STEP4_MAX_WAIT_SEC}s) ==="
  local iters=$(( (STEP4_MAX_WAIT_SEC + STEP4_POLL_SEC - 1) / STEP4_POLL_SEC ))
  local i pod phase ready

  for i in $(seq 1 "${iters}"); do
    pod="$(pick_ready_web_pod)"
    if [[ -n "${pod}" ]]; then
      MOODLE_POD="${pod}"
      echo "[$(( (i-1)*STEP4_POLL_SEC ))s] ${pod} moodle container Ready"
      return 0
    fi

    pod=$(kubectl -n "${MOODLE_NAMESPACE}" get pods -l "${MOODLE_WEB_SELECTOR}" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -z "${pod}" ]]; then
      echo "[$(( (i-1)*STEP4_POLL_SEC ))s] No web pod yet..."
    else
      phase=$(kubectl -n "${MOODLE_NAMESPACE}" get pod "${pod}" -o jsonpath='{.status.phase}' 2>/dev/null)
      ready=$(kubectl -n "${MOODLE_NAMESPACE}" get pod "${pod}" -o json 2>/dev/null \
        | jq -r '.status.containerStatuses[]? | select(.name=="moodle") | .ready' 2>/dev/null || echo "?")
      echo "[$(( (i-1)*STEP4_POLL_SEC ))s] ${pod} phase=${phase:-unknown} moodle.ready=${ready}"
      kubectl -n "${MOODLE_NAMESPACE}" get pod "${pod}" -o json 2>/dev/null | jq -r '
        (.status.initContainerStatuses // [])[]
          | "  init \(.name): \(.state | keys[0])\(if .state.waiting then " (\(.state.waiting.reason // "?"): \(.state.waiting.message // ""))" else "" end)",
        (.status.containerStatuses // [])[]
          | "  cont \(.name): \(.state | keys[0]) ready=\(.ready)\(if .state.waiting then " (\(.state.waiting.reason // "?"): \(.state.waiting.message // ""))" else "" end)"
      ' 2>/dev/null || true
    fi

    [[ "${i}" -eq "${iters}" ]] \
      && { echo "Timeout. Increase MOODLE_STEP4_MAX_WAIT_SEC and retry."; exit 1; }
    sleep "${STEP4_POLL_SEC}"
  done
}

# Step 7: moodledata permissions + install_database.php
step_install() {
  echo "=== Install Moodle DB ==="
  MOODLE_POD="$(pick_ready_web_pod)"
  [[ -z "${MOODLE_POD}" ]] && { echo "No ready pod"; exit 1; }

  exec_retry chown -R www-data:www-data /var/www/moodledata || { echo "chown failed"; exit 1; }
  exec_retry chmod -R 777 /var/www/moodledata || { echo "chmod failed"; exit 1; }

  local ver; ver="$(get_moodle_version "${MOODLE_POD}")"
  if [[ "${ver}" =~ ^[0-9] ]]; then
    echo "Already installed (version: ${ver})"
    exec_retry runuser -u www-data -- php admin/cli/cfg.php --name=enabledashboard --set=1 || true
    return
  fi

  local idir="/var/www/moodledata/.install"
  local iscript="${idir}/run.sh" ilog="${idir}/install.log" iexit="${idir}/install.exit"

  exec_retry sh -c "mkdir -p ${idir} && rm -f ${ilog} ${iexit}" || { echo "Failed prep install dir"; exit 1; }

  exec_retry_stdin "cat > ${iscript} && chmod +x ${iscript}" <<EOF
#!/bin/bash
exec > ${ilog} 2>&1
cd /var/www/html && rm -f ${iexit}
runuser -u www-data -- php -d display_errors=1 admin/cli/install_database.php \
  --lang=en --adminuser="${ADMIN_USER}" --adminpass="${ADMIN_PASS}" \
  --adminemail="${ADMIN_EMAIL}" --fullname="HCMUT E-learning" \
  --shortname="HCMUT LMS" --agree-license
echo \$? > ${iexit}
EOF
  [[ $? -ne 0 ]] && { echo "Failed to stage install script"; exit 1; }

  exec_retry sh -c "nohup sh ${iscript} >/dev/null 2>&1 &" || { echo "Failed to launch installer"; exit 1; }
  echo "Installer started (max 15 min)..."

  local relaunched=false last_size=0
  for i in $(seq 1 60); do
    sleep 15
    local elapsed=$(( i * 15 ))
    local cur_pod; cur_pod="$(pick_ready_web_pod)"
    [[ -z "${cur_pod}" ]] && cur_pod="${MOODLE_POD}"
    if [[ -z "${cur_pod}" ]]; then
      echo "[${elapsed}s] no web pod available, retrying..."
      continue
    fi

    local ec; ec=$(kubectl -n "${MOODLE_NAMESPACE}" exec "${cur_pod}" -c "${MOODLE_EXEC_CONTAINER}" \
      -- sh -c "cat ${iexit} 2>/dev/null || true" 2>/dev/null | tr -d '\r\n' || true)

    if [[ "${ec}" == "0" ]]; then
      ver="$(get_moodle_version "${cur_pod}")"
      [[ "${ver}" =~ ^[0-9] ]] && { echo "Installed (version: ${ver})"; break; }
    elif [[ "${ec}" =~ ^[1-9] ]]; then
      local tail; tail=$(kubectl -n "${MOODLE_NAMESPACE}" exec "${cur_pod}" -c "${MOODLE_EXEC_CONTAINER}" \
        -- sh -c "tail -n 30 ${ilog} 2>/dev/null" 2>/dev/null)
      echo "${tail}" | grep -qi 'already present' && { echo "DB already present, skipping"; break; }
      echo "Install failed (exit=${ec}):" && echo "${tail}" && exit 1
    fi

    local sz; sz=$(kubectl -n "${MOODLE_NAMESPACE}" exec "${cur_pod}" -c "${MOODLE_EXEC_CONTAINER}" \
      -- sh -c "wc -c < ${ilog} 2>/dev/null || echo 0" 2>/dev/null | tr -d ' \n' || echo 0)
    echo "[${elapsed}s] log_bytes=${sz}"
    (( sz > last_size )) && { kubectl -n "${MOODLE_NAMESPACE}" exec "${cur_pod}" \
      -c "${MOODLE_EXEC_CONTAINER}" -- sh -c "tail -n 8 ${ilog} 2>/dev/null" 2>/dev/null || true
      last_size=${sz}; }

    (( elapsed >= 60 )) && (( sz == 0 )) && [[ -z "${ec}" && "${relaunched}" == "false" ]] \
      && exec_retry sh -c "nohup sh ${iscript} >/dev/null 2>&1 &" && relaunched=true

    [[ "${i}" -eq 60 ]] && { echo "Install timeout"; exit 1; }
  done

  exec_retry runuser -u www-data -- php admin/cli/cfg.php --name=enabledashboard --set=1 || true
}

# Step 8: Lean site settings. Run MUC mapping after this step because it purges Moodle caches.
step_configure_moodle() {
  echo "=== Configure Moodle (lean mode) ==="

  local lines=("<?php" "define('CLI_SCRIPT',true);" "require('/var/www/html/config.php');"
    "core_plugin_manager::reset_caches();" "\$pm=core_plugin_manager::instance();")
  for p in "${MOODLE_DISABLED_PLUGINS[@]}"; do
    lines+=("\$i=\$pm->get_plugin_info('${p}');if(\$i&&\$i->is_enabled()){if(method_exists(\$i,'set_enabled')){\$i->set_enabled(false);}else{\$c=get_class(\$i);\$c::enable_plugin(\$i->name,0);}echo\"Disabled:${p}\\n\";}")
  done
  lines+=("core_plugin_manager::reset_caches();echo\"Done\\n\";")
  printf '%s\n' "${lines[@]}" | exec_retry_stdin 'cat > /tmp/disable-plugins.php'
  exec_retry runuser -u www-data -- php /tmp/disable-plugins.php || true

  exec_retry_stdin 'cat > /tmp/lean.php' <<'PHP'
<?php
define('CLI_SCRIPT', true); require('/var/www/html/config.php');
$s = [
  'sessiontimeout'               => 7200,   // up to 90 min quiz
  'lastaccountsupdate'           => 300,    // fewer lastaccess writes
  'task_adhoc_concurrency_limit' => 4,      // leave CPU for web
  'cron_max_stored_log_rows'     => 1000,
  'maxbytes'                     => 2147483648, // 2GB uploads (video)
  'userquota'                    => 0,
  'quiz_autosaveperiod'          => 60,
  'messaging'                    => 0,
  'messagingallusers'            => 0,
  'noemailever'                  => 1,
  'sendmail'                     => '/bin/true',
  'sendcoursewelcomemessage'     => 0,
  'block_online_users_timetosee' => 0,      // disable online-users block
  'enablebadges'                 => 0,
  'enableportfolios'             => 0,
  'enablewebservices'            => 1,
  'enablemobilewebservice'       => 0,
  'enableblogs'                  => 0,
  'enablenotes'                  => 0,
  'enabletags'                   => 0,
  'enablecompletion'             => 1,
  'enableanalytics'              => 0,
  'enableglobalsearch'           => 0,
  'enablecalendarexport'         => 0,
  'antiviruses'                  => '',
];
$c=[];
foreach($s as $k=>$v){ if((string)get_config('core',$k)!==(string)$v){set_config($k,$v);$c[]=$k;} }
echo $c ? 'Updated: '.implode(',',$c)."\n" : "No changes\n";
purge_all_caches(); echo "Cache purged\n";
PHP
  exec_retry runuser -u www-data -- php /tmp/lean.php || { echo "Lean settings failed"; exit 1; }
}
