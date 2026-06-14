#!/usr/bin/env bash
# stress-test-remote.sh — HTTP load test against the GCP-deployed FastAPI app.
# All requests are issued from inside the VM via SSH to avoid GCP firewall restrictions.
# Requires: ssh access to GCP_HOST, curl on the remote VM, jq locally.
set -euo pipefail

NAMESPACE="${NAMESPACE:-zenyard}"
GCP_HOST="${GCP_HOST:-}"
GCP_USER="${GCP_USER:-ubuntu}"
GCP_SSH_KEY="${GCP_SSH_KEY:-${HOME}/.ssh/id_rsa}"
CONCURRENCY="${CONCURRENCY:-20}"
TOTAL_REQUESTS="${TOTAL_REQUESTS:-200}"
BASE_URL="http://localhost"

if [ -z "${GCP_HOST}" ]; then
  printf '%s\n' 'GCP_HOST is not set. Run: make gcp-stress GCP_HOST=<vm-ip>' >&2
  exit 1
fi

GCP_SSH="ssh -i ${GCP_SSH_KEY} -o StrictHostKeyChecking=no -o BatchMode=yes \
  -o ServerAliveInterval=30 -o ServerAliveCountMax=10 ${GCP_USER}@${GCP_HOST}"

log()  { printf '[stress] %s\n' "$*"; }
hr()   { printf '%s\n' '────────────────────────────────────────'; }

# Run the entire stress workload as a single heredoc on the VM to avoid
# per-request SSH overhead.
run_remote() {
  ${GCP_SSH} bash -s "$@"
}

log "GCP stress test — ${BASE_URL} via SSH"
log "concurrency=${CONCURRENCY}  total_requests=${TOTAL_REQUESTS}"
hr

# ── Phase 1: health check burst ───────────────────────────────────────────────
log "Phase 1: GET /healthz (${TOTAL_REQUESTS} requests, concurrency ${CONCURRENCY})"

run_remote "${CONCURRENCY}" "${TOTAL_REQUESTS}" "${BASE_URL}" <<'REMOTE'
set -euo pipefail
CONCURRENCY=$1
TOTAL=$2
BASE=$3

ok=0; fail=0
tmp=$(mktemp -d)
start=$(date +%s%3N)

batch() {
  local n=$1
  for _ in $(seq 1 "$n"); do
    code=$(curl -o /dev/null -s -w "%{http_code}" "${BASE}/healthz")
    printf '%s\n' "$code" >> "${tmp}/results" &
  done
  wait
}

sent=0
while [ $sent -lt $TOTAL ]; do
  batch_size=$CONCURRENCY
  [ $((sent + batch_size)) -gt $TOTAL ] && batch_size=$((TOTAL - sent))
  batch "$batch_size"
  sent=$((sent + batch_size))
done

end=$(date +%s%3N)
elapsed=$((end - start))

while IFS= read -r code; do
  if [ "$code" = "200" ]; then ok=$((ok+1)); else fail=$((fail+1)); fi
done < "${tmp}/results"
rm -rf "${tmp}"

elapsed_s=$(printf "%.2f" "$(echo "scale=2; ${elapsed}/1000" | bc)")
rps=$(printf "%.1f" "$(echo "scale=1; ${TOTAL}*1000/${elapsed}" | bc)")

printf 'requests=%d  ok=%d  fail=%d  elapsed=%ss  rps=%s\n' \
  "$TOTAL" "$ok" "$fail" "$elapsed_s" "$rps"
REMOTE

hr

# ── Phase 2: write burst (POST /todos) ────────────────────────────────────────
log "Phase 2: POST /todos (${TOTAL_REQUESTS} requests, concurrency ${CONCURRENCY})"

run_remote "${CONCURRENCY}" "${TOTAL_REQUESTS}" "${BASE_URL}" <<'REMOTE'
set -euo pipefail
CONCURRENCY=$1
TOTAL=$2
BASE=$3

tmp=$(mktemp -d)
start=$(date +%s%3N)

batch() {
  local n=$1 i
  for i in $(seq 1 "$n"); do
    title="stress-$(date +%s%3N)-${i}"
    code=$(curl -o /dev/null -s -w "%{http_code}" \
      -H 'Content-Type: application/json' \
      -d "{\"title\":\"${title}\"}" \
      "${BASE}/todos")
    printf '%s\n' "$code" >> "${tmp}/results" &
  done
  wait
}

sent=0
while [ $sent -lt $TOTAL ]; do
  batch_size=$CONCURRENCY
  [ $((sent + batch_size)) -gt $TOTAL ] && batch_size=$((TOTAL - sent))
  batch "$batch_size"
  sent=$((sent + batch_size))
done

end=$(date +%s%3N)
elapsed=$((end - start))

ok=0; fail=0
while IFS= read -r code; do
  if [ "$code" = "201" ] || [ "$code" = "200" ]; then ok=$((ok+1)); else fail=$((fail+1)); fi
done < "${tmp}/results"
rm -rf "${tmp}"

elapsed_s=$(printf "%.2f" "$(echo "scale=2; ${elapsed}/1000" | bc)")
rps=$(printf "%.1f" "$(echo "scale=1; ${TOTAL}*1000/${elapsed}" | bc)")

printf 'requests=%d  ok=%d  fail=%d  elapsed=%ss  rps=%s\n' \
  "$TOTAL" "$ok" "$fail" "$elapsed_s" "$rps"
REMOTE

hr

# ── Phase 3: read burst (GET /todos) ──────────────────────────────────────────
log "Phase 3: GET /todos (${TOTAL_REQUESTS} requests, concurrency ${CONCURRENCY})"

run_remote "${CONCURRENCY}" "${TOTAL_REQUESTS}" "${BASE_URL}" <<'REMOTE'
set -euo pipefail
CONCURRENCY=$1
TOTAL=$2
BASE=$3

tmp=$(mktemp -d)
start=$(date +%s%3N)

batch() {
  local n=$1
  for _ in $(seq 1 "$n"); do
    code=$(curl -o /dev/null -s -w "%{http_code}" "${BASE}/todos")
    printf '%s\n' "$code" >> "${tmp}/results" &
  done
  wait
}

sent=0
while [ $sent -lt $TOTAL ]; do
  batch_size=$CONCURRENCY
  [ $((sent + batch_size)) -gt $TOTAL ] && batch_size=$((TOTAL - sent))
  batch "$batch_size"
  sent=$((sent + batch_size))
done

end=$(date +%s%3N)
elapsed=$((end - start))

ok=0; fail=0
while IFS= read -r code; do
  if [ "$code" = "200" ]; then ok=$((ok+1)); else fail=$((fail+1)); fi
done < "${tmp}/results"
rm -rf "${tmp}"

elapsed_s=$(printf "%.2f" "$(echo "scale=2; ${elapsed}/1000" | bc)")
rps=$(printf "%.1f" "$(echo "scale=1; ${TOTAL}*1000/${elapsed}" | bc)")

printf 'requests=%d  ok=%d  fail=%d  elapsed=%ss  rps=%s\n' \
  "$TOTAL" "$ok" "$fail" "$elapsed_s" "$rps"
REMOTE

hr

# ── Phase 4: mixed write + complete ───────────────────────────────────────────
log "Phase 4: mixed POST /todos + PATCH complete (${CONCURRENCY} cycles)"

run_remote "${CONCURRENCY}" "${BASE_URL}" <<'REMOTE'
set -euo pipefail
N=$1
BASE=$2

tmp=$(mktemp -d)
start=$(date +%s%3N)

for i in $(seq 1 "$N"); do
  (
    title="mixed-$(date +%s%3N)-${i}"
    resp=$(curl -fsS -H 'Content-Type: application/json' \
      -d "{\"title\":\"${title}\"}" "${BASE}/todos" 2>/dev/null || true)
    id=$(printf '%s' "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || true)
    if [ -n "$id" ] && [ "$id" != "null" ]; then
      curl -fsS -X PATCH "${BASE}/todos/${id}/complete" -o /dev/null
      printf 'ok\n' >> "${tmp}/results"
    else
      printf 'fail\n' >> "${tmp}/results"
    fi
  ) &
done
wait

end=$(date +%s%3N)
elapsed=$((end - start))

ok=$(grep -c '^ok$' "${tmp}/results" 2>/dev/null || true)
fail=$(grep -c '^fail$' "${tmp}/results" 2>/dev/null || true)
rm -rf "${tmp}"

elapsed_s=$(printf "%.2f" "$(echo "scale=2; ${elapsed}/1000" | bc)")
printf 'cycles=%d  ok=%d  fail=%d  elapsed=%ss\n' "$N" "$ok" "$fail" "$elapsed_s"
REMOTE

hr
log "stress test complete"
log "check Grafana for request-rate and latency metrics (make gcp-port-forward-grafana)"
