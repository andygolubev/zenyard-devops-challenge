{{- define "zenyard.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "zenyard.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "zenyard.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "zenyard.labels" -}}
app.kubernetes.io/name: {{ include "zenyard.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: zenyard
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "zenyard.selectorLabels" -}}
app.kubernetes.io/name: {{ include "zenyard.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: api
{{- end -}}

{{- define "zenyard.dbSecretName" -}}
{{- default (printf "%s-db" (include "zenyard.fullname" .)) .Values.database.existingSecret -}}
{{- end -}}

{{- define "zenyard.grafanaSecretName" -}}
{{- default "zenyard-grafana" .Values.grafana.existingSecret -}}
{{- end -}}
