## Why

Phase 1 produced a complete, working local stack (k3d + the `zenyard` Helm chart: PostgreSQL, FastAPI, ingress, schema init hook, observability, slow-query logging, alerting, dashboard). The challenge now needs the *same* solution running on a real, already-provisioned Google Cloud Ubuntu VM — without an AWS staging detour. We need repeatable, demo-friendly automation that takes a clean VM to a verified deployment in minutes, treating GCP as another environment target rather than a re-implementation.

## What Changes

- Add an Ansible-based bootstrap that turns a clean Ubuntu Server VM into a single-node k3s host: OS packages, k3s (with local-path storage, Traefik ingress, metrics-server), kubectl for the SSH user, and Helm.
- Add a registry-free image workflow: build the FastAPI image locally, `docker save` to a tar, copy to the VM, and `k3s ctr images import` into containerd.
- Reuse the **existing** `zenyard` Helm chart unchanged in architecture; add only a new `charts/zenyard/values-gcp.yaml` environment overlay (image `zenyard-api:gcp`, `pullPolicy: IfNotPresent`).
- Deploy/upgrade the release into the `zenyard` namespace on the remote cluster and run remote verification.
- Add GCP-specific Makefile targets (`gcp-bootstrap`, `gcp-build-image`, `gcp-load-image`, `gcp-deploy`, `gcp-redeploy`, `gcp-test`, `gcp-verify-k3s`, `gcp-helm-deps`, `gcp-port-forward-grafana`, `gcp-logs-app`, `gcp-logs-postgres`, `gcp-generate-slow-query`, `gcp-info`) and a `scripts/smoke-test-remote.sh`.
- Add `docs/gcp-deployment.md` covering prerequisites, VM sizing, firewall rules, inventory setup, bootstrap → deploy → test, safe Grafana access, troubleshooting, and cleanup.
- Keep PostgreSQL cluster-internal and Grafana non-public (SSH tunnel / port-forward only); expose only FastAPI over HTTP ingress.
- Preserve all Phase 1 security and resource best practices (Secrets for credentials, securityContext, NetworkPolicy, requests/limits).
- **Preserve the Phase 1 local workflow unchanged** — all `*-local` targets and the local values file keep working exactly as before.

## Capabilities

### New Capabilities
- `gcp-vm-deployment`: Ansible + Makefile automation to bootstrap a clean Google Cloud Ubuntu VM into a single-node k3s cluster, make the FastAPI image available without a registry, deploy the existing `zenyard` Helm chart via a GCP values overlay, and verify the full stack remotely (idempotent and rerun-safe).

### Modified Capabilities
<!-- None. The local-development-setup capability and the zenyard chart architecture are unchanged; GCP differences live only in inventory, group_vars, and values-gcp.yaml. -->

## Impact

- **New directories/files**: `ansible/` (inventory example, `playbook.yml`, `group_vars/`, `roles/{common,k3s,helm,image,deploy,verify}`), `charts/zenyard/values-gcp.yaml`, `docs/gcp-deployment.md`, `scripts/smoke-test-remote.sh`.
- **Modified**: `Makefile` (additive `gcp-*` targets only).
- **Unchanged**: the `zenyard` chart architecture/templates, Phase 1 local targets, `values.yaml`, `values-local.yaml`, existing scripts and docs.
- **New tooling dependency (control machine)**: Ansible, plus existing Docker/kubectl/Helm/SSH. No new runtime services; no AWS, Terraform, GKE, Cloud SQL, Artifact Registry, external DNS, or TLS.
- **Operational**: requires an existing GCP VM, SSH access, and a user-provided `ansible/inventory.gcp.ini`; firewall opens 22 (and optionally 80), never PostgreSQL or Grafana.
