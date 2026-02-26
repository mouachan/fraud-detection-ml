{{/*
Expand the name of the chart.
*/}}
{{- define "fraud-detection-feast.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "fraud-detection-feast.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "fraud-detection-feast.labels" -}}
helm.sh/chart: {{ include "fraud-detection-feast.chart" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Namespace
*/}}
{{- define "fraud-detection-feast.namespace" -}}
{{- .Values.namespace }}
{{- end }}
