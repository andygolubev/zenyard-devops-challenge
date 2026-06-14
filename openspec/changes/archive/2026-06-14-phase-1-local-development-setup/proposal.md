## Why

The Zenyard DevOps Challenge needs a fast, repeatable local Kubernetes loop before any remote Ubuntu VM work begins. This change establishes a disposable k3d/k3s environment so the Helm chart, PostgreSQL, FastAPI app, ingress, metrics, logs, alerts, and Grafana dashboard can be developed and verified locally.

## What Changes

- Add a local-only k3d cluster workflow for creating, deleting, restarting, verifying, and inspecting a cluster named `zenyard`.
- Add Makefile targets for local tool guidance, cluster lifecycle, image build/load, Helm dependency management, deployment, smoke tests, slow-query generation, Grafana port-forwarding, logs, and cleanup.
- Add a Helm chart named `zenyard` with local values, pinned dependencies, maintainable templates, and configurable values for app, PostgreSQL, ingress, observability, dashboard, and alerts.
- Deploy a single-instance PostgreSQL database with local-path persistence, local-friendly resources, metrics exporter support, and slow query logging for statements slower than 1 second.
- Add a minimal non-root Python FastAPI app using plain SQL and environment-based database configuration.
- Expose only the FastAPI app through local HTTP ingress on `localhost:8080`.
- Add an idempotent Helm post-install/post-upgrade schema creation Job for a simple TODO table.
- Deploy a local observability stack for pod metrics, PostgreSQL metrics, log collection, Grafana, a database activity dashboard, and a log-based slow SQL alert.
- Add smoke test and slow query helper scripts.
- Add developer documentation for setup, deployment, validation, Grafana access, slow-query verification, architecture, and troubleshooting.
- Exclude Ansible, AWS, GCP, Terraform, remote VM provisioning, production HA PostgreSQL, external DNS, TLS, real notification integrations, cloud registries, and customer start/stop scripts.

## Capabilities

### New Capabilities

- `local-development-setup`: Defines the required local Kubernetes development environment, Helm-deployed challenge stack, smoke tests, observability, alerting, and documentation for Phase 1.

### Modified Capabilities

- None.

## Impact

- Adds repository-local development artifacts: `Makefile`, `app/`, `charts/zenyard/`, `scripts/`, and `docs/`.
- Introduces local tool expectations for Docker, k3d, kubectl, Helm, Make, curl, and jq.
- Adds Helm dependencies for PostgreSQL and local observability components.
- Adds local Kubernetes resources for the FastAPI app, PostgreSQL, schema initialization, ingress, metrics scraping, log-based alerting, dashboard provisioning, secrets, and network policy.
- Establishes acceptance criteria for local cluster creation, deployment, API behavior, PostgreSQL readiness, slow query logging, metrics, log collection, Grafana dashboard availability, alert provisioning, security posture, and clean recreation.
