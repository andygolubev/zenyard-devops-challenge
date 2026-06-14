## Context

The repository is currently at the OpenSpec planning stage for the Zenyard DevOps Challenge. Phase 1 must produce a local-only development environment that behaves like the eventual Kubernetes target closely enough to validate the Helm chart, PostgreSQL deployment, observability, alerting, dashboard, and FastAPI application before any remote Ubuntu Server VM work begins.

The local environment must be disposable, fast to recreate, and suitable for a live challenge walkthrough. It will rely on developer-machine tools for orchestration and image building, and Kubernetes/Helm for everything that runs inside the cluster.

## Goals / Non-Goals

**Goals:**

- Provide a repeatable local k3d/k3s cluster named `zenyard` with ingress exposed on `localhost:8080`.
- Use local-path storage and verify Kubernetes metrics support instead of replacing k3s defaults unnecessarily.
- Package the challenge stack in a Helm chart named `zenyard`.
- Build, load, deploy, test, observe, and clean up the stack through Makefile targets.
- Deploy a single-instance PostgreSQL database with persistence, metrics, and slow query logging for statements over 1 second.
- Deploy a minimal FastAPI TODO API that uses plain SQL, reads database settings from environment variables, and runs with a non-root posture where practical.
- Create the TODO schema with an idempotent Helm post-install/post-upgrade hook Job.
- Deploy local observability for Kubernetes pod metrics, PostgreSQL metrics, PostgreSQL logs, Grafana dashboard provisioning, and a log-based slow SQL alert.
- Document the local workflow, architecture, verification steps, slow-query testing, Grafana access, and troubleshooting.

**Non-Goals:**

- No Ansible, AWS, GCP, Terraform, remote VM provisioning, external DNS, TLS, cloud registry, production HA PostgreSQL, customer start/stop scripts, or real notification integration.
- No external exposure for PostgreSQL.
- No Grafana ingress by default; access is via local port-forward.
- No production-grade backup, restore, secret-management, or HA design in Phase 1.

## Decisions

### Use k3d with default k3s components

Use `k3d cluster create zenyard --servers 1 --agents 0 -p "8080:80@loadbalancer"` and keep the default k3s ingress controller unless validation proves it unsuitable.

Rationale: k3d gives a clean disposable Kubernetes loop while preserving k3s defaults that are likely to exist in the final single-node challenge environment. Traefik and local-path storage are sufficient for Phase 1 and reduce custom moving parts.

Alternatives considered:

- Kind: common and reliable, but less representative of k3s behavior.
- Minikube: capable, but heavier and less aligned with the requested runtime.
- Replacing Traefik: unnecessary unless ingress requirements fail.

### Use Helm as the only in-cluster deployment mechanism

Create `charts/zenyard` as the parent chart and use subcharts for production-ready components where appropriate: PostgreSQL, metrics/Grafana, and logging.

Rationale: the challenge explicitly requires Helm, and subcharts keep infrastructure concerns maintainable while allowing local values to configure resource profiles and feature switches.

Alternatives considered:

- Raw manifests: simpler initially, but weaker dependency management and less aligned with the challenge.
- Docker Compose: useful for app iteration, but does not validate Kubernetes requirements.

### Prefer established subcharts for data and observability

Use a PostgreSQL Helm chart for the single database instance. Use a Prometheus/Grafana stack such as `kube-prometheus-stack` for metrics and dashboard provisioning. Use a local Loki-compatible logging stack with a collector such as Promtail or a similarly reasonable Helm-supported log collector.

Rationale: these are standard local Kubernetes building blocks, provide ServiceMonitor/PrometheusRule/Grafana provisioning patterns, and avoid writing fragile custom observability deployments.

Alternatives considered:

- Custom PostgreSQL manifests: more control, but poorer maintainability and fewer battle-tested defaults.
- Metrics-server only: satisfies `kubectl top`, but does not provide PostgreSQL metrics, dashboards, or alerting.
- File-only logs: insufficient because logs must be collected into a queryable local backend.

### Keep the app minimal but production-shaped

Implement a small FastAPI app with `GET /healthz`, `GET /todos`, `POST /todos`, and `PATCH /todos/{id}/complete`, using plain SQL through psycopg or asyncpg. Build a pinned Python image, run as a non-root user, and configure database connection details through Kubernetes Secret and ConfigMap values.

Rationale: this proves application connectivity, schema correctness, ingress, and smoke-test behavior without spending challenge time on business logic.

Alternatives considered:

- ORM-based app: faster for larger domain models, but unnecessary and less direct for schema validation.
- Shell-only database checks: validates PostgreSQL but not an application path through ingress.

### Use a Helm hook Job for schema creation

Create the TODO table in a post-install/post-upgrade Job with `CREATE TABLE IF NOT EXISTS` and Helm hook delete policies for `before-hook-creation` and `hook-succeeded`.

Rationale: this demonstrates the required idempotent schema creation behavior and keeps schema bootstrap inside the Helm release lifecycle.

Alternatives considered:

- App startup migration: common, but the challenge specifically asks for a Helm hook.
- PostgreSQL init scripts: run only on first data directory initialization and are less suitable for repeatable upgrades.

### Expose only the FastAPI app through ingress

Configure the app ingress for local HTTP on `localhost:8080` through the k3d load balancer. Keep PostgreSQL as ClusterIP only. Keep Grafana private and document port-forward access and credential retrieval.

Rationale: this matches the requested local ingress behavior while avoiding unnecessary database and observability exposure.

Alternatives considered:

- Grafana ingress: convenient, but expands exposed surface area and is not required.
- PostgreSQL NodePort: useful for manual debugging, but conflicts with the security requirements.

### Make observability optional but enabled by local defaults

Enable metrics, logs, dashboard, and alerting by default in `values-local.yaml`, while allowing observability components to be disabled or scaled down through values for constrained developer machines.

Rationale: acceptance criteria require observability, but local machines vary. Explicit switches preserve demo completeness and local usability.

Alternatives considered:

- Always-on fixed stack: simpler, but brittle on smaller machines.
- Fully optional observability by default: easier to run, but weaker against challenge acceptance criteria.

## Risks / Trade-offs

- [Risk] k3d/k3s packaged metrics-server behavior may vary by version. -> Mitigation: `make create-local` and documentation must verify `kubectl top nodes`, wait for readiness, and include a documented repair path if metrics-server is not ready.
- [Risk] Full observability stacks can be resource-heavy on a developer machine. -> Mitigation: use conservative local resource requests/limits and expose values to disable or reduce observability components.
- [Risk] PostgreSQL slow query log format may differ across chart versions. -> Mitigation: configure PostgreSQL logging explicitly and write the alert expression against the observed slow-statement log lines used by the selected chart.
- [Risk] Helm hook Jobs can fail if secrets, services, or database readiness are not available yet. -> Mitigation: make the Job wait for PostgreSQL connectivity before running SQL and ensure it is safe to rerun.
- [Risk] NetworkPolicy behavior depends on the cluster CNI enforcing it. -> Mitigation: provide practical policies without relying on them as the only local security boundary, and document local limitations if enforcement is not available.
- [Risk] Pulling multiple Helm dependencies can slow first setup. -> Mitigation: keep Make targets explicit, use pinned chart versions, and document expected first-run behavior.

## Migration Plan

This is a new local-only capability, so no data migration is required.

Implementation sequence:

1. Add app source, Dockerfile, `.dockerignore`, scripts, docs, and Makefile targets.
2. Add `charts/zenyard` with chart metadata, values, templates, and pinned dependencies.
3. Wire local image build/load and Helm deployment targets.
4. Add smoke tests and slow-query generation.
5. Verify local acceptance criteria from a clean `make delete-local && make create-local` run.

Rollback strategy:

- Run `make uninstall-local` to remove the Helm release from the local cluster.
- Run `make delete-local` to delete the disposable k3d cluster and all local Kubernetes state.
- Remove the added repository files if the change is abandoned before implementation.

## Open Questions

- Which exact Helm chart versions should be pinned during implementation after testing compatibility on the local machine?
- Should the logging stack use Grafana Loki with Promtail, or a lighter equivalent if the selected chart versions are too heavy for the demo environment?
- Should psycopg or asyncpg be used for the FastAPI database client after evaluating the smallest clean implementation?
