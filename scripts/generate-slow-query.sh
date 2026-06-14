#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-zenyard}"
RELEASE_NAME="${RELEASE_NAME:-zenyard}"
DB_SECRET="${DB_SECRET:-${RELEASE_NAME}-zenyard-db}"
DB_HOST="${DB_HOST:-zenyard-postgresql}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-zenyard}"
SQL="${SQL:-SELECT pg_sleep(1.2);}"
POD_NAME="zenyard-slow-query-$(date +%s)"

DB_USER="$(kubectl get secret -n "${NAMESPACE}" "${DB_SECRET}" -o jsonpath='{.data.DB_USER}' | base64 -d)"
DB_PASSWORD="$(kubectl get secret -n "${NAMESPACE}" "${DB_SECRET}" -o jsonpath='{.data.DB_PASSWORD}' | base64 -d)"

kubectl run "${POD_NAME}" \
  --namespace "${NAMESPACE}" \
  --rm \
  -i \
  --restart=Never \
  --image=postgres:17.2-alpine \
  --env="PGHOST=${DB_HOST}" \
  --env="PGPORT=${DB_PORT}" \
  --env="PGDATABASE=${DB_NAME}" \
  --env="PGUSER=${DB_USER}" \
  --env="PGPASSWORD=${DB_PASSWORD}" \
  --command -- sh -ec "psql -v ON_ERROR_STOP=1 -c '${SQL}'"

printf '%s\n' 'Slow query generated. Check PostgreSQL logs and Grafana/Loki alert state.'
