# Architecture

## Local Cluster

The local runtime is k3d running k3s. The cluster is named `zenyard` and uses:

- one k3s server
- zero agents
- k3s local-path storage
- k3s Traefik ingress
- local port mapping from `localhost:8080` to cluster ingress port 80

The cluster is disposable. Deleting it removes local Kubernetes state, including PostgreSQL persistent volumes.

## Helm Chart

The parent chart is `charts/zenyard`.

It deploys:

- the Zenyard FastAPI TODO app
- a single-instance PostgreSQL database through the Bitnami PostgreSQL chart
- kube-prometheus-stack for Prometheus, Grafana, and Kubernetes metrics
- Loki stack for log storage and Promtail log collection
- an idempotent schema hook Job
- dashboard and alert provisioning ConfigMaps
- practical NetworkPolicies for local boundaries

Helm dependencies are pinned in `Chart.yaml`.

## Application Flow

Traffic enters through local HTTP ingress:

```text
localhost:8080 -> k3d load balancer -> Traefik -> FastAPI Service -> FastAPI Pod
```

The FastAPI app connects to PostgreSQL through the internal ClusterIP service:

```text
FastAPI Pod -> zenyard-postgresql:5432 -> PostgreSQL Pod
```

PostgreSQL is not exposed through Ingress, NodePort, or LoadBalancer.

## Database Schema

The TODO schema is created by a Helm post-install/post-upgrade Job. The Job waits for PostgreSQL readiness and runs idempotent SQL:

```sql
CREATE TABLE IF NOT EXISTS todos (...);
```

The hook uses delete policies for `before-hook-creation` and `hook-succeeded`, making repeated upgrades safe.

## Observability

Prometheus collects Kubernetes and PostgreSQL metrics. Grafana is deployed by kube-prometheus-stack and kept private by default. Access is through `kubectl port-forward`.

Loki stores logs locally and Promtail collects pod logs, including PostgreSQL logs. PostgreSQL slow query logging is configured for statements slower than 1000ms.

Grafana provisions a "Zenyard Database Activity" dashboard with:

- database query activity
- mean latency proxy based on database timing metrics
- database pod CPU usage
- database pod memory usage

Grafana also provisions a "Zenyard SQL Transactions" dashboard, backed by Loki, for inspecting the slow SQL statements themselves: a time series of slow statements over a 10-minute window, a table of the most frequent slow statements, and a logs panel showing the raw statement text. This is the dashboard to open when the slow-SQL alert fires.

Grafana also provisions a log-based alert for more than 3 slow SQL log entries in a 10-minute window. It queries the same Loki selector as the "Zenyard SQL Transactions" dashboard, so the two always agree. No notification integration is configured in Phase 1.

## Security Boundaries

Local development uses Kubernetes Secrets for passwords. The default passwords in local values are intentionally simple and must be overridden outside local demos.

On the remote GCP cluster, credentials are managed with **Bitnami Sealed Secrets instead of Google Secret Manager**. A controller in the cluster holds an RSA private key; `kubeseal` encrypts each `Secret` into a `SealedSecret` that only that controller can decrypt, so the encrypted manifests are committed to git (`sealed-secrets/gcp/`) with no plaintext, and `values-gcp.yaml` consumes the unsealed Secrets via `existingSecret`. This keeps secrets in git as the source of truth without exposing them in the clear and without any cloud-provider secret-manager API or IAM dependency. See `sealed-secrets/README.md`.

The app container runs as a non-root user, disables privilege escalation, drops Linux capabilities, and uses a read-only root filesystem where practical.

NetworkPolicy is included for app-to-database traffic and observability access. Enforcement depends on the local cluster CNI; k3s defaults may not enforce every policy in the same way as a production CNI.

## Tradeoffs

The setup favors a reliable two-hour challenge/demo loop over production completeness. It uses established Helm charts for PostgreSQL and observability to reduce custom Kubernetes code. Observability is enabled by default for acceptance criteria, but Helm values allow it to be disabled when local machines are resource constrained.

Out of scope: Ansible, AWS, GCP, Terraform, remote VM provisioning, HA PostgreSQL, external DNS, TLS, real notification integrations, cloud registries, and customer start/stop scripts.
