# Local Development

This Phase 1 environment runs the Zenyard DevOps Challenge stack on a disposable local k3d/k3s cluster. It is intended for fast local validation before any remote Ubuntu Server VM work.

## Required Tools

- Docker
- k3d
- kubectl
- Helm
- Make
- curl
- jq

Run:

```sh
make install-local-tools-help
```

## Create the Local Cluster

```sh
make create-local
```

This creates a k3d cluster named `zenyard` with one server and maps `localhost:8080` to the k3s ingress controller on port 80:

```sh
k3d cluster create zenyard --servers 1 --agents 0 -p "8080:80@loadbalancer"
```

The target waits for a Ready node, verifies kubectl connectivity, checks the `local-path` StorageClass, and verifies `kubectl top nodes`.

## Build and Load the App Image

```sh
make build-image-local
make load-image-local
```

The default image is `zenyard-api:local`. Override it when needed:

```sh
make build-image-local IMAGE=my-api:dev
make load-image-local IMAGE=my-api:dev
```

## Deploy

```sh
make helm-deps
make deploy-local
```

The Helm release is installed into namespace `zenyard` using `charts/zenyard/values-local.yaml`.

For the normal inner loop:

```sh
make redeploy-local
```

## Test

```sh
make test-local
```

The smoke test verifies:

- namespace exists
- pods become Ready
- PostgreSQL is Ready
- `GET /healthz` works through `http://localhost:8080`
- TODO create/list/complete works through ingress
- Grafana is running when observability is enabled
- Prometheus is running when metrics are enabled
- Loki and Promtail are running when logs are enabled

Manual checks:

```sh
curl http://localhost:8080/healthz
curl http://localhost:8080/todos
```

## Generate Slow Queries

```sh
make generate-slow-query
```

The helper runs:

```sql
SELECT pg_sleep(1.2);
```

PostgreSQL is configured to log statements slower than 1000ms. Use this helper to verify PostgreSQL container logs, Loki collection, and the Grafana slow SQL alert.

## Grafana Access

Grafana is not exposed through ingress. Use port-forwarding:

```sh
make port-forward-grafana
```

Open `http://localhost:3000`.

Default local credentials:

- username: `admin`
- password: `zenyard-local-admin`

To retrieve the active password from Kubernetes:

```sh
kubectl get secret -n zenyard zenyard-grafana -o jsonpath='{.data.admin-password}' | base64 -d
```

## Useful Debug Commands

```sh
make local-info
make logs-app
make logs-postgres
kubectl get pods -n zenyard -o wide
kubectl describe pod -n zenyard <pod-name>
helm status zenyard -n zenyard
```

## Cleanup

Remove only the Helm release:

```sh
make uninstall-local
```

Delete the full disposable cluster:

```sh
make delete-local
```

Recreate from scratch:

```sh
make restart-local
```

## Scope

Phase 1 is local-only. It intentionally excludes Ansible, AWS, GCP, Terraform, remote VM provisioning, production HA PostgreSQL, external DNS, TLS certificates, real notification integrations, cloud container registry, and customer start/stop scripts.

The local passwords in `values-local.yaml` are for local development only. Any real deployment must override them with environment-specific secrets.
