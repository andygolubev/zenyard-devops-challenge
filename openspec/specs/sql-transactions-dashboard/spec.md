## ADDED Requirements

### Requirement: SQL transactions dashboard provisioned via Grafana sidecar
The `zenyard` chart SHALL provide a Grafana dashboard titled "Zenyard SQL Transactions" (uid `zenyard-sql-tx`) delivered as a ConfigMap labelled `grafana_dashboard: "1"`, so the Grafana sidecar auto-imports it without manual configuration. The dashboard SHALL be rendered only when both `observability.dashboard.enabled` and `observability.logs.enabled` are true, and SHALL NOT introduce any new values keys, datasources, exporters, or runtime services.

#### Scenario: Dashboard ConfigMap is created on deploy
- **WHEN** the chart is deployed with `observability.dashboard.enabled=true` and `observability.logs.enabled=true`
- **THEN** a ConfigMap labelled `grafana_dashboard: "1"` containing the "Zenyard SQL Transactions" dashboard JSON exists in the release namespace
- **AND** the Grafana sidecar imports it so the dashboard appears in Grafana alongside "Zenyard Database Activity"

#### Scenario: Dashboard omitted when logs or dashboards are disabled
- **WHEN** the chart is templated with `observability.logs.enabled=false` (or `observability.dashboard.enabled=false`)
- **THEN** the SQL transactions dashboard ConfigMap is not rendered

### Requirement: Visualize slow SQL statements from Loki
The dashboard SHALL visualize PostgreSQL slow-query (statements exceeding 1 second) logs sourced from the existing Loki datasource, using the same log selector the `zenyard-slow-sql` alert uses (`{namespace="<release-namespace>", pod=~"zenyard-postgresql.*"} |= "duration:"`), so the dashboard and the alert reflect the same underlying data.

#### Scenario: Slow statements appear after slow queries run
- **WHEN** one or more SQL statements taking longer than 1 second have executed and been logged to Loki
- **THEN** the dashboard's slow-statement time series shows a non-zero count over the affected interval
- **AND** the logs panel shows the corresponding slow-query log lines including the SQL statement text

#### Scenario: Dashboard and alert agree
- **WHEN** the `zenyard-slow-sql` alert evaluates its 10-minute slow-statement count
- **THEN** the dashboard's slow-statement panel, querying the same selector and window, reflects the same count

### Requirement: Panels for count, statement text, and frequency
The dashboard SHALL include at minimum: (a) a time-series panel of the count of slow SQL statements over time aligned to a 10-minute window, (b) a logs panel showing the raw slow-query log lines (timestamp, duration, SQL text) for the selected range, and (c) a table panel surfacing the most frequent slow statements.

#### Scenario: Operator inspects slow SQL after an alert
- **WHEN** an operator opens "Zenyard SQL Transactions" after the slow-SQL alert fires
- **THEN** they can see how many slow statements occurred and when, read the actual SQL statement text, and identify which statements recur most often — without leaving Grafana
