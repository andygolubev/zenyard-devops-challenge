## ADDED Requirements

### Requirement: VM bootstrap via Ansible
The system SHALL provide an idempotent, rerun-safe Ansible playbook (`ansible/playbook.yml`) that bootstraps a clean Ubuntu Server VM on Google Cloud into a single-node k3s host, runnable through `make gcp-bootstrap` against a user-supplied `ansible/inventory.gcp.ini`. The playbook SHALL use `become: true` only where root is required and SHALL be safe to rerun without breaking an existing cluster.

#### Scenario: Bootstrap a clean VM
- **WHEN** an operator runs `make gcp-bootstrap` against a clean Ubuntu VM listed in `ansible/inventory.gcp.ini`
- **THEN** the playbook installs required OS packages, installs k3s, installs Helm, configures kubectl access for the SSH user, and completes without error

#### Scenario: Rerunning the playbook is safe
- **WHEN** an operator reruns `make gcp-bootstrap` against a VM that is already bootstrapped
- **THEN** the run completes successfully, makes no destructive changes, and leaves the cluster and its workloads running

### Requirement: OS package preparation
The `common` role SHALL update the apt cache and install a minimal, justified set of packages required for k3s, image handling, and verification: `curl`, `ca-certificates`, `gnupg`, `jq`, `make`, `python3`, `python3-pip`, `python3-venv`, `tar`, `gzip`, `unzip`, and the networking packages (e.g. `iptables`) k3s requires.

#### Scenario: Required packages present after common role
- **WHEN** the `common` role has run on a clean VM
- **THEN** `curl`, `jq`, `tar`, and the other listed packages are installed and available on the host

### Requirement: k3s installation with required cluster primitives
The `k3s` role SHALL install k3s (at a pinned/configurable version) on the VM with the local-path storage provisioner, Traefik HTTP ingress controller, and metrics-server enabled (k3s defaults retained unless there is a documented reason to change them). It SHALL ensure the k3s service is enabled and running, wait for the Kubernetes API to be ready, and wait for the node to reach `Ready`, using retries.

#### Scenario: Single Ready node with required components
- **WHEN** the `k3s` role completes
- **THEN** `kubectl get nodes` shows exactly one node in `Ready` state
- **AND** `kubectl get storageclass` lists `local-path`
- **AND** the Traefik ingress controller and metrics-server are running

#### Scenario: Node metrics available
- **WHEN** metrics-server has become ready after the `k3s` role completes
- **THEN** `kubectl top nodes` returns node CPU and memory metrics

### Requirement: kubectl access for the SSH user without sudo
The `k3s` role SHALL configure kubeconfig for the SSH user (copying the k3s admin kubeconfig to the user's `~/.kube/config` with correct ownership) so that normal `kubectl` usage does not require sudo after bootstrap.

#### Scenario: SSH user runs kubectl directly
- **WHEN** the SSH user runs `kubectl get nodes` after bootstrap without sudo
- **THEN** the command succeeds against the local k3s cluster

### Requirement: Helm installation
The `helm` role SHALL install Helm (at a pinned/configurable version) on the VM and verify the installation.

#### Scenario: Helm usable after bootstrap
- **WHEN** the `helm` role completes
- **THEN** `helm version` succeeds on the VM

### Requirement: Registry-free image delivery to k3s
The system SHALL make the FastAPI image available to the remote k3s containerd without requiring an external registry, using a build-local / save / copy / import workflow. `make gcp-build-image` SHALL build the image (default `zenyard-api:gcp`, with configurable name and tag). `make gcp-load-image` (and the `image` role) SHALL save the image to a tar, copy it to the VM, import it into k3s containerd via `k3s ctr images import`, verify the image exists in containerd, and remove the temporary tar archive where practical.

#### Scenario: Build the FastAPI image
- **WHEN** an operator runs `make gcp-build-image`
- **THEN** a Docker image named `zenyard-api:gcp` (or the configured name/tag) is built locally

#### Scenario: Image imported into remote containerd
- **WHEN** an operator runs `make gcp-load-image` after building the image
- **THEN** the image tar is copied to the VM and imported into k3s containerd
- **AND** the image is listed by `k3s ctr images list`
- **AND** the temporary tar archive is removed where practical

### Requirement: Deploy the existing zenyard chart with a GCP overlay
The system SHALL deploy the existing Phase 1 `zenyard` Helm chart unchanged in architecture, using a new `charts/zenyard/values-gcp.yaml` overlay, into the `zenyard` namespace on the remote cluster. `make gcp-deploy` (and the `deploy` role) SHALL add/update required Helm repositories, run `helm dependency update` when needed, perform `helm upgrade --install`, set the app image repository/tag/pullPolicy for the imported image, and wait for key workloads to roll out where reasonable. The overlay SHALL set `app.image.repository: zenyard-api`, `app.image.tag: gcp`, and `app.image.pullPolicy: IfNotPresent`.

#### Scenario: Deploy or upgrade the release
- **WHEN** an operator runs `make gcp-deploy` after the image is imported
- **THEN** the `zenyard` Helm release is installed or upgraded in the `zenyard` namespace using `values-gcp.yaml`
- **AND** `helm list -A` shows the release as deployed

#### Scenario: PostgreSQL deployed with persistence and schema hook
- **WHEN** the deploy completes
- **THEN** PostgreSQL is running with a bound local-path PersistentVolumeClaim
- **AND** the schema init hook Job has completed successfully and is idempotent on rerun
- **AND** FastAPI connects to PostgreSQL

#### Scenario: Redeploy chains build, load, and deploy
- **WHEN** an operator runs `make gcp-redeploy`
- **THEN** the image is rebuilt, re-imported into remote containerd, and the release is upgraded

### Requirement: Remote verification of the deployment
The `verify` role and `make gcp-test` (via `scripts/smoke-test-remote.sh`) SHALL verify the remote deployment with clear, demo-legible commands and appropriate retries/waits. Verification SHALL confirm: remote kubectl connectivity, the `zenyard` namespace exists, pods are running, PostgreSQL is ready, the schema init hook completed, the FastAPI health endpoint works through ingress, TODO API endpoints work, Grafana is running, the metrics stack is running, the logging stack is running, and slow-query generation produces PostgreSQL log entries.

#### Scenario: Full remote smoke test passes
- **WHEN** an operator runs `make gcp-test` after a successful deploy
- **THEN** all verification checks pass: namespace, running pods, PostgreSQL readiness, schema hook completion, FastAPI `/healthz` through ingress, TODO create/list/complete, and presence of Grafana, metrics, and logging pods

#### Scenario: Verify role surfaces cluster state
- **WHEN** the `verify` role runs
- **THEN** it reports the output of `kubectl get nodes`, `kubectl get storageclass`, `kubectl get pods -A`, `kubectl top nodes`, `helm list -A`, and `kubectl get ingress -n zenyard`

#### Scenario: Slow-query generation creates log entries
- **WHEN** an operator runs `make gcp-generate-slow-query`
- **THEN** a slow query is executed against PostgreSQL
- **AND** corresponding slow-query entries appear in the PostgreSQL logs and are collected by the logging stack

### Requirement: Network exposure and security posture
The deployment SHALL expose only the FastAPI app over HTTP ingress. PostgreSQL SHALL remain cluster-internal and SHALL NOT be exposed outside the cluster. Grafana SHALL NOT be publicly exposed by default; access SHALL be provided only via SSH tunnel or `kubectl port-forward` through `make gcp-port-forward-grafana`. SSH SHALL be the only required administrative entry point. The deployment SHALL preserve the Phase 1 security best practices: Kubernetes Secrets for app/database credentials, `runAsNonRoot`, `allowPrivilegeEscalation: false`, dropped Linux capabilities, `readOnlyRootFilesystem` where practical, NetworkPolicy where supported, resource requests/limits, and no cluster-admin for app workloads. Demo secrets MAY be supplied through values for the challenge, and documentation SHALL state that real deployments must override them.

#### Scenario: Only FastAPI is publicly reachable
- **WHEN** the deployment is running and firewall rules per the documentation are applied
- **THEN** FastAPI is reachable through the VM public IP over HTTP ingress
- **AND** PostgreSQL is not reachable from outside the cluster
- **AND** Grafana is not reachable on any public port

#### Scenario: Grafana reached only through a tunnel
- **WHEN** an operator runs `make gcp-port-forward-grafana`
- **THEN** Grafana becomes reachable on a local port via SSH tunnel or `kubectl port-forward`
- **AND** no public port is opened for Grafana

#### Scenario: Credentials stored as Secrets
- **WHEN** the release is deployed
- **THEN** app and database credentials are stored in Kubernetes Secrets, not hardcoded in plain manifests

### Requirement: GCP configuration isolated from local configuration
GCP-specific differences SHALL be confined to the Ansible inventory, `group_vars`, and `charts/zenyard/values-gcp.yaml`. The Phase 1 local workflow (local Make targets, `values-local.yaml`, local scripts, and the chart templates) SHALL remain unchanged. The repository SHALL provide `ansible/inventory.gcp.ini.example`; the real `inventory.gcp.ini` is supplied by the operator.

#### Scenario: Local workflow unaffected
- **WHEN** an operator runs the Phase 1 local targets after Phase 2 is added
- **THEN** the local k3d workflow behaves exactly as before, with no changes to chart templates, `values.yaml`, or `values-local.yaml`

#### Scenario: GCP differences live only in overlay and inventory
- **WHEN** reviewing the change
- **THEN** GCP-specific configuration appears only in `ansible/` inventory and `group_vars` and in `charts/zenyard/values-gcp.yaml`

### Requirement: GCP deployment documentation
The repository SHALL include `docs/gcp-deployment.md` documenting the final GCP deployment flow: prerequisites, recommended VM sizing (`e2-standard-4` preferred, `e2-standard-2` tight, 40–60 GB disk), required firewall rules (SSH 22 from developer IP, HTTP 80 only if public testing is needed, never PostgreSQL, never Grafana), inventory setup, the bootstrap → deploy → test flow, safe Grafana access, troubleshooting, and cleanup. Troubleshooting SHALL cover SSH problems, GCP firewall not allowing HTTP 80, node not Ready, metrics-server not ready, image pull errors, ingress not reachable, pods pending due to memory, Helm timeout, and local-path PVC issues.

#### Scenario: Documentation covers the full flow
- **WHEN** an operator reads `docs/gcp-deployment.md`
- **THEN** it explains prerequisites, VM sizing, firewall rules, inventory setup, bootstrap, deploy, test, Grafana access, troubleshooting, and cleanup

### Requirement: GCP Makefile targets
The `Makefile` SHALL provide additive GCP targets: `gcp-bootstrap`, `gcp-verify-k3s`, `gcp-build-image`, `gcp-load-image`, `gcp-helm-deps`, `gcp-deploy`, `gcp-redeploy`, `gcp-test`, `gcp-port-forward-grafana`, `gcp-logs-app`, `gcp-logs-postgres`, `gcp-generate-slow-query`, and `gcp-info`. Adding these targets SHALL NOT modify or remove existing local targets.

#### Scenario: GCP targets available alongside local targets
- **WHEN** an operator inspects the `Makefile` after Phase 2
- **THEN** all listed `gcp-*` targets are present and the existing `*-local` targets are unchanged
