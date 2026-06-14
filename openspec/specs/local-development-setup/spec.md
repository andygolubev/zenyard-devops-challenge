## ADDED Requirements

### Requirement: Local cluster lifecycle
The repository SHALL provide Makefile targets to create, verify, restart, inspect, and delete a disposable local k3d cluster named `zenyard`.

#### Scenario: Create local cluster
- **WHEN** a developer runs `make create-local`
- **THEN** the command creates or prepares a k3d cluster named `zenyard` with one server, no agents, and local port mapping from `localhost:8080` to cluster ingress port `80`
- **AND** `kubectl get nodes` reports a Ready node
- **AND** local-path storage is available as a Kubernetes StorageClass
- **AND** Kubernetes metrics support is verified or a documented local remediation path is shown

#### Scenario: Delete local cluster
- **WHEN** a developer runs `make delete-local`
- **THEN** the local k3d cluster named `zenyard` is deleted if it exists
- **AND** the command succeeds when the cluster does not exist

#### Scenario: Restart local cluster
- **WHEN** a developer runs `make restart-local`
- **THEN** the local k3d cluster is recreated cleanly using the same local cluster defaults

### Requirement: Local developer commands
The repository SHALL provide Makefile targets for the full Phase 1 local loop, including tool help, cluster lifecycle, verification, image build/load, Helm dependencies, deployment, redeployment, uninstall, tests, slow-query generation, Grafana port-forwarding, logs, and local info.

#### Scenario: Required Makefile targets exist
- **WHEN** a developer inspects the Makefile
- **THEN** targets named `install-local-tools-help`, `create-local`, `delete-local`, `restart-local`, `verify-local`, `build-image-local`, `load-image-local`, `helm-deps`, `deploy-local`, `redeploy-local`, `uninstall-local`, `test-local`, `generate-slow-query`, `port-forward-grafana`, `logs-app`, `logs-postgres`, and `local-info` are present

#### Scenario: Local tooling is documented by command
- **WHEN** a developer runs `make install-local-tools-help`
- **THEN** the output explains that Docker, k3d, kubectl, Helm, Make, curl, and jq are required on the developer machine

### Requirement: Local FastAPI image workflow
The repository SHALL provide a Docker-based local image workflow for the FastAPI application.

#### Scenario: Build local image
- **WHEN** a developer runs `make build-image-local`
- **THEN** Docker builds the FastAPI image using a configurable image name
- **AND** the default image name is `zenyard-api:local`

#### Scenario: Load local image into k3d
- **WHEN** a developer runs `make load-image-local`
- **THEN** the configured FastAPI image is imported into the `zenyard` k3d cluster for use by Kubernetes

### Requirement: Helm chart packaging
The repository SHALL include a Helm chart named `zenyard` under `charts/zenyard` with local-friendly defaults and pinned dependencies for appropriate subcharts.

#### Scenario: Helm dependencies update
- **WHEN** a developer runs `make helm-deps` or `helm dependency update charts/zenyard`
- **THEN** Helm chart dependency resolution succeeds
- **AND** dependency versions are pinned in the chart metadata

#### Scenario: Local Helm values are configurable
- **WHEN** a developer inspects `charts/zenyard/values.yaml` and `charts/zenyard/values-local.yaml`
- **THEN** values exist for app image repository, tag, pull policy, replica count, resources, PostgreSQL username, password, database, persistence size, PostgreSQL resources, slow query threshold, ingress host and path, Grafana admin password or secret reference, observability enable switches, dashboard enable switch, and alert enable switch

### Requirement: Local Helm deployment
The repository SHALL deploy or upgrade the full local stack into the `zenyard` namespace through Helm.

#### Scenario: Deploy local release
- **WHEN** a developer runs `make deploy-local`
- **THEN** Helm installs or upgrades the `zenyard` chart into namespace `zenyard` using `charts/zenyard/values-local.yaml`
- **AND** the command waits for rollout where practical
- **AND** Kubernetes pods for the application, PostgreSQL, and enabled observability components reach a running or ready state

#### Scenario: Uninstall local release
- **WHEN** a developer runs `make uninstall-local`
- **THEN** the local Helm release is removed from namespace `zenyard`
- **AND** the command succeeds when the release is already absent

### Requirement: PostgreSQL local database
The local Helm deployment SHALL include a single-instance PostgreSQL database with persistence, cluster-internal access only, local-friendly resources, metrics support where chart-supported, and slow query logging for SQL statements slower than 1000 milliseconds.

#### Scenario: PostgreSQL starts with persistence
- **WHEN** the local Helm release is deployed
- **THEN** PostgreSQL runs as a single instance with persistent storage backed by local-path storage
- **AND** PostgreSQL has reasonable local resource requests and limits
- **AND** PostgreSQL is not exposed through Ingress, NodePort, or LoadBalancer

#### Scenario: Slow query logging is enabled
- **WHEN** the local Helm release is deployed
- **THEN** PostgreSQL logs statements taking longer than 1000 milliseconds
- **AND** PostgreSQL slow query logs are emitted to container logs, stdout, or stderr where the selected chart supports it

#### Scenario: PostgreSQL metrics are available
- **WHEN** observability is enabled and the selected PostgreSQL chart supports an exporter
- **THEN** PostgreSQL metrics are scraped by the local metrics stack

### Requirement: FastAPI TODO application
The repository SHALL include a minimal Python FastAPI application that uses plain SQL, reads database connection settings from environment variables, logs requests, and provides TODO endpoints.

#### Scenario: Health endpoint succeeds
- **WHEN** a developer sends `GET /healthz` to the application through local ingress
- **THEN** the application returns a successful health response

#### Scenario: TODO lifecycle works
- **WHEN** a developer creates a TODO through `POST /todos`
- **AND** lists TODOs through `GET /todos`
- **AND** marks the TODO complete through `PATCH /todos/{id}/complete`
- **THEN** the API returns successful responses backed by PostgreSQL data

#### Scenario: Application configuration avoids hardcoded secrets
- **WHEN** the application container starts
- **THEN** database host, port, name, username, and password are read from environment variables sourced from Kubernetes ConfigMaps or Secrets

### Requirement: Application Kubernetes resources
The Helm chart SHALL deploy the FastAPI app with maintainable Kubernetes resources, consistent labels, probes, security context, and ingress on `localhost:8080`.

#### Scenario: App is exposed by local ingress only
- **WHEN** the local Helm release is deployed in the k3d cluster
- **THEN** the FastAPI app is reachable through HTTP ingress at `http://localhost:8080`
- **AND** no PostgreSQL endpoint is exposed externally

#### Scenario: App pods use operational safeguards
- **WHEN** the application Deployment is rendered
- **THEN** it includes readiness and liveness probes
- **AND** it includes resource requests and limits
- **AND** it includes security settings to run as non-root where practical, disable privilege escalation, and drop Linux capabilities where practical

#### Scenario: App resources are consistently labeled
- **WHEN** Kubernetes resources are rendered by the chart
- **THEN** app-related resources include labels for `app.kubernetes.io/name`, `app.kubernetes.io/instance`, `app.kubernetes.io/component`, and `app.kubernetes.io/part-of`

### Requirement: Idempotent schema hook
The Helm chart SHALL include an idempotent post-install/post-upgrade Job that creates the TODO database schema.

#### Scenario: Schema hook creates TODO table
- **WHEN** the Helm release is installed or upgraded
- **THEN** a Kubernetes Job runs after install or upgrade to create the TODO table
- **AND** the SQL uses `CREATE TABLE IF NOT EXISTS`

#### Scenario: Schema hook is safe to rerun
- **WHEN** the Helm release is upgraded repeatedly
- **THEN** the schema hook completes without failing because the TODO table already exists
- **AND** the Job uses Helm hook annotations for `post-install`, `post-upgrade`, `before-hook-creation`, and `hook-succeeded`

### Requirement: Local observability stack
The local Helm deployment SHALL provide metrics collection, pod-level CPU and memory visibility, PostgreSQL metrics where supported, log collection, queryable PostgreSQL logs, Grafana, dashboard provisioning, and a slow SQL alert rule.

#### Scenario: Kubernetes metrics are collected
- **WHEN** the local cluster and observability stack are ready
- **THEN** pod-level CPU and memory metrics are available to the local metrics stack
- **AND** `kubectl top nodes` works after metrics-server readiness

#### Scenario: PostgreSQL logs are collected
- **WHEN** PostgreSQL emits logs in the local deployment
- **THEN** the selected logging stack collects PostgreSQL pod logs
- **AND** the logs are queryable in a local backend

#### Scenario: Grafana is available by port-forward
- **WHEN** a developer runs `make port-forward-grafana`
- **THEN** Grafana is reachable locally through kubectl port-forward
- **AND** documentation explains the default credentials or how to retrieve them

#### Scenario: Dashboard is provisioned
- **WHEN** dashboard provisioning is enabled
- **THEN** Grafana includes a dashboard showing database queries per second, mean query latency, CPU usage by database pod, and memory usage by database pod

#### Scenario: Slow SQL alert is provisioned
- **WHEN** alert provisioning is enabled
- **THEN** the observability stack includes a log-based alert rule that triggers when more than 3 SQL statements slower than 1 second occur within a 10-minute window
- **AND** no real notification integration is required

### Requirement: Slow query verification
The repository SHALL provide a local helper command and script to intentionally generate PostgreSQL slow query log entries.

#### Scenario: Generate slow query
- **WHEN** a developer runs `make generate-slow-query`
- **THEN** the command runs a SQL statement such as `SELECT pg_sleep(1.2);` against local PostgreSQL
- **AND** PostgreSQL emits slow query log entries that can be used to test log collection and the alert rule

### Requirement: Local smoke tests
The repository SHALL include smoke tests that verify the key Phase 1 local acceptance criteria after deployment.

#### Scenario: Smoke test local stack
- **WHEN** a developer runs `make test-local`
- **THEN** the test verifies the `zenyard` namespace exists
- **AND** pods are running
- **AND** PostgreSQL is ready
- **AND** `GET /healthz` works through local ingress
- **AND** TODO create, list, and complete API operations work through local ingress
- **AND** Grafana is running when observability is enabled
- **AND** Prometheus is running when the selected metrics stack is enabled
- **AND** the selected logging stack is running when log collection is enabled

### Requirement: Security and network boundaries
The local Helm deployment SHALL use Kubernetes Secrets for passwords, avoid hardcoded plaintext secrets in templates, expose only the FastAPI app through ingress, and apply practical network and pod security controls.

#### Scenario: Secrets are Kubernetes Secrets
- **WHEN** the Helm chart is rendered
- **THEN** database and Grafana passwords are stored in Kubernetes Secrets or referenced from user-provided Secrets
- **AND** plaintext passwords are not hardcoded in templates

#### Scenario: Network policies limit unnecessary traffic
- **WHEN** NetworkPolicy support is available in the local cluster
- **THEN** policies allow the FastAPI app to connect to PostgreSQL
- **AND** policies allow observability components to scrape or collect required data
- **AND** policies avoid unnecessary cross-pod access where practical

#### Scenario: App container avoids root privileges
- **WHEN** the FastAPI application pod runs
- **THEN** the application container runs as non-root where practical
- **AND** privilege escalation is disabled

### Requirement: Local documentation
The repository SHALL document the local development environment, architecture, deployment and testing workflow, slow-query alert verification, Grafana access, and troubleshooting.

#### Scenario: Developer documentation exists
- **WHEN** a developer inspects the `docs/` directory
- **THEN** `docs/local-development.md`, `docs/architecture.md`, and `docs/troubleshooting.md` exist
- **AND** they explain setup, deployment, testing, slow-query generation, Grafana access, troubleshooting, local-only scope, and relevant tradeoffs

#### Scenario: Scope exclusions are documented
- **WHEN** a developer reads the documentation
- **THEN** it is clear that Ansible, AWS, GCP, Terraform, remote VM provisioning, production HA PostgreSQL, external DNS, TLS certificates, real notification integrations, cloud container registry, and customer start/stop scripts are out of scope for Phase 1
