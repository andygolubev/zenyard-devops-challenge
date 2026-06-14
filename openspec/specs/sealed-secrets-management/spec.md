## ADDED Requirements

### Requirement: Sealed Secrets controller on the remote cluster
The system SHALL install a Bitnami Sealed Secrets controller on the remote k3s cluster via an idempotent Ansible `sealed-secrets` role and the `make gcp-sealed-secrets-install` target, using a pinned/configurable chart version and namespace. The controller install SHALL be safe to rerun.

#### Scenario: Install the controller
- **WHEN** an operator runs `make gcp-sealed-secrets-install` against a bootstrapped VM
- **THEN** the Sealed Secrets controller is installed via Helm into its configured namespace and its Deployment becomes Available

#### Scenario: Reinstalling is safe
- **WHEN** an operator reruns the controller install on a cluster that already has it
- **THEN** the run completes successfully with no destructive change and the existing controller and its sealing key are preserved

### Requirement: Seal credentials against the remote cluster
The system SHALL provide `make gcp-seal-secrets` that uses `kubeseal` against the remote cluster's controller to encrypt the stack credentials into `SealedSecret` resources, reading source credential values from environment/variables (never committed in plaintext) and writing the encrypted YAML into `sealed-secrets/gcp/`. The sealing SHALL produce three resources: an app/DB secret (`zenyard-db` with keys `DB_USER`, `DB_PASSWORD`), a PostgreSQL subchart secret (`zenyard-postgresql` with the Bitnami-expected keys), and a Grafana admin secret (`zenyard-grafana` with keys `admin-user`, `admin-password`). The DB password and the PostgreSQL `password` key SHALL be sealed from the same source value.

#### Scenario: Seal the credentials
- **WHEN** an operator runs `make gcp-seal-secrets` with source credential values after the controller is installed
- **THEN** `kubeseal` encrypts the credentials against the remote controller's public certificate
- **AND** the encrypted `SealedSecret` YAML for `zenyard-db`, `zenyard-postgresql`, and `zenyard-grafana` is written into `sealed-secrets/gcp/`
- **AND** no plaintext credential value is written to the repository

#### Scenario: App and PostgreSQL passwords agree
- **WHEN** the credentials are sealed
- **THEN** the DB user password in `zenyard-db` and the `password` key in `zenyard-postgresql` hold the same value

### Requirement: Committable encrypted secrets in the repository
Sealed resources SHALL be stored under `sealed-secrets/gcp/` and SHALL be safe to commit to git because they are asymmetrically encrypted and only the remote controller can decrypt them. Plaintext `Secret` manifests used during sealing SHALL NOT be committed. The repository SHALL include `sealed-secrets/README.md` explaining the approach, the per-secret key names, how to re-seal, and that the controller's private sealing key must be backed up.

#### Scenario: Only encrypted material is committed
- **WHEN** reviewing `sealed-secrets/gcp/`
- **THEN** it contains only `SealedSecret` resources with encrypted values and no plaintext credentials

#### Scenario: Documentation explains re-sealing and key backup
- **WHEN** an operator reads `sealed-secrets/README.md`
- **THEN** it explains why the resources are committable, the key names per secret, how to re-seal, and how to back up and restore the controller's sealing key

### Requirement: Apply sealed secrets before deployment
The system SHALL apply the committed `SealedSecret` resources to the remote cluster via `make gcp-apply-sealed-secrets` and via the `sealed-secrets` Ansible role, which runs before the `deploy` role in the playbook order `common → k3s → helm → image → sealed-secrets → deploy → verify`. After application, the controller SHALL unseal each `SealedSecret` into a corresponding `Secret`.

#### Scenario: SealedSecrets unseal into Secrets
- **WHEN** an operator runs `make gcp-apply-sealed-secrets` on a cluster with the controller installed
- **THEN** the controller decrypts each `SealedSecret` into a `Secret` (`zenyard-db`, `zenyard-postgresql`, `zenyard-grafana`) in the target namespace

#### Scenario: Secrets exist before the chart is deployed
- **WHEN** the playbook runs end to end
- **THEN** the unsealed `Secret`s exist before `helm upgrade --install` runs, so the chart's `existingSecret` references resolve

### Requirement: Chart consumes sealed-secret credentials via existingSecret
The GCP overlay `charts/zenyard/values-gcp.yaml` SHALL consume credentials through the chart's `existingSecret` hooks — `database.existingSecret: zenyard-db`, `postgresql.auth.existingSecret: zenyard-postgresql`, and the Grafana `admin.existingSecret: zenyard-grafana` — and SHALL NOT contain any plaintext password values. The chart templates SHALL remain unchanged and their inline-Secret fallback SHALL stay intact for environments where `existingSecret` is unset.

#### Scenario: No plaintext credentials in the GCP overlay
- **WHEN** reviewing `charts/zenyard/values-gcp.yaml`
- **THEN** it references the sealed-secret-derived Secrets via `existingSecret` and contains no plaintext `password` or `adminPassword` values

#### Scenario: App reads credentials from the unsealed Secret
- **WHEN** the release is deployed with `values-gcp.yaml` and the unsealed Secrets present
- **THEN** the FastAPI app and the schema init job read DB credentials from `zenyard-db`
- **AND** PostgreSQL uses `zenyard-postgresql`
- **AND** Grafana uses `zenyard-grafana`
- **AND** the chart does not template a plaintext `Secret` for these credentials

### Requirement: Sealed Secrets documented as the chosen approach instead of Google Secret Manager
`README.md`, `ARCHITECTURE.md`, and the docs (`docs/architecture.md`, `docs/gcp-deployment.md`) SHALL document the Sealed Secrets approach and SHALL state explicitly that the project uses Sealed Secrets **instead of Google Secret Manager**, including the rationale and the install → seal → apply → deploy flow.

#### Scenario: Docs state the choice and rationale
- **WHEN** an operator reads the README and architecture docs
- **THEN** they explain that Sealed Secrets is used instead of Google Secret Manager, why, and how secrets flow from sealing to consumption

#### Scenario: GCP deployment doc covers the flow and prerequisites
- **WHEN** an operator reads `docs/gcp-deployment.md`
- **THEN** it documents the `kubeseal` prerequisite, the controller install, the seal/apply/deploy sequence, and controller private-key backup/restore

### Requirement: Local workflow unchanged
The Phase 1 local workflow SHALL remain unchanged: `values-local.yaml`, the local Make targets, and the chart templates SHALL continue to use inline demo credentials with no Sealed Secrets dependency. Sealed Secrets SHALL apply only to the remote/GCP path.

#### Scenario: Local deployment needs no Sealed Secrets
- **WHEN** an operator runs the local k3d workflow after this change
- **THEN** it deploys with inline demo credentials exactly as before, with no controller, `kubeseal`, or `existingSecret` requirement
