## Why

The GCP deployment currently carries credentials as **plaintext** in `charts/zenyard/values-gcp.yaml` (the DB password, the PostgreSQL subchart password, and the Grafana admin password are committed demo values). That is fine for a throwaway demo but is exactly the anti-pattern a DevOps review flags: secrets live in git in the clear, and the chart's own `app-secret.yaml` materialises them at install time.

We want a credible secret-management story that is **GitOps-friendly and committable** without an external cloud dependency. Rather than reach for Google Secret Manager (which adds GCP API wiring, IAM, an external runtime dependency, and only protects secrets at the cloud boundary — not in git), we adopt **Bitnami Sealed Secrets**: the controller runs in the remote cluster, holds the private key, and decrypts `SealedSecret` resources into normal `Secret`s. Sealed resources are asymmetrically encrypted, so they are **safe to commit** to this repo. This is the explicit design choice the README and architecture docs will call out: *Sealed Secrets instead of Google Secret Manager.*

Because the controller's keypair lives in the cluster, the sealing must be done **against the remote cluster** and the resulting `SealedSecret` YAML copied back into the repo on this host. The change is scoped to the remote/GCP path only; the Phase 1 local workflow keeps its plaintext demo values unchanged.

## What Changes

- Add a Bitnami **Sealed Secrets controller** to the remote cluster (Helm install via a new Ansible `sealed-secrets` role and `make gcp-sealed-secrets-install`), pinned to a configurable chart version.
- Define the three secrets the stack needs as **`SealedSecret`** resources sealed on the remote cluster with `kubeseal`: the app/DB credential Secret (`DB_USER`/`DB_PASSWORD`), the PostgreSQL subchart auth Secret (Bitnami keys), and the Grafana admin Secret (`admin-user`/`admin-password`).
- Add `make gcp-seal-secrets` to run `kubeseal` over SSH against the remote controller and **fetch the sealed YAML back into the repo** under `sealed-secrets/gcp/`, plus `make gcp-apply-sealed-secrets` to apply them.
- Wire the `zenyard` chart's GCP path to consume these via **`existingSecret`** references (`database.existingSecret`, `postgresql.auth.existingSecret`, Grafana `admin.existingSecret`) and **remove the plaintext passwords from `values-gcp.yaml`**.
- Order the GCP deploy flow so the controller and applied SealedSecrets exist before `helm upgrade --install`.
- Update `README.md`, `ARCHITECTURE.md`, and `docs/architecture.md`/`docs/gcp-deployment.md` to document the Sealed Secrets approach and explicitly state it is used **instead of Google Secret Manager**.
- **Preserve the local workflow unchanged** — `values-local.yaml` and the local Make targets keep using inline demo credentials; the chart's `app-secret.yaml` fallback stays for environments that do not set `existingSecret`.

## Capabilities

### New Capabilities
- `sealed-secrets-management`: Manage the remote cluster's credentials as committable Bitnami `SealedSecret` resources — controller installation, sealing on the remote cluster, copying sealed YAML back to the repo, applying them, and consuming the resulting Secrets via the chart's `existingSecret` hooks — replacing plaintext credentials in the GCP values overlay and standing in for a cloud secret manager.

### Modified Capabilities
<!-- The gcp-vm-deployment capability gains a sealed-secrets step in its deploy flow and drops plaintext credentials from values-gcp.yaml; the change is captured in this new capability's requirements. Chart templates remain backward compatible (existingSecret was already supported). -->

## Impact

- **New files**: `ansible/roles/sealed-secrets/{tasks/main.yml,defaults/main.yml}`, `sealed-secrets/gcp/*.yaml` (the committed sealed resources), `sealed-secrets/README.md`.
- **Modified**: `ansible/playbook.yml` (run `sealed-secrets` before `deploy`), `ansible/group_vars/gcp.yml` (controller/namespace/version vars), `charts/zenyard/values-gcp.yaml` (replace plaintext passwords with `existingSecret` references), `Makefile` (additive `gcp-sealed-secrets-install`, `gcp-seal-secrets`, `gcp-apply-sealed-secrets`), `README.md`, `ARCHITECTURE.md`, `docs/architecture.md`, `docs/gcp-deployment.md`.
- **Unchanged**: chart templates, `values.yaml`, `values-local.yaml`, the Phase 1 local workflow and targets.
- **New tooling dependency**: `kubeseal` CLI (control machine) and the Sealed Secrets controller (remote cluster). No GCP API, IAM, or Google Secret Manager dependency.
- **Operational**: sealing is performed against the remote cluster over the user-provided SSH key after the major implementation is in place; the controller's private key must be backed up (documented).
