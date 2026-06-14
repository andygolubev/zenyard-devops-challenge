## 1. Dashboard ConfigMap template

- [x] 1.1 Add `charts/zenyard/templates/grafana-sql-transactions-dashboard.yaml` as a ConfigMap, mirroring `grafana-dashboard-configmap.yaml`: standard `zenyard.labels`, `app.kubernetes.io/component: dashboard`, and the `grafana_dashboard: "1"` label so the Grafana sidecar imports it
- [x] 1.2 Gate the whole template on `{{- if and .Values.observability.dashboard.enabled .Values.observability.logs.enabled }}` (no new values keys)
- [x] 1.3 Set dashboard metadata: `uid: zenyard-sql-tx`, `title: "Zenyard SQL Transactions"`, tags `["zenyard","postgresql","logs"]`, sensible default time range and refresh

## 2. Panels (Loki-backed)

- [x] 2.1 Panel "Slow SQL statements (>1s)" — timeseries using LogQL `sum(count_over_time({namespace="{{ .Release.Namespace }}", pod=~"zenyard-postgresql.*"} |= "duration:" [10m]))`, reusing the exact selector from `alert-rules.yaml`; targets the Loki datasource (uid `Loki`)
- [x] 2.2 Panel "Recent slow SQL statements" — `logs` panel querying `{namespace="{{ .Release.Namespace }}", pod=~"zenyard-postgresql.*"} |= "duration:"`, showing time/text, newest first
- [x] 2.3 Panel "Top slow statements" — table aggregating slow-query log lines (e.g. `topk` over `count_over_time` / instant query) so frequent offenders are visible
- [x] 2.4 Escape Go-template-conflicting Grafana tokens (e.g. `{{`{{pod}}`}}`) and verify all `{{ .Release.Namespace }}` / `{{ .Values.database.name }}` interpolations are correct

## 3. Render and lint

- [x] 3.1 `helm template` the chart with `values-local.yaml` and confirm the new ConfigMap renders with valid JSON in the dashboard key (pipe the JSON through a parser)
- [x] 3.2 Confirm the template is omitted when `observability.dashboard.enabled=false` or `observability.logs.enabled=false`
- [x] 3.3 `helm lint charts/zenyard` passes

## 4. Deploy and verify locally

- [x] 4.1 `helm upgrade --install` the release locally (existing local target) and confirm the ConfigMap exists: `kubectl get configmap -l grafana_dashboard=1`
- [x] 4.2 Port-forward Grafana and confirm the "Zenyard SQL Transactions" dashboard appears and loads without datasource errors
- [x] 4.3 Generate slow queries (existing slow-query generator) and confirm the time series, logs panel, and table populate with the SQL statement text
- [x] 4.4 Sanity-check that the dashboard's slow-statement count tracks the same data that drives the `zenyard-slow-sql` alert

## 5. Verification hooks and docs

- [x] 5.1 Extend the local/remote verification (smoke test) to assert the new dashboard ConfigMap is present
- [x] 5.2 Add a short note in the relevant `docs/` page pointing operators to "Zenyard SQL Transactions" for inspecting slow SQL when the alert fires
- [x] 5.3 Confirm no change is needed for the GCP overlay (works via the same toggles) and that `values-gcp.yaml` still deploys cleanly
