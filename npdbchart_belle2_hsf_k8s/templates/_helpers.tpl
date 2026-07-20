{{/*
Expand the name of the chart.
*/}}
{{- define "npdbchart.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Build the image reference used by a workload. Kubernetes pulls the configured
image directly, while OpenShift workloads consume the chart-managed ImageStream.
*/}}
{{- define "npdbchart.workloadImage" -}}
{{- if eq .root.Values.platform "openshift" -}}
{{- printf "image-registry.openshift-image-registry.svc:5000/%s/%s-%s:%s" .root.Release.Namespace (include "npdbchart.fullname" .root) .component .image.tag -}}
{{- else -}}
{{- printf "%s:%s" .image.repository .image.tag -}}
{{- end -}}
{{- end }}

{{/* Build the external image reference imported by an OpenShift ImageStream. */}}
{{- define "npdbchart.externalImage" -}}
{{- printf "%s:%s" .repository .tag -}}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "npdbchart.fullname" -}}
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
{{- define "npdbchart.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "npdbchart.labels" -}}
helm.sh/chart: {{ include "npdbchart.chart" . }}
{{ include "npdbchart.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "npdbchart.selectorLabels" -}}
app.kubernetes.io/name: {{ include "npdbchart.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "npdbchart.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "npdbchart.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
