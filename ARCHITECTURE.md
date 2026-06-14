# Architecture

This document describes the overall architecture of the Zenyard DevOps Challenge
solution: a containerized FastAPI TODO service backed by PostgreSQL, packaged as a
Helm chart, with a built-in observability stack (Prometheus, Grafana, Loki). The
same chart runs in two environments — a local k3d cluster for development and a
remote single-node k3s VM on GCP — driven from a single Makefile.

## High-Level Overview

```text
                ┌──────────────────────────────────────────────────────────┐
                │                  Kubernetes (k3s / k3d)                    │
                │                                                            │
   HTTP :80     │   ┌─────────┐    ┌──────────────┐    ┌──────────────────┐  │
 ───────────────┼──▶│ Traefik │───▶│ FastAPI app  │───▶│   PostgreSQL     │  │
  (ingress)     │   │ ingress │    │  (zenyard)   │    │ (Bitnami chart)  │  │
                │   └─────────┘    └──────┬───────┘    └────────┬─────────┘  │
                │                         │ metrics             │ logs       │
                │                  ┌──────▼───────┐      ┌───────▼────────┐  │
                │                  │  Prometheus  │      │ Promtail/Loki  │  │
                │                  └──────┬───────┘      └───────┬────────┘  │
                │                         └──────────┬───────────┘           │
                │                              ┌─────▼──────┐                 │
                │                              │  Grafana   │ (port-forward)  │
                │                              └────────────┘                 │
                └──────────────────────────────────────────────────────────┘
```

## Components

### Application — `app/`

A small FastAPI service (`app/main.py`) exposing a TODO REST API:

| Method | Path | Purpose |
|--------|------|---------|
| `GET`  | `/healthz` | Liveness/readiness — runs `SELECT 1` against PostgreSQL |
| `GET`  | `/todos` | List all todos |
| `POST` | `/todos` | Create a todo |
| `PATCH`| `/todos/{id}/complete` | Mark a todo complete |

Key properties:

- Connects to PostgreSQL via `psycopg` using connection settings injected from the
  environment (`DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`).
- An HTTP middleware logs every request with method, path, status and duration —
  these structured logs are collected by Promtail.
- Maps DB configuration errors to `500` and DB connectivity errors to `503`, so the
  health check reflects real database reachability.
- Containerized via `app/Dockerfile`; the image runs as a non-root user with a
  read-only root filesystem where practical.

### Helm chart — `charts/zenyard/`

The parent chart bundles the application and its supporting infrastructure. It
deploys:

- The Zenyard FastAPI app (`app-deployment.yaml`, `app-service.yaml`,
  `app-ingress.yaml`, `app-configmap.yaml`, `app-secret.yaml`).
- A single-instance **PostgreSQL** via the Bitnami subchart.
- **kube-prometheus-stack** for Prometheus, Grafana, and Kubernetes metrics.
- **loki-stack** for log storage (Loki) and collection (Promtail).
- An idempotent **schema-init Job** (`postgres-init-job.yaml`) that runs as a Helm
  post-install/post-upgrade hook and creates the `todos` table with
  `CREATE TABLE IF NOT EXISTS`. Hook delete policies (`before-hook-creation`,
  `hook-succeeded`) make repeated upgrades safe.
- Observability provisioning: a `ServiceMonitor`, Grafana dashboard ConfigMaps, and
  Prometheus/Loki alert rules.
- `NetworkPolicy` resources scoping app↔database and observability traffic.

Chart dependencies are pinned in `charts/zenyard/Chart.yaml`:

| Dependency | Version | Toggle |
|------------|---------|--------|
| `postgresql` (Bitnami) | 18.7.3 | `postgresql.enabled` |
| `kube-prometheus-stack` | 86.2.3 | `observability.metrics.enabled` |
| `loki-stack` | 2.10.3 | `observability.logs.enabled` |

Values are layered:

- `values.yaml` — chart defaults.
- `values-local.yaml` — local k3d overrides.
- `values-gcp.yaml` — GCP VM overrides (image tag `gcp`, credentials referenced via
  `existingSecret` from Sealed Secrets — no plaintext passwords, wildcard ingress host,
  Prometheus operator TLS disabled, Prometheus retention 6h).

### Request & data flow

Traffic enters through HTTP ingress on port 80:

```text
client → (k3d load balancer | VM :80) → Traefik → FastAPI Service → FastAPI Pod
```

The app reaches PostgreSQL only over the internal ClusterIP service:

```text
FastAPI Pod → zenyard-postgresql:5432 → PostgreSQL Pod
```

PostgreSQL is **never** exposed through Ingress, NodePort, or LoadBalancer.

### Observability

- **Prometheus** scrapes Kubernetes and PostgreSQL metrics (via the `ServiceMonitor`).
- **Loki + Promtail** store and collect pod logs, including PostgreSQL logs.
  PostgreSQL is configured to log statements slower than 1000ms
  (`log_min_duration_statement = 1000`).
- **Grafana** (kept private — accessed via `kubectl port-forward` / SSH tunnel)
  provisions two dashboards:
  - *Zenyard Database Activity* — query activity, latency proxy, DB pod CPU/memory.
  - *Zenyard SQL Transactions* — Loki-backed view of the slow SQL statements
    themselves (time series, top statements, raw log panel).
- A **log-based alert** fires on more than 3 slow-SQL log entries in a 10-minute
  window, querying the same Loki selector as the SQL Transactions dashboard.

## Deployment Environments

### Local — k3d

- `k3d` runs `k3s` in Docker. Cluster `zenyard`: one server, zero agents.
- Uses k3s built-in local-path storage, Traefik ingress, and metrics-server.
- `localhost:8080` is port-mapped to the cluster ingress (port 80).
- The cluster is disposable; deleting it removes all state including PostgreSQL PVs.

Driven by the `*-local` Makefile targets (`make create-local`, `redeploy-local`,
`test-local`, …). See `docs/local-development.md`.

### Remote — GCP VM with k3s

- A manually-created Ubuntu Server VM runs a single-node `k3s` cluster.
- **Ansible** (`ansible/playbook.yml`) bootstraps and deploys, organized as roles:

  | Role | Responsibility |
  |------|----------------|
  | `common` | apt packages |
  | `k3s` | install k3s, wait for Ready, set up kubeconfig for the SSH user |
  | `helm` | install Helm |
  | `image` | build image locally, save, copy to VM, import into containerd |
  | `deploy` | rsync chart to VM, add Helm repos, `helm upgrade --install` with `values-gcp.yaml` |
  | `verify` | nodes, storageclass, pods, metrics-server, Helm releases, ingress |

- Images are shipped **without a registry**: built locally for `linux/amd64`,
  `docker save`d, copied over SSH, and imported into k3s containerd via
  `k3s ctr images import`. Pods use `pullPolicy: IfNotPresent`.
- Driven by the `gcp-*` Makefile targets. See `docs/gcp-deployment.md` and the
  README for the full setup walkthrough.

## Security Boundaries

- Passwords are stored as Kubernetes Secrets. On GCP they are managed with **Bitnami
  Sealed Secrets instead of Google Secret Manager**: a controller in the cluster holds
  the private key, `kubeseal` encrypts each `Secret` into a `SealedSecret` that only that
  controller can decrypt, so the encrypted YAML is committed to git (`sealed-secrets/gcp/`)
  with no plaintext. `values-gcp.yaml` consumes the unsealed Secrets via `existingSecret`.
  This avoids any cloud-provider API/IAM dependency while keeping secrets out of git in
  the clear. The local k3d workflow still uses inline demo passwords in `values-local.yaml`.
  See [`sealed-secrets/README.md`](sealed-secrets/README.md).
- The app container runs as non-root, disables privilege escalation, drops Linux
  capabilities, and uses a read-only root filesystem where practical.
- `NetworkPolicy` scopes app↔DB and observability traffic. Enforcement depends on
  the cluster CNI; k3s defaults may not enforce every policy like a production CNI.
- Externally, only port 22 (SSH/Ansible) and optionally port 80 (FastAPI) are
  opened on the VM. PostgreSQL (5432), Grafana (3000), and the k3s API (6443) stay
  cluster-internal and are reached only via SSH tunnels / port-forward.

## Tooling Layout

```text
app/                  FastAPI service + Dockerfile
charts/zenyard/       Helm chart (templates + layered values)
ansible/              Playbook + roles for GCP VM bootstrap & deploy
sealed-secrets/gcp/   Committed encrypted SealedSecrets for the remote cluster
scripts/              Smoke tests, stress test, slow-query generator, secret sealing
docs/                 Detailed local / GCP / troubleshooting guides
Makefile              Single entrypoint for local and GCP workflows
```

## Tradeoffs

The solution favors a reliable, reproducible demo loop over production completeness.
It reuses established Helm charts (Bitnami PostgreSQL, kube-prometheus-stack,
loki-stack) to minimize bespoke Kubernetes code, and ships images over SSH to avoid
standing up a registry. Observability is on by default to satisfy acceptance
criteria but can be disabled via Helm values on resource-constrained machines.

Out of scope: HA/replicated PostgreSQL, a container registry, external DNS, TLS
termination, real alert-notification integrations, and Terraform-based VM
provisioning (the GCP VM is created manually).
</content>
</invoke>
