## 1. Repository Structure and Local Command Skeleton

- [x] 1.1 Add `Makefile` with configurable variables for cluster name, namespace, release name, chart path, local values file, image name, and ingress URL.
- [x] 1.2 Add all required Makefile targets: `install-local-tools-help`, `create-local`, `delete-local`, `restart-local`, `verify-local`, `build-image-local`, `load-image-local`, `helm-deps`, `deploy-local`, `redeploy-local`, `uninstall-local`, `test-local`, `generate-slow-query`, `port-forward-grafana`, `logs-app`, `logs-postgres`, and `local-info`.
- [x] 1.3 Implement `create-local` with k3d cluster creation using one server, no agents, and `8080:80@loadbalancer` port mapping.
- [x] 1.4 Implement cluster verification commands for kubectl connectivity, Ready node status, local-path StorageClass availability, and metrics-server or `kubectl top nodes` readiness.
- [x] 1.5 Implement idempotent cleanup behavior for `delete-local` and `uninstall-local`.

## 2. FastAPI Application

- [x] 2.1 Create `app/requirements.txt` with pinned FastAPI, ASGI server, PostgreSQL client, and supporting runtime dependencies.
- [x] 2.2 Create `app/main.py` with `GET /healthz`, `GET /todos`, `POST /todos`, and `PATCH /todos/{id}/complete` using plain SQL and environment-based database configuration.
- [x] 2.3 Add basic application error handling for database connection failures, missing TODO records, invalid input, and failed writes.
- [x] 2.4 Add simple readable or structured request logging.
- [x] 2.5 Create `app/Dockerfile` using a pinned Python base image, small runtime footprint, non-root user, and suitable startup command.
- [x] 2.6 Add `.dockerignore` to keep local, Git, cache, and generated files out of the application image.
- [x] 2.7 Wire `build-image-local` to build the configurable FastAPI image, defaulting to `zenyard-api:local`.
- [x] 2.8 Wire `load-image-local` to import the configured image into the `zenyard` k3d cluster.

## 3. Helm Chart Foundation

- [x] 3.1 Create `charts/zenyard/Chart.yaml` with chart name `zenyard` and pinned dependency versions for PostgreSQL, metrics/Grafana, and logging subcharts.
- [x] 3.2 Create `charts/zenyard/values.yaml` with documented defaults for app image, replicas, resources, ingress, PostgreSQL, slow query threshold, Grafana, observability switches, dashboard switch, and alert switch.
- [x] 3.3 Create `charts/zenyard/values-local.yaml` with local-friendly defaults, local image settings, ingress on localhost, small persistence, modest resource requests/limits, and enabled observability defaults.
- [x] 3.4 Implement `helm-deps` to run `helm dependency update charts/zenyard`.
- [x] 3.5 Implement `deploy-local` to install or upgrade the Helm release into namespace `zenyard` with `values-local.yaml` and wait behavior where practical.
- [x] 3.6 Implement `redeploy-local` to build, load, update dependencies as needed, and redeploy the local release.

## 4. Application Kubernetes Resources

- [x] 4.1 Add `templates/app-configmap.yaml` for non-secret app configuration such as database host, port, name, and log settings.
- [x] 4.2 Add `templates/app-secret.yaml` for database credentials, supporting generated local defaults and user-provided overrides without hardcoding plaintext secrets in templates.
- [x] 4.3 Add `templates/app-deployment.yaml` with labels, resource requests/limits, probes, env vars from ConfigMap and Secret, and pod/container security contexts.
- [x] 4.4 Add `templates/app-service.yaml` exposing the FastAPI pod only inside the cluster.
- [x] 4.5 Add `templates/app-ingress.yaml` exposing the FastAPI service through local HTTP ingress on the configured host/path.
- [x] 4.6 Ensure app-related resources include `app.kubernetes.io/name`, `app.kubernetes.io/instance`, `app.kubernetes.io/component`, and `app.kubernetes.io/part-of` labels.

## 5. PostgreSQL and Schema Initialization

- [x] 5.1 Configure the PostgreSQL subchart for single-instance deployment, local-path persistence, internal-only service exposure, local credentials, resource requests/limits, and small persistence size.
- [x] 5.2 Configure PostgreSQL slow query logging for statements slower than the configurable threshold, defaulting to 1000ms.
- [x] 5.3 Configure PostgreSQL logs to be emitted to container logs, stdout, or stderr where the selected chart supports it.
- [x] 5.4 Enable PostgreSQL metrics exporter support where available in the selected chart.
- [x] 5.5 Add `templates/postgres-init-job.yaml` as a Helm post-install/post-upgrade hook Job that waits for PostgreSQL readiness and creates the TODO table with `CREATE TABLE IF NOT EXISTS`.
- [x] 5.6 Add hook annotations for `post-install`, `post-upgrade`, `before-hook-creation`, and `hook-succeeded`.
- [x] 5.7 Verify repeated Helm upgrades do not fail when the TODO table already exists.

## 6. Observability, Dashboard, and Alerting

- [x] 6.1 Configure the metrics stack to collect Kubernetes pod-level CPU and memory metrics.
- [x] 6.2 Configure PostgreSQL metrics scraping through ServiceMonitor or the selected stack's equivalent mechanism.
- [x] 6.3 Add `templates/servicemonitor.yaml` if the parent chart must provide an explicit ServiceMonitor for app or PostgreSQL scraping.
- [x] 6.4 Configure the logging stack to collect PostgreSQL pod logs into a queryable local backend.
- [x] 6.5 Add `templates/grafana-dashboard-configmap.yaml` to provision a Grafana dashboard showing queries per second, mean query latency, database pod CPU usage, and database pod memory usage.
- [x] 6.6 Add `templates/alert-rules.yaml` to provision a log-based alert for more than 3 SQL statements slower than 1 second within 10 minutes.
- [x] 6.7 Keep Grafana private by default and implement `port-forward-grafana` for local access.
- [x] 6.8 Expose values to enable or disable observability, dashboard, and alert provisioning for constrained local machines.

## 7. Security and Network Policy

- [x] 7.1 Add `templates/networkpolicy.yaml` allowing FastAPI to connect to PostgreSQL and observability components to scrape or collect required data while avoiding unnecessary cross-pod access where practical.
- [x] 7.2 Ensure PostgreSQL is not exposed by Ingress, NodePort, or LoadBalancer.
- [x] 7.3 Ensure Grafana is not exposed by Ingress by default.
- [x] 7.4 Ensure app containers run as non-root where practical, disable privilege escalation, use a read-only root filesystem where practical, and drop Linux capabilities where practical.
- [x] 7.5 Avoid cluster-admin permissions for app components and add least-privilege service accounts only where custom service accounts are needed.

## 8. Local Test and Utility Scripts

- [x] 8.1 Create `scripts/smoke-test-local.sh` to verify namespace existence, running pods, PostgreSQL readiness, FastAPI health, TODO create/list/complete behavior, ingress response, Grafana pod, Prometheus pod when enabled, and logging stack pods when enabled.
- [x] 8.2 Create `scripts/generate-slow-query.sh` to run `SELECT pg_sleep(1.2);` or an equivalent configurable slow SQL statement against local PostgreSQL.
- [x] 8.3 Wire `make test-local` to execute `scripts/smoke-test-local.sh`.
- [x] 8.4 Wire `make generate-slow-query` to execute `scripts/generate-slow-query.sh`.
- [x] 8.5 Implement `logs-app`, `logs-postgres`, and `local-info` with useful kubectl output for live debugging.

## 9. Documentation

- [x] 9.1 Create `docs/local-development.md` covering required tools, setup, cluster lifecycle, image build/load, Helm dependency update, deployment, smoke tests, slow-query generation, Grafana port-forwarding, credentials, and cleanup.
- [x] 9.2 Create `docs/architecture.md` explaining the local k3d/k3s architecture, Helm chart structure, app/database flow, ingress, storage, observability, alerting, security boundaries, and local-only tradeoffs.
- [x] 9.3 Create `docs/troubleshooting.md` covering common Docker, k3d, kubectl, Helm, metrics-server, ingress, PostgreSQL, schema hook, observability, Grafana, and resource-limit issues.
- [x] 9.4 Document that Ansible, AWS, GCP, Terraform, remote VM provisioning, production HA PostgreSQL, external DNS, TLS certificates, real notification integrations, cloud registry, and customer start/stop scripts are out of scope for Phase 1.

## 10. Validation

- [x] 10.1 Run `make create-local` and verify the `zenyard` node is Ready.
- [x] 10.2 Run `kubectl get storageclass` and verify local-path storage exists.
- [x] 10.3 Run `kubectl top nodes` after metrics-server readiness and verify node metrics work or document the local remediation.
- [x] 10.4 Run `make build-image-local` and verify `zenyard-api:local` is built by default.
- [x] 10.5 Run `make load-image-local` and verify the image is available in the k3d cluster.
- [x] 10.6 Run `make helm-deps` and verify `helm dependency update charts/zenyard` succeeds.
- [x] 10.7 Run `make deploy-local` and verify the Helm release installs into namespace `zenyard`.
- [x] 10.8 Verify PostgreSQL starts with persistence, is not externally exposed, and has slow query logging enabled.
- [x] 10.9 Verify the schema hook creates the TODO table and remains safe across repeated upgrades.
- [x] 10.10 Run `curl http://localhost:8080/healthz` and verify success.
- [x] 10.11 Run `make test-local` and verify TODO create/list/complete behavior through ingress.
- [x] 10.12 Run `make generate-slow-query` and verify PostgreSQL slow query log entries are collected by the logging stack.
- [x] 10.13 Verify PostgreSQL metrics, Kubernetes pod metrics, Grafana dashboard provisioning, and slow SQL alert rule provisioning.
- [x] 10.14 Run `make port-forward-grafana` and verify Grafana can be reached locally.
- [x] 10.15 Run `make delete-local && make create-local` and verify the setup can be deleted and recreated cleanly.
