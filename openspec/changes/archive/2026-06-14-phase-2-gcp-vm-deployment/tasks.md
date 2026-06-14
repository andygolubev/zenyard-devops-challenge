## 1. Ansible scaffolding and inventory

- [x] 1.1 Create `ansible/` tree: `playbook.yml`, `group_vars/{all.yml,gcp.yml}`, and `roles/{common,k3s,helm,image,deploy,verify}/{tasks/main.yml,defaults/main.yml}`
- [x] 1.2 Add `ansible/inventory.gcp.ini.example` (host, `ansible_user`, `ansible_ssh_private_key_file`) and ensure the real `ansible/inventory.gcp.ini` is git-ignored
- [x] 1.3 Wire `playbook.yml` to run roles in order `common → k3s → helm → image → deploy → verify`, targeting the `gcp` group, with `become: true` only where needed
- [x] 1.4 Define shared variables in `group_vars/all.yml` and GCP-specific overrides in `group_vars/gcp.yml` (k3s version, helm version, image name/tag, namespace, chart path, kube user)

## 2. common role

- [x] 2.1 Update apt cache (idempotent)
- [x] 2.2 Install minimal package set: `curl`, `ca-certificates`, `gnupg`, `jq`, `make`, `python3`, `python3-pip`, `python3-venv`, `tar`, `gzip`, `unzip`, `iptables`
- [x] 2.3 Expose package list and any toggles via `common/defaults/main.yml`

## 3. k3s role

- [x] 3.1 Install k3s at a pinned/configurable version using the official installer, keeping local-path, Traefik, and metrics-server defaults
- [x] 3.2 Ensure the k3s systemd service is enabled and running; make install idempotent (no-op if already active)
- [x] 3.3 Wait for Kubernetes API readiness and node `Ready` with retries
- [x] 3.4 Configure kubeconfig for the SSH user (`~/.kube/config`, correct ownership) so kubectl needs no sudo
- [x] 3.5 Expose `k3s_version` and related toggles in `k3s/defaults/main.yml`

## 4. helm role

- [x] 4.1 Install Helm at a pinned/configurable version
- [x] 4.2 Verify with `helm version`
- [x] 4.3 Expose `helm_version` in `helm/defaults/main.yml`

## 5. image role

- [x] 5.1 Build the FastAPI image locally and `docker save` it to a tar (delegated/local action)
- [x] 5.2 Copy the tar to the VM
- [x] 5.3 Import the tar into k3s containerd via `k3s ctr images import`
- [x] 5.4 Verify the image is present with `k3s ctr images list`
- [x] 5.5 Remove the temporary tar (local and remote) where practical; expose image name/tag in `image/defaults/main.yml`

## 6. deploy role

- [x] 6.1 Add/update required Helm repositories and run `helm dependency update` when needed
- [x] 6.2 Run `helm upgrade --install` of `charts/zenyard` into namespace `zenyard` using `values-gcp.yaml`, setting app image repository/tag/pullPolicy for the imported image
- [x] 6.3 Wait for key workloads to roll out where reasonable; expose deploy vars in `deploy/defaults/main.yml`

## 7. verify role

- [x] 7.1 Run `kubectl get nodes`, `get storageclass`, `get pods -A`, `top nodes`, `helm list -A`, `get ingress -n zenyard`
- [x] 7.2 Add retries/waits for components that need time (node Ready, metrics-server, rollout)

## 8. Chart GCP overlay

- [x] 8.1 Create `charts/zenyard/values-gcp.yaml` with `app.image.repository: zenyard-api`, `app.image.tag: gcp`, `app.image.pullPolicy: IfNotPresent`, ingress host, and demo credential overrides
- [x] 8.2 Confirm `values.yaml`, `values-local.yaml`, and all chart templates remain unchanged

## 9. Makefile GCP targets (additive)

- [x] 9.1 Add `gcp-bootstrap` (run Ansible against `inventory.gcp.ini`; bootstrap + verify node/storage/ingress/metrics)
- [x] 9.2 Add `gcp-build-image` and `gcp-load-image` (build/save/copy/import; configurable image name/tag)
- [x] 9.3 Add `gcp-helm-deps`, `gcp-deploy`, and `gcp-redeploy`
- [x] 9.4 Add `gcp-verify-k3s`, `gcp-test`, `gcp-info`
- [x] 9.5 Add `gcp-port-forward-grafana` (SSH tunnel / port-forward; no public exposure), `gcp-logs-app`, `gcp-logs-postgres`, `gcp-generate-slow-query`
- [x] 9.6 Verify existing `*-local` targets are untouched

## 10. Remote smoke test

- [x] 10.1 Create `scripts/smoke-test-remote.sh` checking remote kubectl, namespace, running pods, PostgreSQL ready, schema hook completed, FastAPI `/healthz` through ingress, TODO endpoints, Grafana/metrics/logging pods, and slow-query log entries
- [x] 10.2 Wire `make gcp-test` to invoke the script with the right env (ingress host/IP, namespace, SSH target)

## 11. Documentation

- [x] 11.1 Write `docs/gcp-deployment.md`: prerequisites, VM sizing (e2-standard-4 preferred / e2-standard-2 tight / 40–60 GB), firewall rules (SSH 22, optional HTTP 80, never PostgreSQL/Grafana), inventory setup, bootstrap → deploy → test, safe Grafana access, and cleanup
- [x] 11.2 Add troubleshooting for SSH problems, firewall blocking 80, node not Ready, metrics-server not ready, image pull errors, ingress not reachable, pods pending due to memory, Helm timeout, and local-path PVC issues
- [x] 11.3 Document that demo secrets must be overridden for real deployments

## 12. Validation

- [x] 12.1 Run `openspec validate phase-2-gcp-vm-deployment --strict` and resolve issues
- [x] 12.2 Dry-run review: confirm idempotency (rerun-safe), GCP/local isolation, and that no AWS/Terraform artifacts were introduced
