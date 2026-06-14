# Troubleshooting

## Missing Tools

Run:

```sh
make install-local-tools-help
```

Install Docker, k3d, kubectl, Helm, Make, curl, and jq before running the local workflow.

## Docker Is Not Running

Symptoms:

- `k3d cluster create` fails
- `docker build` fails

Fix:

Start Docker Desktop or the local Docker daemon, then retry the command.

## k3d Cluster Already Exists

`make create-local` is idempotent and reuses the existing `zenyard` cluster. To recreate it:

```sh
make restart-local
```

## kubectl Points at the Wrong Cluster

Run:

```sh
kubectl config use-context k3d-zenyard
kubectl get nodes
```

## local-path StorageClass Is Missing

k3s normally installs local-path storage by default. Check:

```sh
kubectl get storageclass
kubectl get pods -n kube-system
```

If it is missing, recreate the cluster:

```sh
make delete-local
make create-local
```

## kubectl top nodes Does Not Work

Metrics-server may need time to become ready:

```sh
kubectl get pods -n kube-system | grep metrics
kubectl logs -n kube-system deploy/metrics-server
kubectl top nodes
```

If metrics-server is absent or unhealthy, recreate the k3d cluster first. If it still fails, install or repair metrics-server for the local k3s version before continuing.

## Helm Dependency Update Fails

Run:

```sh
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
make helm-deps
```

## App Image Pull Fails

For local k3d clusters, build and import the image:

```sh
make build-image-local
make load-image-local
make deploy-local
```

Verify the image name matches the Helm values:

```sh
make local-info
```

## Ingress Does Not Respond

Check:

```sh
kubectl get ingress -n zenyard
kubectl get svc -n zenyard
kubectl get pods -n kube-system
curl -v http://localhost:8080/healthz
```

Confirm the cluster was created with:

```sh
-p "8080:80@loadbalancer"
```

## PostgreSQL Is Not Ready

Check:

```sh
kubectl get pods -n zenyard -l app.kubernetes.io/name=postgresql
kubectl describe pod -n zenyard -l app.kubernetes.io/name=postgresql
make logs-postgres
```

Common causes include insufficient local memory, pending persistent volume claims, or mismatched credentials.

## Schema Hook Fails

Check hook Jobs:

```sh
kubectl get jobs -n zenyard
kubectl logs -n zenyard job/zenyard-zenyard-postgres-init
```

The hook waits for PostgreSQL and uses `CREATE TABLE IF NOT EXISTS`, so repeated Helm upgrades should be safe once connectivity is available.

## Slow Query Logs Do Not Appear

Generate a slow query:

```sh
make generate-slow-query
```

Then check PostgreSQL logs:

```sh
make logs-postgres
```

The expected slow query threshold is 1000ms. The default generated query sleeps for 1.2 seconds.

## Grafana Is Not Reachable

Grafana is intentionally not exposed through ingress. Use:

```sh
make port-forward-grafana
```

Then open `http://localhost:3000`.

## Dashboard or Alert Is Missing

Check the provisioning ConfigMaps:

```sh
kubectl get configmap -n zenyard -l grafana_dashboard=1
kubectl get configmap -n zenyard -l grafana_alert=1
kubectl get pods -n zenyard -l app.kubernetes.io/name=grafana
```

Restart the Grafana pod if the sidecar has not picked up new ConfigMaps.

## Local Machine Resource Limits

The default stack includes PostgreSQL, Prometheus, Grafana, Loki, and Promtail. On constrained machines, disable observability in a custom values file:

```yaml
observability:
  metrics:
    enabled: false
  logs:
    enabled: false
  dashboard:
    enabled: false
  alerts:
    enabled: false
```

Then deploy with your override file in addition to `values-local.yaml`.

## Phase 1 Scope

This setup is local-only. It does not include Ansible, AWS, GCP, Terraform, remote VM provisioning, production HA PostgreSQL, external DNS, TLS certificates, real notification integrations, cloud container registry, or customer start/stop scripts.
