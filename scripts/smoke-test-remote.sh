#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-zenyard}"
RELEASE_NAME="${RELEASE_NAME:-zenyard}"
GCP_HOST="${GCP_HOST:-}"
GCP_USER="${GCP_USER:-ubuntu}"
GCP_SSH_KEY="${GCP_SSH_KEY:-${HOME}/.ssh/id_rsa}"
INGRESS_URL="${INGRESS_URL:-http://${GCP_HOST}}"
CHECK_OBSERVABILITY="${CHECK_OBSERVABILITY:-true}"

if [ -z "${GCP_HOST}" ]; then
  printf '%s\n' 'GCP_HOST is not set. Run: make gcp-test GCP_HOST=<vm-ip>' >&2
  exit 1
fi

GCP_SSH="ssh -i ${GCP_SSH_KEY} -o StrictHostKeyChecking=no -o BatchMode=yes -o ServerAliveInterval=30 ${GCP_USER}@${GCP_HOST}"
KUBECONFIG_REMOTE="/home/${GCP_USER}/.kube/config"
# HTTP tests run from inside the VM via SSH — GCP firewall may block port 80 externally.
# Replace the public host with localhost so curl resolves through Traefik on the VM.
LOCAL_INGRESS_URL="http://localhost"

log() { printf '[smoke-remote] %s\n' "$*"; }

rkubectl() {
  local q
  q="$(printf '%q ' "$@")"
  ${GCP_SSH} "KUBECONFIG=${KUBECONFIG_REMOTE} kubectl ${q}"
}

# Run curl inside the VM via SSH using the localhost ingress URL.
# Use printf '%q' to preserve argument quoting across the SSH boundary.
rcurl() {
  local q
  q="$(printf '%q ' "$@")"
  ${GCP_SSH} "curl ${q}"
}

wait_for_http() {
  local url="${LOCAL_INGRESS_URL}${1#${INGRESS_URL}}"
  for _ in $(seq 1 30); do
    if rcurl -fsS "${url}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  rcurl -fsS "${url}" >/dev/null
}

log "checking remote kubectl connectivity"
rkubectl get nodes

log "checking namespace ${NAMESPACE}"
rkubectl get namespace "${NAMESPACE}" >/dev/null

log "waiting for all pods to be Ready"
rkubectl wait --for=condition=Ready pod --all -n "${NAMESPACE}" --timeout=10m
rkubectl get pods -n "${NAMESPACE}"

log "checking PostgreSQL readiness"
rkubectl wait --for=condition=Ready pod -n "${NAMESPACE}" \
  -l app.kubernetes.io/name=postgresql --timeout=10m

log "checking schema init hook completed"
# Job is deleted on success (hook-delete-policy: hook-succeeded), so absence = success
# A failed job would still be present; the API TODO test below also catches schema issues
if rkubectl get jobs -n "${NAMESPACE}" 2>/dev/null | grep -q "postgres-init"; then
  rkubectl get jobs -n "${NAMESPACE}" | grep -q "1/1\|Complete" || \
    { printf '%s\n' 'Schema init job present but not complete'; exit 1; }
else
  log "schema init job absent (cleaned up after success)"
fi

log "checking FastAPI health through ingress"
wait_for_http "${INGRESS_URL}/healthz"
log "GET /healthz OK"

log "checking TODO lifecycle through ingress"
todo_payload="$(printf '{"title":"remote smoke %s"}' "$(date +%s)")"
created="$(rcurl -fsS -H 'Content-Type: application/json' \
  -d "${todo_payload}" "${LOCAL_INGRESS_URL}/todos")"
todo_id="$(printf '%s' "${created}" | jq -r '.id')"
if [ -z "${todo_id}" ] || [ "${todo_id}" = "null" ]; then
  printf '%s\n' "${created}"
  printf '%s\n' 'failed to read TODO id from create response' >&2
  exit 1
fi

rcurl -fsS "${LOCAL_INGRESS_URL}/todos" \
  | jq -e --argjson id "${todo_id}" '.[] | select(.id == $id)' >/dev/null
rcurl -fsS -X PATCH "${LOCAL_INGRESS_URL}/todos/${todo_id}/complete" \
  | jq -e '.completed == true' >/dev/null
log "TODO create/list/complete OK"

if [ "${CHECK_OBSERVABILITY}" = "true" ]; then
  log "checking Grafana pod"
  rkubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=grafana \
    --no-headers | grep -q .

  log "checking Prometheus pod"
  rkubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=prometheus \
    --no-headers | grep -q .

  log "checking Loki pod"
  rkubectl get pods -n "${NAMESPACE}" -l app=loki \
    --no-headers | grep -q .

  log "checking Promtail pod"
  rkubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=promtail \
    --no-headers | grep -q .

  log "checking Grafana dashboard ConfigMaps"
  rkubectl get configmap -n "${NAMESPACE}" -l grafana_dashboard=1 \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -q 'sql-transactions-dashboard'

  log "checking node metrics"
  rkubectl top nodes
fi

log "remote smoke test passed"
