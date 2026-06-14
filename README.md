# Zenyard DevOps Challenge

A containerized FastAPI TODO service backed by PostgreSQL, packaged as a Helm chart
with a built-in observability stack (Prometheus, Grafana, Loki). The same chart runs
locally on **k3d** and remotely on a single-node **k3s** VM on **GCP**, driven from a
single `Makefile`.

- **Architecture:** [`ARCHITECTURE.md`](ARCHITECTURE.md)
- **Local development:** [`docs/local-development.md`](docs/local-development.md)
- **GCP deployment (detailed):** [`docs/gcp-deployment.md`](docs/gcp-deployment.md)
- **Troubleshooting:** [`docs/troubleshooting.md`](docs/troubleshooting.md)

## Repository Layout

```text
app/                  FastAPI service + Dockerfile
charts/zenyard/       Helm chart (templates + layered values)
ansible/              Playbook + roles for GCP VM bootstrap & deploy
scripts/              Smoke tests, stress test, slow-query generator
docs/                 Detailed guides
Makefile              Single entrypoint for local and GCP workflows
```

## Quick Start (Local)

Requires Docker, k3d, kubectl, Helm, and `make`/`curl`/`jq`
(`make install-local-tools-help` lists install links).

```sh
make create-local        # create the k3d cluster
make redeploy-local      # build image, load it, deploy the chart
make test-local          # run smoke tests
```

The API is then reachable at `http://localhost:8080` (e.g. `curl localhost:8080/healthz`).

---

## Setting Up the Remote GCP VM

This deploys the full stack to a manually-created GCP Ubuntu VM using Ansible and the
same Helm chart. The commands below run from your laptop/CI (the "control machine").

### 1. Prerequisites

**Control machine:** Docker, Ansible (`pip install ansible`), kubectl, Helm v3,
`make`/`curl`/`jq`, and an SSH key whose public half is authorized on the VM.

**GCP VM:**

| Requirement | Details |
|-------------|---------|
| OS | Ubuntu 22.04 LTS Server (fresh) |
| Sizing | `e2-standard-4` (4 vCPU / 16 GB) recommended; `e2-standard-2` works but is tight |
| Disk | 40–60 GB SSD |
| SSH | Public key accepted, user with passwordless sudo (e.g. `ubuntu`) |
| Egress | Internet access for apt, the k3s installer, and Helm charts |

> The VM is created manually (Cloud Console or `gcloud`); there is no Terraform in
> this solution.

### 2. Configure the GCP firewall

Open only what you need (GCP VPC → Firewall, or `gcloud compute firewall-rules`):

| Port | Protocol | Source | Required |
|------|----------|--------|----------|
| 22 | TCP | Your developer IP | Yes (SSH / Ansible) |
| 80 | TCP | 0.0.0.0/0 (or your IP) | Only for public FastAPI access |

**Do not open** 5432 (PostgreSQL), 3000 (Grafana), or 6443 (k3s API) — these stay
cluster-internal and are reached via SSH tunnels.

```sh
# Example: allow HTTP to instances tagged "zenyard"
gcloud compute firewall-rules create allow-http \
  --allow=tcp:80 --target-tags=zenyard --source-ranges=0.0.0.0/0
```

### 3. Create the Ansible inventory

```sh
cp ansible/inventory.gcp.ini.example ansible/inventory.gcp.ini
```

Edit `ansible/inventory.gcp.ini` with your VM's public IP, SSH user, and key:

```ini
[gcp]
34.x.x.x ansible_user=ubuntu ansible_ssh_private_key_file=~/.ssh/your-key
```

The real `inventory.gcp.ini` is git-ignored; only the `.example` is committed.
Verify SSH works before continuing:

```sh
ssh -i ~/.ssh/your-key ubuntu@34.x.x.x "echo ok"
```

> Throughout the rest of this guide, pass your VM IP as `GCP_HOST=34.x.x.x`. You can
> also override `GCP_USER` and `GCP_SSH_KEY` (defaults: `ubuntu`, `~/.ssh/id_rsa`).

### 4. Bootstrap the VM

```sh
make gcp-bootstrap
```

Runs Ansible to install OS packages, install k3s (with local-path storage, Traefik
ingress, metrics-server), install Helm, configure `kubectl` for the SSH user, then
verify the node is Ready and metrics-server responds. Idempotent — safe to re-run.

### 5. Build & load the application image

There is no registry; the image is shipped over SSH and imported into k3s containerd.

```sh
make gcp-build-image                    # build zenyard-api:gcp for linux/amd64
make gcp-load-image GCP_HOST=34.x.x.x   # save → scp → k3s ctr images import
```

### 6. Download chart dependencies (one-time)

```sh
make gcp-helm-deps
```

Fetches the PostgreSQL, kube-prometheus-stack, and loki-stack chart archives. Re-run
after any `Chart.yaml` dependency change.

### 7. Seal the secrets

This project keeps the cluster's credentials in git as encrypted **Sealed Secrets**
(Bitnami) — **instead of Google Secret Manager**. A controller in the cluster holds the
private key; `kubeseal` encrypts each `Secret` into a `SealedSecret` that only that
controller can decrypt, so the encrypted YAML is safe to commit. See
[`sealed-secrets/README.md`](sealed-secrets/README.md) for the full rationale.

```sh
make gcp-sealed-secrets-install GCP_HOST=34.x.x.x          # install the controller
make gcp-seal-secrets GCP_HOST=34.x.x.x \
  DB_USER=zenyard DB_PASSWORD='…' \
  GRAFANA_ADMIN_USER=admin GRAFANA_ADMIN_PASSWORD='…'        # seal → sealed-secrets/gcp/*.yaml
git add sealed-secrets/gcp/*.yaml && git commit -m "Add sealed GCP secrets"
```

Sealing runs against the remote cluster (its key lives there) and writes only the
encrypted output back here. The plaintext values you pass are never written to the repo.
`make gcp-deploy` applies the sealed secrets (the controller unseals them into Secrets)
before the Helm upgrade, and `values-gcp.yaml` consumes them via `existingSecret`.

### 8. Deploy

```sh
make gcp-deploy
```

Rsyncs the chart to `/opt/zenyard/chart` on the VM and runs `helm upgrade --install`
with `values-gcp.yaml` (waits up to 15 min for the full stack). The ingress host is
empty, so Traefik routes all HTTP requests to the FastAPI app.

### 9. Verify

```sh
make gcp-test GCP_HOST=34.x.x.x
```

Smoke-tests remote connectivity, pod readiness, the schema-init job, the `/healthz`
endpoint, TODO create/list/complete, and the observability pods.

> GCP firewall blocks external port 80 by default, so the smoke test runs its HTTP
> checks over SSH against `http://localhost` on the VM rather than the public IP.

### Redeploy after an app change

```sh
make gcp-redeploy GCP_HOST=34.x.x.x     # build → load → deploy in one step
```

## Accessing Grafana on the VM

Grafana is not exposed publicly — tunnel to it over SSH:

```sh
make gcp-port-forward-grafana GCP_HOST=34.x.x.x
# then open http://localhost:3000  (user: admin)
```

Retrieve the admin password:

```sh
ssh ubuntu@34.x.x.x kubectl get secret -n zenyard zenyard-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d
```

> On GCP, credentials come from **Sealed Secrets**, not plaintext — `values-gcp.yaml`
> references them via `existingSecret` and contains no passwords. Use the value you
> passed to `make gcp-seal-secrets` (the local k3d workflow still uses inline demo
> credentials in `values-local.yaml`).

## Useful GCP Commands

```sh
make gcp-info GCP_HOST=34.x.x.x                # cluster + deployment status
make gcp-logs-app GCP_HOST=34.x.x.x            # tail FastAPI logs
make gcp-logs-postgres GCP_HOST=34.x.x.x       # tail PostgreSQL logs (slow queries)
make gcp-generate-slow-query GCP_HOST=34.x.x.x # trigger the slow-query alert
make gcp-stress GCP_HOST=34.x.x.x              # load test through the ingress
make gcp-verify-k3s                            # cluster-only checks (no app)
make gcp-apply-sealed-secrets GCP_HOST=34.x.x.x # re-apply sealed secrets
```

## Cleanup

```sh
# Remove the Helm release
ssh ubuntu@34.x.x.x helm uninstall zenyard --namespace zenyard

# Remove k3s entirely
ssh ubuntu@34.x.x.x sudo /usr/local/bin/k3s-uninstall.sh
```

Then delete the VM from the Cloud Console. For deeper diagnostics (SSH failures,
pending pods, image pull errors, ingress issues), see
[`docs/troubleshooting.md`](docs/troubleshooting.md) and the troubleshooting section
of [`docs/gcp-deployment.md`](docs/gcp-deployment.md).
</content>
