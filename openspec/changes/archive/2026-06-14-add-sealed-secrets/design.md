## Context

Phase 2 runs the `zenyard` Helm chart on a single-node k3s VM on GCP. Today the GCP overlay (`charts/zenyard/values-gcp.yaml`) holds three plaintext credentials that get committed to git: `database.password`, `postgresql.auth.password`, and the Grafana admin password (both the chart-level `grafana.adminPassword` and the kube-prometheus-stack subchart's `grafana.adminPassword`). The chart already supports `database.existingSecret` and `grafana.existingSecret`, and the PostgreSQL/Grafana subcharts support `existingSecret`/`admin.existingSecret`, so the wiring needed to consume externally-managed Secrets already exists — we only have to point at it and remove the inline values.

The challenge asks for a real secret-management posture without leaning on a cloud provider's secret service. Bitnami Sealed Secrets fits: a controller in the cluster holds an RSA keypair, `kubeseal` encrypts a normal Secret into a `SealedSecret` custom resource using the controller's public cert, and only that controller (with its private key) can decrypt it back into a `Secret`. The encrypted `SealedSecret` is therefore **safe to commit**, which is the whole point — secrets live in git, but in the clear nowhere.

The controller's keypair lives in the remote cluster, so encryption is cluster-specific: a `SealedSecret` sealed for this VM's controller can only be unsealed by it. That dictates the workflow — seal **on/against the remote cluster**, then copy the sealed YAML back to the repo on this host. The actual sealing runs later over a user-provided SSH key; this change lands the automation, wiring, and docs first.

## Goals / Non-Goals

**Goals:**
- Run a Sealed Secrets controller on the remote cluster, installed idempotently via Ansible + a Make target.
- Express the three stack credentials as `SealedSecret` resources sealed against that controller and committed under `sealed-secrets/gcp/`.
- Consume the resulting `Secret`s through the chart's existing `existingSecret` hooks and **remove all plaintext passwords from `values-gcp.yaml`**.
- Make the GCP deploy order correct: controller → apply SealedSecrets → `helm upgrade --install`.
- Document Sealed Secrets as the chosen approach **instead of Google Secret Manager** in README and architecture docs.
- Keep the Phase 1 local workflow byte-for-byte unchanged.

**Non-Goals:**
- Google Secret Manager, External Secrets Operator, HashiCorp Vault, or SOPS.
- Sealing the local (k3d) environment — local keeps inline demo credentials.
- Secret rotation automation, multi-cluster key sharing, or HA for the controller.
- Changing chart template architecture (only values and deploy ordering change).

## Decisions

**1. Bitnami Sealed Secrets (vs. Google Secret Manager / ESO / Vault / SOPS).**
Sealed Secrets requires no external cloud API, no IAM, and no extra runtime sidecar in the app path — just one controller in-cluster. Crucially the sealed artifact is committable, so the repo stays the source of truth (GitOps) while never exposing a plaintext secret. Google Secret Manager would add GCP API + IAM wiring, couple the deployment to GCP, and still leave the question of how the cluster authenticates to it; it also does not solve "no plaintext in git" for the chart's own Secret. ESO/Vault are heavier than a single-node challenge warrants. SOPS would keep encryption keys off-cluster but needs a key-management story of its own. Sealed Secrets is the smallest credible step up from plaintext for this scope.

**2. Seal on the remote cluster, copy sealed YAML back to the repo.**
The controller's private key is what defines "who can unseal," and it lives in the remote cluster. `kubeseal` fetches the controller's public cert from that cluster and produces a `SealedSecret` bound to it. So sealing must target the remote controller. We run `kubeseal` over SSH against the remote cluster, capture stdout, and write it into `sealed-secrets/gcp/*.yaml` on this host. Alternative (`kubeseal --cert <fetched-pem>` locally) is equivalent but still requires fetching the remote cert first; doing it over SSH keeps a single source of truth and matches the operational constraint that this runs against the remote box.

**3. Consume via `existingSecret`; remove plaintext from `values-gcp.yaml`.**
The chart already branches on `database.existingSecret` (skips templating `app-secret.yaml`) and supports `grafana.existingSecret`; the Bitnami PostgreSQL subchart honours `auth.existingSecret` and the kube-prometheus-stack Grafana subchart honours `admin.existingSecret`. We set these in `values-gcp.yaml` to the names of the Secrets the controller produces and delete the inline `password`/`adminPassword` keys. The chart's plaintext fallback paths remain intact for local/other environments, so nothing breaks where `existingSecret` is unset.

**4. Three SealedSecrets matching the three consumers.**
   - `zenyard-db` — keys `DB_USER`, `DB_PASSWORD` — consumed by the app deployment and the schema init job (`zenyard.dbSecretName`).
   - `zenyard-postgresql` — the Bitnami-expected keys (`password`, and `postgres-password` for the admin account) — referenced by `postgresql.auth.existingSecret`.
   - `zenyard-grafana` — keys `admin-user`, `admin-password` — referenced by the kube-prometheus-stack Grafana `admin.existingSecret`.
The DB user password and the PostgreSQL `password` key must hold the **same value** (the app connects with that user), which the sealing step guarantees by sealing from one source value.

**5. New Ansible `sealed-secrets` role, run before `deploy`.**
A dedicated role installs the controller (Helm, pinned `sealed_secrets_chart_version`, namespace `kube-system` or `sealed-secrets`) and applies the committed `sealed-secrets/gcp/*.yaml`. Playbook order becomes `common → k3s → helm → image → sealed-secrets → deploy → verify`, so the unsealed `Secret`s exist before the chart references them. The role is idempotent (Helm `upgrade --install`, `kubectl apply`).

**6. Make targets split install / seal / apply.**
   - `gcp-sealed-secrets-install` — install/upgrade the controller on the remote cluster.
   - `gcp-seal-secrets` — seal credentials against the remote controller over SSH and write the YAML into `sealed-secrets/gcp/`. Source values come from Make/env variables (or prompt), never committed in plaintext.
   - `gcp-apply-sealed-secrets` — `kubectl apply` the committed sealed YAML to the remote cluster.
Splitting them keeps sealing (rare, produces committed artifacts) separate from applying (idempotent, part of every deploy).

**7. Sealed YAML lives in `sealed-secrets/gcp/` with a README.**
Top-level `sealed-secrets/gcp/` keeps environment-specific, pre-sealed resources out of `charts/` (they are not Helm templates and are cluster-key-specific). `sealed-secrets/README.md` documents that these are encrypted, why they are committable, how to re-seal, and that the controller's private key must be backed up.

## Risks / Trade-offs

- **Sealed resources are bound to one controller key** → if the cluster/controller is recreated, the committed `SealedSecret`s can no longer be unsealed. Mitigation: document backing up the controller's sealing key (`kubectl get secret -n <ns> -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml`) and re-sealing via `gcp-seal-secrets` after a rebuild.
- **DB password split-brain** → the app DB Secret and the PostgreSQL subchart Secret must agree. Mitigation: `gcp-seal-secrets` seals both from a single source value; documented.
- **Forgetting to apply before deploy** → chart references a missing Secret and pods fail to start. Mitigation: the `sealed-secrets` role runs before `deploy`, and `gcp-redeploy` chains apply→deploy.
- **kubeseal/controller version skew** → mismatched CLI/controller can fail to seal. Mitigation: pin `sealed_secrets_chart_version` and document the matching `kubeseal` version.
- **Source plaintext leaking into shell history** → Mitigation: read source values from env/file, document not echoing them; only encrypted output is written/committed.
- **Local workflow regression** → Mitigation: no change to `values-local.yaml` or local targets; `existingSecret` stays empty locally so the chart's inline-Secret path is unchanged.

## Migration Plan

1. Land automation, chart wiring, sealed-resource placeholders, and docs (this change). `values-gcp.yaml` switches to `existingSecret` references but the repo still builds/templates.
2. Operator provides the SSH key. Run `make gcp-sealed-secrets-install` to install the controller on the remote cluster.
3. Run `make gcp-seal-secrets` (with source credential values) to produce `sealed-secrets/gcp/*.yaml`; commit the encrypted output.
4. `make gcp-apply-sealed-secrets` then `make gcp-deploy` (or `gcp-redeploy`); verify pods read credentials from the unsealed Secrets.
5. **Rollback**: revert `values-gcp.yaml` to inline demo credentials and remove the role from the playbook; the chart's `app-secret.yaml` fallback restores the prior behaviour. The controller can be `helm uninstall`ed independently.

## Open Questions

- Controller namespace (`kube-system` vs. a dedicated `sealed-secrets`) — defaulting to a dedicated namespace for clarity; not blocking.
- Whether to also seal local-environment secrets later — deferred; out of scope for this challenge.
