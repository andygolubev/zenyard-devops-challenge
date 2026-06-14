#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-zenyard}"
RELEASE_NAME="${RELEASE_NAME:-zenyard}"
INGRESS_URL="${INGRESS_URL:-http://localhost:8080}"
CHECK_OBSERVABILITY="${CHECK_OBSERVABILITY:-true}"

log() {
  printf '[smoke] %s\n' "$*"
}

wait_for_http() {
  local url="$1"
  for _ in $(seq 1 30); do
    if curl -fsS "$url" >/dev/null; then
      return 0
    fi
    sleep 2
  done
  curl -fsS "$url" >/dev/null
}

log "checking namespace ${NAMESPACE}"
kubectl get namespace "${NAMESPACE}" >/dev/null

log "waiting for pods"
kubectl wait --for=condition=Ready pod --all -n "${NAMESPACE}" --timeout=10m
kubectl get pods -n "${NAMESPACE}"

log "checking PostgreSQL readiness"
kubectl wait --for=condition=Ready pod -n "${NAMESPACE}" -l app.kubernetes.io/name=postgresql --timeout=10m

log "checking FastAPI health through ingress"
wait_for_http "${INGRESS_URL}/healthz"

log "checking TODO lifecycle through ingress"
todo_payload="$(printf '{"title":"local smoke %s"}' "$(date +%s)")"
created="$(curl -fsS -H 'Content-Type: application/json' -d "${todo_payload}" "${INGRESS_URL}/todos")"
todo_id="$(printf '%s' "${created}" | jq -r '.id')"
if [ -z "${todo_id}" ] || [ "${todo_id}" = "null" ]; then
  printf '%s\n' "${created}"
  printf '%s\n' 'failed to read TODO id from create response' >&2
  exit 1
fi

curl -fsS "${INGRESS_URL}/todos" | jq -e --argjson id "${todo_id}" '.[] | select(.id == $id)' >/dev/null
curl -fsS -X PATCH "${INGRESS_URL}/todos/${todo_id}/complete" | jq -e '.completed == true' >/dev/null

if [ "${CHECK_OBSERVABILITY}" = "true" ]; then
  log "checking Grafana pod"
  kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=grafana --no-headers | grep -q .

  log "checking Prometheus pod"
  kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=prometheus --no-headers | grep -q .

  log "checking logging stack pods"
  kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=loki --no-headers | grep -q .
  kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=promtail --no-headers | grep -q .

  log "checking Grafana dashboard ConfigMaps"
  kubectl get configmap -n "${NAMESPACE}" -l grafana_dashboard=1 \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -q 'sql-transactions-dashboard'
fi

log "local smoke test passed"
