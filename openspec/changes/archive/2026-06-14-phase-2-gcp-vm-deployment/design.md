## Context

Phase 1 delivered a working local environment: a k3d cluster and the `zenyard` Helm chart (PostgreSQL standalone, FastAPI, Traefik ingress, schema init Job hook, kube-prometheus-stack + loki-stack observability, slow-query logging, alert rules, Grafana dashboard) driven entirely from a `Makefile` and `values-local.yaml`. The chart already encodes the security and resource posture we want (Secrets for DB/Grafana credentials, `securityContext`, `NetworkPolicy`, requests/limits).

Phase 2 must run that *same* chart on a single, already-created Google Cloud Ubuntu Server VM. There is no AWS staging step. The work is constrained by a ~2-hour challenge/demo window, so every command must be legible during a live walkthrough, and the automation must be idempotent so a rerun during the demo is safe. The control machine has Docker, kubectl, Helm, and SSH; we add Ansible there for remote bootstrap.

The chart and its templates do not change. GCP-specific differences are confined to three places: the Ansible inventory, `group_vars`, and a new `charts/zenyard/values-gcp.yaml` overlay.

## Goals / Non-Goals

**Goals:**
- One-command bootstrap (`make gcp-bootstrap`) of a clean Ubuntu VM into a single-node k3s host with local-path storage, Traefik ingress, and metrics-server verified Ready.
- Registry-free delivery of the FastAPI image to the remote containerd.
- Reuse the Phase 1 `zenyard` chart unchanged; express GCP only as an environment overlay + inventory/vars.
- Idempotent, rerun-safe Ansible roles (`common`, `k3s`, `helm`, `image`, `deploy`, `verify`).
- Remote verification (`make gcp-test`) covering app, DB, schema hook, ingress, observability, and slow-query logging.
- Keep PostgreSQL cluster-internal and Grafana non-public; expose only FastAPI over HTTP ingress.
- Preserve the Phase 1 local workflow byte-for-byte.

**Non-Goals:**
- AWS, Terraform, automatic GCP VM creation, GKE, Cloud SQL, Artifact Registry, external DNS, TLS.
- Production HA for Kubernetes or PostgreSQL; real alert-notification integrations.
- Any change to the app architecture or chart templates.

## Decisions

**1. Ansible for remote bootstrap (vs. shell scripts over SSH).**
Ansible gives idempotency, retries, and readable role separation for free — essential for "safe to rerun" during a live demo. Roles map one-to-one to phases (`common`, `k3s`, `helm`, `image`, `deploy`, `verify`), so a viewer can follow the playbook top to bottom. Alternative (a bootstrap.sh) would be shorter to write but harder to make idempotent and less legible per-step.

**2. k3s with stock defaults (vs. disabling Traefik / swapping components).**
k3s ships local-path storage, Traefik ingress, and metrics-server already wired — exactly the three primitives the chart needs. Keeping defaults means the chart's `ingress.className: traefik` works as-is and there is nothing extra to install or explain. We pin a configurable `k3s_version` (via the `INSTALL_K3S_VERSION` channel) for reproducibility. Alternative (ingress-nginx + manual metrics-server) adds install steps and a values divergence for no demo benefit.

**3. Registry-free image flow: `docker build → docker save → scp → k3s ctr images import` (vs. a registry).**
The VM already runs containerd under k3s; importing a tar straight into it avoids standing up or authenticating to any registry (Artifact Registry, Docker Hub). It is the most demo-legible path and removes a whole class of image-pull/auth failures. With the image present in containerd and `pullPolicy: IfNotPresent`, kubelet never reaches out to a registry. Trade-off: image must be re-copied on each change (handled by `gcp-redeploy`), and the tar transits SSH — acceptable for a single-node challenge. We remove the temp tar after import where practical.

**4. GCP as an environment overlay, not a fork.**
`values-gcp.yaml` carries only what differs from `values.yaml`: `app.image` = `zenyard-api:gcp` with `pullPolicy: IfNotPresent`, the ingress host, and demo credential overrides. Everything else (observability, securityContext, NetworkPolicy, resources) is inherited. This guarantees the local and GCP environments stay in lockstep and that Phase 1 files are untouched.

**5. kubeconfig for the SSH user (vs. sudo kubectl).**
The k3s role copies `/etc/rancher/k3s/k3s.yaml` to `~/.kube/config` for the SSH user (chowned, server URL left as `https://127.0.0.1:6443`). Day-to-day `kubectl` then needs no sudo, matching how a developer expects to operate and keeping demo commands clean. Remote Make targets run kubectl over SSH against this config.

**6. Grafana access via SSH tunnel / `kubectl port-forward` (vs. ingress/LoadBalancer).**
Grafana stays `ClusterIP`. `make gcp-port-forward-grafana` opens an SSH-tunneled port-forward so the dashboard is reachable locally without ever binding a public port. This satisfies "FastAPI is the only public HTTP service" with zero extra config.

**7. Image/tag are variables, defaulting to `zenyard-api:gcp`.**
`IMAGE`/`IMAGE_TAG` Make variables and Ansible defaults make the image name configurable without editing the chart, while the documented default matches `values-gcp.yaml`.

## Risks / Trade-offs

- **Observability stack memory pressure on small VMs** → Document `e2-standard-4` as preferred, `e2-standard-2` as tight; chart already sets requests/limits; troubleshooting covers "pods pending due to memory."
- **GCP firewall blocks HTTP 80, making ingress look broken** → Doc calls out the exact firewall rule; `gcp-test` distinguishes in-cluster reachability from external; troubleshooting has a dedicated entry.
- **Image not re-imported after a code change → stale pods** → `gcp-redeploy` always rebuilds, re-imports, and upgrades; `pullPolicy: IfNotPresent` documented so users know to bump tags or redeploy.
- **k3s API / metrics-server not Ready immediately** → Ansible uses retries/waits on node Ready and `kubectl top nodes`; verify role retries.
- **Re-running the playbook mid-demo** → All roles idempotent: k3s install is a no-op if the service is active, image import is safe to repeat, Helm uses `upgrade --install`.
- **SSH connectivity / wrong inventory** → `inventory.gcp.ini.example` is provided; docs cover SSH troubleshooting; the user supplies the real `inventory.gcp.ini` (git-ignored).
- **Demo credentials in values** → `values-gcp.yaml` carries only demo secrets; docs state real deployments MUST override via `--set`/existingSecret. No real secrets committed.

## Migration Plan

1. Add Ansible tree, `values-gcp.yaml`, remote smoke script, docs, and additive `gcp-*` Make targets. No Phase 1 file is modified except the additive `Makefile`.
2. User creates the VM (manual, out of scope), opens SSH (and optionally HTTP 80), and writes `ansible/inventory.gcp.ini` from the example.
3. `make gcp-bootstrap` → `make gcp-build-image` → `make gcp-load-image` → `make gcp-deploy` → `make gcp-test` (or `gcp-redeploy` to chain build/load/deploy).
4. **Rollback**: `helm uninstall` the release on the VM and/or `/usr/local/bin/k3s-uninstall.sh` to return the VM to clean; nothing on the control machine or Phase 1 workflow is affected.

## Open Questions

- None blocking. Whether to later add an optional Artifact Registry path is deferred until explicitly requested; the registry-free flow is sufficient for the challenge.
