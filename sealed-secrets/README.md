# Sealed Secrets (GCP remote cluster)

This project keeps the remote cluster's credentials in git as **encrypted**
[Bitnami Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) — **instead
of Google Secret Manager**. A controller running in the cluster holds an RSA keypair;
`kubeseal` encrypts a normal `Secret` into a `SealedSecret` using the controller's
public certificate, and only that controller (with its private key) can decrypt it
back into a `Secret`. The encrypted `SealedSecret` is therefore safe to commit.

## Why Sealed Secrets instead of Google Secret Manager

- No cloud-provider API, IAM bindings, or workload-identity wiring; nothing ties the
  deployment to GCP.
- Secrets live in this repo as the source of truth (GitOps), but never in plaintext.
- One in-cluster controller — no external runtime dependency in the app's request path.

The local (k3d) workflow is unaffected: it still uses inline demo credentials in
`charts/zenyard/values-local.yaml`. Sealing applies only to the remote/GCP path.

## What is sealed

| SealedSecret (file)        | Consumed by                                              | Keys                            |
|----------------------------|----------------------------------------------------------|---------------------------------|
| `gcp/zenyard-db.yaml`         | app deployment + schema init job (`database.existingSecret`) | `DB_USER`, `DB_PASSWORD`        |
| `gcp/zenyard-postgresql.yaml` | PostgreSQL subchart (`postgresql.auth.existingSecret`)   | `postgres-password`, `password` |
| `gcp/zenyard-grafana.yaml`    | Grafana (`kube-prometheus-stack.grafana.admin.existingSecret`) | `admin-user`, `admin-password`  |

The PostgreSQL `password` key and `DB_PASSWORD` must hold the **same value** so the
app can connect; `make gcp-seal-secrets` seals both from the same source value.

The `*.yaml.example` files are committed templates that document the shape of each
SealedSecret. The real `*.yaml` files are produced by sealing (below). Only the
encrypted `*.yaml` are applied; the controller does not touch the `.example` files.

## Workflow

Because the controller's key lives in the remote cluster, sealing runs **against the
remote cluster** and the encrypted output is copied back here.

```bash
# 1. Install the controller on the remote cluster (idempotent)
make gcp-sealed-secrets-install GCP_HOST=<vm-ip>

# 2. Seal credentials against the remote controller; writes sealed-secrets/gcp/*.yaml
#    Source values come from env (or you are prompted); plaintext never hits the repo.
make gcp-seal-secrets GCP_HOST=<vm-ip> \
  DB_USER=zenyard DB_PASSWORD='…' \
  GRAFANA_ADMIN_USER=admin GRAFANA_ADMIN_PASSWORD='…'

# 3. Commit the encrypted output
git add sealed-secrets/gcp/*.yaml && git commit -m "Add sealed GCP secrets"

# 4. Apply + deploy (the sealed-secrets Ansible role also applies them before deploy)
make gcp-apply-sealed-secrets GCP_HOST=<vm-ip>
make gcp-deploy
```

**Prerequisite:** the `kubeseal` CLI is used on the remote VM. Keep its version in sync
with the controller chart (`sealed_secrets_chart_version` in
`ansible/group_vars/gcp.yml`).

## Back up the controller's private key

The committed `SealedSecret`s can only be decrypted by the controller that sealed
them. If the cluster or controller is recreated, back up and restore the sealing key,
or re-run `make gcp-seal-secrets` to re-seal against the new controller.

```bash
# Back up (run on the VM, or over SSH):
kubectl get secret -n sealed-secrets \
  -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealed-secrets-key.backup.yaml
# Restore onto a fresh controller, then restart it:
kubectl apply -f sealed-secrets-key.backup.yaml
kubectl delete pod -n sealed-secrets -l app.kubernetes.io/name=sealed-secrets
```

Store `sealed-secrets-key.backup.yaml` somewhere safe — it is the master key and is
**not** committed (it is plaintext).

## Safety

- Never commit plaintext `Secret` manifests. `.gitignore` excludes `*.plain.yaml`,
  `*.secret.yaml`, and `*.unsealed.yaml`.
- Only the encrypted `sealed-secrets/gcp/*.yaml` belong in git.
