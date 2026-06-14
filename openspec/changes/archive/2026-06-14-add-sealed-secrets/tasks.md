## 1. Sealed Secrets controller (Ansible role)

- [x] 1.1 Create `ansible/roles/sealed-secrets/{tasks/main.yml,defaults/main.yml}`
- [x] 1.2 In `defaults/main.yml`, expose `sealed_secrets_namespace`, `sealed_secrets_release_name`, `sealed_secrets_chart_repo`, and pinned `sealed_secrets_chart_version`
- [x] 1.3 In `tasks/main.yml`, add/update the Bitnami Sealed Secrets Helm repo and `helm upgrade --install` the controller into its namespace (idempotent)
- [x] 1.4 Wait for the controller Deployment to become Available with retries
- [x] 1.5 `kubectl apply` the committed `sealed-secrets/gcp/*.yaml` resources to the remote cluster

## 2. Playbook wiring

- [x] 2.1 Add the `sealed-secrets` role to `ansible/playbook.yml` in order `common → k3s → helm → image → sealed-secrets → deploy → verify`
- [x] 2.2 Add controller/namespace/version vars to `ansible/group_vars/gcp.yml` (and any shared defaults to `group_vars/all.yml`)

## 3. Chart GCP overlay: switch to existingSecret

- [x] 3.1 Set `database.existingSecret: zenyard-db` in `values-gcp.yaml` and remove the inline `database.password`
- [x] 3.2 Set `postgresql.auth.existingSecret: zenyard-postgresql` and remove the inline `postgresql.auth.password`
- [x] 3.3 Point the Grafana admin credential at `admin.existingSecret: zenyard-grafana` (kube-prometheus-stack `grafana.admin.existingSecret` with `userKey: admin-user`, `passwordKey: admin-password`) and remove the inline `grafana.adminPassword` values
- [x] 3.4 Confirm `values.yaml` and `values-local.yaml` remain unchanged and the chart still templates correctly (`helm template` with `values-local.yaml` and with `values-gcp.yaml`)

## 4. Sealed resources in the repo

- [x] 4.1 Create `sealed-secrets/gcp/` with placeholder/sealed `zenyard-db.yaml`, `zenyard-postgresql.yaml`, `zenyard-grafana.yaml`
- [x] 4.2 Write `sealed-secrets/README.md`: what SealedSecrets are, why they are safe to commit, key names per secret, how to re-seal, and the controller private-key backup/restore note
- [x] 4.3 Ensure any temporary plaintext Secret manifests used during sealing are git-ignored and never committed

## 5. Makefile targets (additive)

- [x] 5.1 Add `gcp-sealed-secrets-install` (Ansible/Helm install of the controller on the remote cluster)
- [x] 5.2 Add `gcp-seal-secrets` (run `kubeseal` against the remote controller over SSH from source env/var values; write encrypted YAML into `sealed-secrets/gcp/`; never echo plaintext)
- [x] 5.3 Add `gcp-apply-sealed-secrets` (`kubectl apply` the committed sealed YAML to the remote cluster)
- [x] 5.4 Ensure `gcp-redeploy` applies sealed secrets before the Helm upgrade; verify existing local and `gcp-*` targets are otherwise untouched

## 6. Documentation

- [x] 6.1 Update `README.md` to describe Sealed Secrets and state explicitly that the project uses Sealed Secrets **instead of Google Secret Manager**
- [x] 6.2 Update `ARCHITECTURE.md` and `docs/architecture.md` with the secret-management section (controller, sealing flow, existingSecret consumption, where sealed resources live)
- [x] 6.3 Update `docs/gcp-deployment.md` with the install → seal → apply → deploy flow, `kubeseal` prerequisite/version, and the private-key backup/restore guidance
- [x] 6.4 Document that the Phase 1 local workflow is unchanged and still uses inline demo credentials

## 7. Remote execution (after SSH key is provided)

- [x] 7.1 `make gcp-sealed-secrets-install` against the remote cluster
- [x] 7.2 `make gcp-seal-secrets` to seal the three credentials and copy the encrypted YAML back into `sealed-secrets/gcp/`
- [x] 7.3 `make gcp-apply-sealed-secrets` and confirm unsealed `Secret`s exist (`kubectl get secret zenyard-db zenyard-postgresql zenyard-grafana -n zenyard`)
- [x] 7.4 `make gcp-redeploy` and verify pods read credentials from the unsealed Secrets and the app connects to PostgreSQL

## 8. Validation

- [x] 8.1 Confirm no plaintext passwords remain in `values-gcp.yaml` and no plaintext Secret manifests are committed
- [x] 8.2 Run `make gcp-test` / `scripts/smoke-test-remote.sh` and confirm the full stack passes with sealed-secret-sourced credentials
- [x] 8.3 Dry-run review: GCP/local isolation preserved, controller install idempotent, sealed resources decrypt successfully
