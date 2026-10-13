{{/*
Expand the name of the chart.
*/}}
{{- define "powersync-helm-chart-demo.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common name helper (reusable)
*/}}
{{- define "common.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "powersync-helm-chart-demo.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "powersync-helm-chart-demo.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "powersync-helm-chart-demo.labels" -}}
helm.sh/chart: {{ include "powersync-helm-chart-demo.chart" . }}
{{ include "powersync-helm-chart-demo.selectorLabels" . | nindent 0 }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "powersync-helm-chart-demo.selectorLabels" -}}
app.kubernetes.io/name: {{ include "powersync-helm-chart-demo.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "powersync-helm-chart-demo.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "powersync-helm-chart-demo.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Optional: Helm release annotations (used by Helm, Argo CD, etc.)
*/}}
{{- define "powersync-helm-chart-demo.annotations" -}}
meta.helm.sh/release-name: {{ .Release.Name }}
meta.helm.sh/release-namespace: {{ .Release.Namespace }}
{{- end }}

{{/* Select and validate the shared Kubernetes and service probe mode. */}}
{{- define "powersync-helm-chart-demo.probeType" -}}
{{- $type := .Values.env.MICRO_PROBE_TYPE | default "fs" -}}
{{- if not (has $type (list "fs" "http")) -}}
{{- fail "env.MICRO_PROBE_TYPE must be fs or http" -}}
{{- end -}}
{{- $type -}}
{{- end -}}

{{/* Probe handler shared by the API and replication deployments. */}}
{{- define "powersync-helm-chart-demo.probeHandler" -}}
{{- if eq (include "powersync-helm-chart-demo.probeType" .root) "http" }}
httpGet:
  path: /probes/{{ .httpPath }}
  port: {{ .root.Values.powersyncConfig.port | default 8080 }}
{{- else }}
exec:
  command:
    - cat
    - /app/.probes/{{ .file }}
{{- end }}
{{- end -}}
