## Why

PostgreSQL is configured to log every statement that takes longer than 1 second (`log_min_duration_statement = 1000`), and those slow-query log lines are shipped to Loki and consumed by the existing `zenyard-slow-sql` alert. But there is no way to *see* those SQL transactions: the existing "Zenyard Database Activity" dashboard is purely metric-based (queries/sec, latency, CPU, memory) and never surfaces the actual statement text. When the slow-SQL alert fires, an operator has no in-Grafana view to ask "*which* statements were slow, and how often?" — they must drop to `kubectl logs` or Explore. This change closes that gap by visualizing the SQL transactions we already collect.

## What Changes

- Add a Grafana dashboard, **"Zenyard SQL Transactions"**, backed by the existing Loki datasource, that surfaces the slow-query logs the cluster already produces.
- Panels:
  - **Slow SQL statements over time** — rate/count of statements exceeding 1s (`count_over_time` of postgres logs matching `duration:`), aligned with the alert's 10-minute window so the dashboard and alert tell the same story.
  - **Recent slow SQL statements (logs)** — a Loki logs panel showing the raw slow-query log lines (timestamp, duration, SQL text) for the selected time range.
  - **Top slow statements** — a table aggregating slow-query occurrences so repeat offenders are visible at a glance.
- Ship the dashboard the same way as the existing one: a ConfigMap labelled `grafana_dashboard: "1"` so the Grafana sidecar auto-imports it; gated on the existing `observability.dashboard.enabled` and `observability.logs.enabled` toggles.
- No new collectors, exporters, datasources, or runtime services — this only adds a dashboard over data already in Loki.

## Capabilities

### New Capabilities
- `sql-transactions-dashboard`: A Grafana dashboard that visualizes PostgreSQL slow-query (SQL transaction) logs from Loki — a time series of slow statements, a live logs panel showing statement text, and a table of the most frequent slow statements — auto-provisioned via the Grafana sidecar and gated on the existing observability toggles.

### Modified Capabilities
<!-- None. The existing metric dashboard, slow-query logging, Loki/Promtail pipeline, and alert rule are unchanged; this adds a sibling dashboard over the same log data. -->

## Impact

- **New files**: `charts/zenyard/templates/grafana-sql-transactions-dashboard.yaml` (ConfigMap with the dashboard JSON).
- **Modified**: possibly `docs/` (a note pointing operators at the new dashboard) and the Phase 1 verification/smoke checks to assert the new ConfigMap is present. No chart-architecture changes.
- **Unchanged**: PostgreSQL config, Promtail/Loki pipeline, the existing `zenyard-db` dashboard, the `zenyard-slow-sql` alert, `values.yaml` structure (reuses `observability.dashboard.enabled` / `observability.logs.enabled`), all Makefile targets, and the GCP overlay.
- **Operational**: appears automatically in Grafana on the next `helm upgrade`; no new credentials, ports, or exposure. Grafana stays non-public (port-forward / SSH tunnel) exactly as before.
