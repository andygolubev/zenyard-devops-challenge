## Context

The `zenyard` Helm chart already delivers the full observability stack: kube-prometheus-stack (Prometheus + Grafana) and loki-stack (Loki + Promtail). PostgreSQL runs with `log_min_duration_statement = 1000`, so every statement slower than 1s is written to the postgres container log. Promtail ships those logs to Loki; the existing `zenyard-slow-sql` alert (`charts/zenyard/templates/alert-rules.yaml`) already queries them with `count_over_time({namespace=..., pod=~"zenyard-postgresql.*"} |= "duration:" [10m])` and fires when the count exceeds 3 in 10 minutes.

The existing dashboard (`charts/zenyard/templates/grafana-dashboard-configmap.yaml`, uid `zenyard-db`) is metric-only and reads from Prometheus. Nothing in Grafana shows the SQL statement text itself. Both the existing dashboard and the alert are auto-provisioned: dashboards via a ConfigMap labelled `grafana_dashboard: "1"` picked up by the Grafana sidecar; the alert via a ConfigMap labelled `grafana_alert: "1"`.

This change adds a second dashboard over the *log* data that is already being collected, reusing the exact label selector the alert uses so the two never disagree.

## Goals / Non-Goals

**Goals:**
- A Grafana dashboard that makes slow SQL transactions visible: how many, when, the statement text, and which statements repeat.
- Reuse the existing Loki datasource and the alert's proven log selector (`{namespace, pod=~"zenyard-postgresql.*"} |= "duration:"`).
- Auto-provision via the Grafana sidecar exactly like the existing dashboard; gate on existing toggles.
- Keep the change additive and chart-architecture-neutral; works identically local (k3d) and on the GCP k3s VM.

**Non-Goals:**
- New exporters, datasources, parsing pipelines, or PostgreSQL config changes.
- Per-statement latency histograms or `pg_stat_statements` (would need an extension/exporter; out of scope).
- Real alert notification integrations or changes to the existing alert.
- Exposing Grafana publicly.

## Decisions

**1. Log-based dashboard from Loki, not new metrics.**
The "SQL transactions" the task cares about are the slow-query statements we already log. Building the dashboard on Loki means zero new collection and a single source of truth shared with the alert. Alternative — adding `pg_stat_statements` + an exporter for per-query metrics — is more powerful but adds a Postgres extension, an exporter, and Prometheus series for a demo-scale need; rejected as over-scoped.

**2. Reuse the alert's exact selector.**
The time-series panel uses the same `{namespace="<ns>", pod=~"zenyard-postgresql.*"} |= "duration:"` LogQL the alert uses, so "what the dashboard shows" and "what trips the alert" are provably the same data. The threshold/window are visualized (10m window) so an operator can see the alert condition forming.

**3. Provision as a sidecar ConfigMap, mirroring the existing dashboard.**
New template `grafana-sql-transactions-dashboard.yaml` produces a ConfigMap with label `grafana_dashboard: "1"`, identical mechanism to `grafana-dashboard-configmap.yaml`. No Grafana provisioning config or datasource wiring changes. The dashboard's Loki targets reference the datasource by name/uid `Loki`, the same uid the alert already relies on.

**4. Gate on existing toggles, no new values.**
Render only when `observability.dashboard.enabled` AND `observability.logs.enabled` are true — a SQL-log dashboard is meaningless without log collection. No new keys in `values.yaml`; keeps the values contract stable across `values-local.yaml` and `values-gcp.yaml`.

**5. Three panels, deliberately minimal.**
(a) time series of slow-statement count, (b) a Loki **logs** panel for raw statement text, (c) a table of most-frequent slow statements. Enough to answer "how bad, when, and which queries" without dashboard sprawl.

## Risks / Trade-offs

- **LogQL label/format drift** — if the postgres log line format or the `duration:` marker changes, panels and the alert break together. Mitigated by reusing one selector and documenting it; acceptable because they fail consistently.
- **Datasource uid assumption** — the dashboard assumes the Loki datasource uid is `Loki` (as the alert does). If loki-stack provisioning changes the uid, both this dashboard and the existing alert would need updating; this keeps the assumption centralized and already in use.
- **Table aggregation fidelity** — grouping "top statements" from free-text logs is approximate (raw lines include bind values/durations). Acceptable for a demo-grade view; the logs panel always shows ground truth.

## Migration Plan

Additive only. On the next `helm upgrade --install`, the new ConfigMap is created and the Grafana sidecar imports the dashboard within its sync interval; it appears alongside "Zenyard Database Activity". No data migration, no downtime, no manual Grafana steps. Rollback = remove the template / set `observability.dashboard.enabled=false`; nothing else depends on it.

## Open Questions

- Should the "top slow statements" table normalize statements (strip literals) for tighter grouping? Deferred — start with raw-line aggregation and revisit if noisy.
