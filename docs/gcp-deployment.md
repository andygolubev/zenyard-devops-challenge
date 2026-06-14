# GCP Deployment

This guide covers deploying the zenyard stack to a manually-created Google Cloud Ubuntu Server VM using Ansible and the existing `zenyard` Helm chart.

## Prerequisites

### Control machine (your laptop / CI)

| Tool | Notes |
|------|-------|
| Docker | Build and save the FastAPI image |
| Ansible | `pip install ansible` or `brew install ansible` |
| kubectl | Standard kubectl binary |
| Helm | v3.x |
| SSH key | Matching your GCP VM's authorized key |
| make, curl, jq | Standard shell utilities |

### GCP VM

| Requirement | Details |
|-------------|---------|
| OS | Ubuntu 22.04 LTS Server (fresh install) |
| SSH access | Public key accepted, user with passwordless sudo |
| Internet access | Needed for apt, k3s installer, Helm charts |

## Recommended VM Sizing

| Size | vCPU | RAM | Notes |
|------|------|-----|-------|
| `e2-standard-4` | 4 | 16 GB | **Recommended** — comfortable for full observability stack |
| `e2-standard-2` | 2 | 8 GB | Works but can be tight when Prometheus + Loki both start |

- **Disk**: 40–60 GB (SSD preferred). The observability stack and persistent volumes need room.
- If pods are pending due to memory, check `kubectl describe node` and consider upgrading the machine type.

## Required Firewall Rules

Configure in **GCP VPC → Firewall** or `gcloud compute firewall-rules`:

| Port | Protocol | Source | Required |
|------|----------|--------|----------|
| 22 | TCP | Your developer IP | Yes (SSH / Ansible) |
| 80 | TCP | 0.0.0.0/0 | Only if you need public FastAPI access |

**Do not open**: 5432 (PostgreSQL), 3000 (Grafana), 6443 (k3s API). Those stay cluster-internal.

## Inventory Setup

1. Copy the example inventory:
   ```sh
   cp ansible/inventory.gcp.ini.example ansible/inventory.gcp.ini
   ```

2. Edit `ansible/inventory.gcp.ini`:
   ```ini
   [gcp]
   34.x.x.x ansible_user=ubuntu ansible_ssh_private_key_file=~/.ssh/your-key
   ```

3. Verify SSH access works before running Ansible:
   ```sh
   ssh -i ~/.ssh/your-key ubuntu@34.x.x.x "echo ok"
   ```

The real `ansible/inventory.gcp.ini` is git-ignored — only the `.example` is committed.

## Deployment Workflow

### 1. Bootstrap the VM

```sh
make gcp-bootstrap
```

This runs Ansible to:
- Install required OS packages
- Install k3s (with local-path storage, Traefik ingress, metrics-server)
- Install Helm
- Configure `kubectl` for the SSH user (no sudo needed after this)
- Verify the node is Ready, local-path storage class exists, metrics-server responds

Expected output: `kubectl get nodes` shows one `Ready` node.

### 2. Build the FastAPI image

```sh
make gcp-build-image
```

Builds `zenyard-api:gcp` locally using the `app/` directory. Run this whenever the app changes.

### 3. Load the image into the remote cluster

```sh
make gcp-load-image GCP_HOST=34.x.x.x
```

This:
1. Saves `zenyard-api:gcp` to `/tmp/zenyard-api-gcp.tar` locally
2. Copies it to the VM
3. Imports it into k3s containerd via `k3s ctr images import`
4. Cleans up the temporary archives

### 4. (One-time) Download chart dependencies

```sh
make gcp-helm-deps
```

Downloads the PostgreSQL, kube-prometheus-stack, and loki-stack Helm chart archives locally. Run this before the first deploy and after any `Chart.yaml` dependency changes.

### 5. Seal the secrets

Credentials are managed with **Bitnami Sealed Secrets instead of Google Secret Manager** (see [Credentials](#credentials) and `sealed-secrets/README.md`). Because the controller's private key lives in the cluster, sealing runs against the remote cluster and the encrypted output is copied back to the repo.

```sh
# Install the controller (idempotent)
make gcp-sealed-secrets-install GCP_HOST=34.x.x.x

# Seal the three credentials; writes encrypted YAML into sealed-secrets/gcp/
make gcp-seal-secrets GCP_HOST=34.x.x.x \
  DB_USER=zenyard DB_PASSWORD='<choose>' \
  GRAFANA_ADMIN_USER=admin GRAFANA_ADMIN_PASSWORD='<choose>'

# Commit the encrypted output (safe — only the cluster can decrypt it)
git add sealed-secrets/gcp/*.yaml && git commit -m "Add sealed GCP secrets"
```

You are prompted for any credential value not passed on the command line; plaintext is never written to the repo. The next `make gcp-deploy` applies the sealed secrets before the Helm upgrade. To re-apply committed sealed secrets without re-sealing, use `make gcp-apply-sealed-secrets GCP_HOST=34.x.x.x`.

### 6. Deploy

```sh
make gcp-deploy
```

This runs Ansible to:
- Sync the chart (including downloaded dependencies) to `/opt/zenyard/chart` on the VM
- Apply the committed SealedSecrets (the controller unseals them into `Secret`s) before the upgrade
- Run `helm upgrade --install` with `values-gcp.yaml` (which references those Secrets via `existingSecret`)
- Wait for workloads to be ready (up to 15 minutes for the full observability stack)

The ingress host is set to `""` (empty) in `values-gcp.yaml`, which Traefik treats as a wildcard — all HTTP requests are routed to the FastAPI app regardless of the Host header.

### 7. Verify

```sh
make gcp-test GCP_HOST=34.x.x.x
```

Runs `scripts/smoke-test-remote.sh` which checks:
- Remote kubectl connectivity
- Namespace exists
- All pods Ready
- PostgreSQL ready
- Schema init job completed
- FastAPI `/healthz` reachable through ingress
- TODO create / list / complete endpoints work
- Grafana, Prometheus, Loki, Promtail pods running
- `kubectl top nodes` returns metrics

### Convenience: redeploy in one command

After the first bootstrap, use:
```sh
make gcp-redeploy GCP_HOST=34.x.x.x
```

This chains `gcp-build-image` → `gcp-load-image` → `gcp-deploy`.

## Credentials

This project manages the remote cluster's credentials with **Bitnami Sealed Secrets instead of Google Secret Manager**. A controller in the cluster holds an RSA private key; `kubeseal` encrypts each `Secret` into a `SealedSecret` that only that controller can decrypt, so the encrypted manifests in `sealed-secrets/gcp/` are safe to commit. `values-gcp.yaml` carries **no plaintext passwords** — it references the unsealed Secrets via `existingSecret`. This keeps the repo as the source of truth for secrets without exposing them, and avoids any GCP API/IAM dependency. The local k3d workflow still uses inline demo passwords in `values-local.yaml`.

Three SealedSecrets are sealed (see [step 5](#5-seal-the-secrets)):

| SealedSecret        | Consumed by                                  | Keys                            |
|---------------------|----------------------------------------------|---------------------------------|
| `zenyard-db`        | app + schema init job (`database.existingSecret`) | `DB_USER`, `DB_PASSWORD`        |
| `zenyard-postgresql`| PostgreSQL subchart (`postgresql.auth.existingSecret`) | `postgres-password`, `password` |
| `zenyard-grafana`   | Grafana (`grafana.admin.existingSecret`)     | `admin-user`, `admin-password`  |

`zenyard-postgresql`'s `password` matches `DB_PASSWORD` so the app can connect; `make gcp-seal-secrets` seals both from the same value.

### kubeseal prerequisite

The `kubeseal` CLI runs on the VM during sealing and is installed automatically by `make gcp-sealed-secrets-install` (the `sealed-secrets` role). Its version (`kubeseal_version`, default `0.27.1`) should match the controller chart pinned in `ansible/group_vars/gcp.yml` (`sealed_secrets_chart_version`, currently `2.16.2`); both are configurable there / in the role defaults.

### Back up the controller's private key

The committed SealedSecrets can only be decrypted by the controller that sealed them. If the cluster/controller is recreated, restore the sealing key or re-run `make gcp-seal-secrets`:

```sh
# Back up the master key
ssh ubuntu@34.x.x.x kubectl get secret -n sealed-secrets \
  -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealed-secrets-key.backup.yaml
# Restore onto a fresh controller and restart it
ssh ubuntu@34.x.x.x kubectl apply -f - < sealed-secrets-key.backup.yaml
ssh ubuntu@34.x.x.x kubectl delete pod -n sealed-secrets -l app.kubernetes.io/name=sealed-secrets
```

Store `sealed-secrets-key.backup.yaml` securely — it is the master key and is **not** committed.

## Accessing Grafana

Grafana is not exposed publicly. Use an SSH tunnel:

```sh
make gcp-port-forward-grafana GCP_HOST=34.x.x.x
```

Then open `http://localhost:3000` in your browser.

- Username: `admin`
- Password (retrieve from cluster):
  ```sh
  ssh ubuntu@34.x.x.x kubectl get secret -n zenyard zenyard-grafana \
    -o jsonpath='{.data.admin-password}' | base64 -d
  ```

Press Ctrl+C to stop the tunnel.

## Useful Commands

```sh
# Show cluster and deployment status
make gcp-info GCP_HOST=34.x.x.x

# Tail FastAPI logs
make gcp-logs-app GCP_HOST=34.x.x.x

# Tail PostgreSQL logs (includes slow query entries)
make gcp-logs-postgres GCP_HOST=34.x.x.x

# Generate a slow query (triggers the slow-query alert in Grafana)
make gcp-generate-slow-query GCP_HOST=34.x.x.x

# Verify k3s cluster state only (no app checks)
make gcp-verify-k3s
```

## Cleanup

To remove the Helm release from the VM:
```sh
ssh ubuntu@34.x.x.x helm uninstall zenyard --namespace zenyard
```

To remove k3s entirely from the VM:
```sh
ssh ubuntu@34.x.x.x sudo /usr/local/bin/k3s-uninstall.sh
```

Neither affects the Phase 1 local workflow. Delete the GCP VM from the Cloud Console when done.

---

## Troubleshooting

### SSH connection fails

```
fatal: [34.x.x.x]: UNREACHABLE! => {"msg": "Failed to connect to the host via ssh"}
```

- Verify your GCP firewall rule allows TCP 22 from your IP
- Check the key path in `ansible/inventory.gcp.ini`
- Test manually: `ssh -i ~/.ssh/your-key ubuntu@34.x.x.x echo ok`
- If using a non-standard user, update `ansible_user` in the inventory

### GCP firewall blocks HTTP port 80

Symptom: `make gcp-test` fails on the FastAPI health check even though pods are running.

Fix: Add a GCP firewall rule allowing TCP 80 from 0.0.0.0/0 (or your IP) targeting the VM's network tag.

```sh
gcloud compute firewall-rules create allow-http \
  --allow=tcp:80 --target-tags=YOUR_TAG --source-ranges=0.0.0.0/0
```

Then retry: `make gcp-test GCP_HOST=34.x.x.x`.

### Node not Ready

```sh
ssh ubuntu@34.x.x.x sudo journalctl -u k3s -n 50
ssh ubuntu@34.x.x.x kubectl get nodes
```

Typical causes: k3s still starting (wait 30–60 s), networking issue, or disk full. If the node stays `NotReady`, rerun bootstrap:

```sh
make gcp-bootstrap
```

The playbook is idempotent and will restart the k3s service if needed.

### metrics-server not ready

`kubectl top nodes` returns an error shortly after bootstrap. Wait up to 2–3 minutes for metrics-server to collect its first scrape. `gcp-bootstrap` retries automatically.

```sh
ssh ubuntu@34.x.x.x kubectl get pods -n kube-system | grep metrics
ssh ubuntu@34.x.x.x kubectl logs -n kube-system deploy/metrics-server
```

### Image pull error (`ErrImagePull` / `ImagePullBackOff`)

The FastAPI pod uses `pullPolicy: IfNotPresent`. If the image is not in containerd, kubelet tries to pull from a registry and fails.

Fix: rerun the image load:
```sh
make gcp-build-image
make gcp-load-image GCP_HOST=34.x.x.x
```

Then the pod will restart and find the image locally.

Verify the image is present:
```sh
ssh ubuntu@34.x.x.x sudo k3s ctr images list | grep zenyard-api
```

### Ingress not reachable

```sh
ssh ubuntu@34.x.x.x kubectl get ingress -n zenyard
ssh ubuntu@34.x.x.x kubectl get pods -n kube-system | grep traefik
curl -v http://34.x.x.x/healthz
```

If Traefik pods are running but curl fails, the GCP firewall is likely blocking port 80 (see above). If Traefik is not running, check:

```sh
ssh ubuntu@34.x.x.x kubectl describe pods -n kube-system -l app.kubernetes.io/name=traefik
```

### Pods pending due to memory

```sh
ssh ubuntu@34.x.x.x kubectl describe node | grep -A5 'Conditions:'
ssh ubuntu@34.x.x.x kubectl get pods -A | grep Pending
ssh ubuntu@34.x.x.x kubectl describe pod -n zenyard <pod-name>
```

If `Insufficient memory`, the VM is too small. Options:
- Resize to `e2-standard-4`
- Disable the observability stack temporarily: `helm upgrade zenyard charts/zenyard --set observability.metrics.enabled=false --set observability.logs.enabled=false ...`

### Helm timeout

If `helm upgrade` times out after 15 minutes:
```sh
ssh ubuntu@34.x.x.x kubectl get pods -n zenyard
ssh ubuntu@34.x.x.x kubectl describe pod -n zenyard <stuck-pod>
```

Look for: OOMKilled (resize VM), image not found (rerun gcp-load-image), or init container failures (check schema job logs).

### local-path PVC not bound

```sh
ssh ubuntu@34.x.x.x kubectl get pvc -n zenyard
ssh ubuntu@34.x.x.x kubectl get storageclass
ssh ubuntu@34.x.x.x kubectl get pods -n kube-system | grep local-path
```

The local-path provisioner is part of k3s. If it's missing, rerun bootstrap:
```sh
make gcp-bootstrap
```
