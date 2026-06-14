#!/usr/bin/env bash
# Seal the zenyard stack credentials against the REMOTE cluster's Sealed Secrets
# controller and write the encrypted SealedSecret YAML back into sealed-secrets/gcp/.
#
# The controller's keypair lives in the remote cluster, so kubeseal must run there.
# Plaintext credentials are read from env (or prompted), piped to the remote over the
# encrypted SSH channel, sealed by kubeseal, and only the encrypted output is saved.
# No plaintext is ever written to the repo.
#
# Required env: GCP_HOST
# Optional env: GCP_USER (default ubuntu), GCP_SSH_KEY (default ~/.ssh/id_rsa),
#               NAMESPACE (default zenyard),
#               SS_CONTROLLER_NS (default sealed-secrets),
#               SS_CONTROLLER_NAME (default sealed-secrets),
#               OUT_DIR (default sealed-secrets/gcp),
#               DB_USER, DB_PASSWORD, GRAFANA_ADMIN_USER, GRAFANA_ADMIN_PASSWORD
set -euo pipefail

: "${GCP_HOST:?Set GCP_HOST=<vm-ip>}"
GCP_USER="${GCP_USER:-ubuntu}"
GCP_SSH_KEY="${GCP_SSH_KEY:-$HOME/.ssh/id_rsa}"
NAMESPACE="${NAMESPACE:-zenyard}"
SS_CONTROLLER_NS="${SS_CONTROLLER_NS:-sealed-secrets}"
SS_CONTROLLER_NAME="${SS_CONTROLLER_NAME:-sealed-secrets}"
OUT_DIR="${OUT_DIR:-sealed-secrets/gcp}"
REMOTE_KUBECONFIG="/home/${GCP_USER}/.kube/config"

SSH=(ssh -i "$GCP_SSH_KEY" -o StrictHostKeyChecking=no -o BatchMode=yes
     -o ServerAliveInterval=30 -o ServerAliveCountMax=10 "${GCP_USER}@${GCP_HOST}")

prompt_secret() {  # var-name prompt-text [hidden]
  local __var="$1" __text="$2" __hidden="${3:-}" __val
  if [ -n "${!__var:-}" ]; then return; fi
  if [ -n "$__hidden" ]; then
    read -r -s -p "$__text: " __val; echo
  else
    read -r -p "$__text: " __val
  fi
  printf -v "$__var" '%s' "$__val"
}

prompt_secret DB_USER "Database username (DB_USER)"
prompt_secret DB_PASSWORD "Database password (DB_PASSWORD)" hidden
prompt_secret GRAFANA_ADMIN_USER "Grafana admin user"
prompt_secret GRAFANA_ADMIN_PASSWORD "Grafana admin password" hidden

mkdir -p "$OUT_DIR"

# seal NAME KEY=VALUE [KEY=VALUE ...]
# Builds a plaintext Secret on the remote, pipes it straight into kubeseal, and
# captures only the encrypted SealedSecret YAML. Plaintext values travel inside the
# script body over the encrypted SSH channel and are never written locally.
seal() {
  local name="$1"; shift
  local -a literals=()
  local kv
  for kv in "$@"; do literals+=(--from-literal="$kv"); done

  echo ">> Sealing ${name} -> ${OUT_DIR}/${name}.yaml"
  # shellcheck disable=SC2029  # we intentionally expand locally into the remote script
  "${SSH[@]}" "KUBECONFIG=${REMOTE_KUBECONFIG} bash -s" <<REMOTE > "${OUT_DIR}/${name}.yaml"
set -euo pipefail
kubectl create secret generic ${name} \
  --namespace ${NAMESPACE} \
  $(printf '%q ' "${literals[@]}") \
  --dry-run=client -o yaml \
| kubeseal \
    --controller-namespace ${SS_CONTROLLER_NS} \
    --controller-name ${SS_CONTROLLER_NAME} \
    --format yaml
REMOTE

  if ! grep -q "kind: SealedSecret" "${OUT_DIR}/${name}.yaml"; then
    echo "ERROR: ${OUT_DIR}/${name}.yaml is not a SealedSecret (sealing failed)." >&2
    rm -f "${OUT_DIR}/${name}.yaml"
    exit 1
  fi
}

seal "zenyard-db" "DB_USER=${DB_USER}" "DB_PASSWORD=${DB_PASSWORD}"
# Bitnami PostgreSQL keys; `password` must equal DB_PASSWORD so the app can connect.
seal "zenyard-postgresql" "postgres-password=${DB_PASSWORD}" "password=${DB_PASSWORD}"
seal "zenyard-grafana" "admin-user=${GRAFANA_ADMIN_USER}" "admin-password=${GRAFANA_ADMIN_PASSWORD}"

echo
echo "Done. Encrypted SealedSecrets written to ${OUT_DIR}/ — safe to commit."
echo "Next: make gcp-apply-sealed-secrets GCP_HOST=${GCP_HOST}  (or run gcp-deploy)."
