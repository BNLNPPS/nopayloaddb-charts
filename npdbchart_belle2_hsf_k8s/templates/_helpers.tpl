{{/*
Expand the name of the chart.
*/}}
{{- define "npdbchart.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Return the existing or chart-managed payload PVC name. */}}
{{- define "npdbchart.payloadClaimName" -}}
{{- if .Values.storage.payload.existingClaim -}}
{{- .Values.storage.payload.existingClaim -}}
{{- else -}}
{{- printf "%s-payload" (include "npdbchart.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
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

{{/* Reproduce the default fullname used by the Bitnami PostgreSQL subchart. */}}
{{- define "npdbchart.postgresql.fullname" -}}
{{- if .Values.postgresql.fullnameOverride -}}
{{- .Values.postgresql.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default "postgresql" .Values.postgresql.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Return one database connection field. An enabled PostgreSQL dependency is the
writer and both readers; otherwise use the corresponding external connection.
*/}}
{{- define "npdbchart.databaseValue" -}}
{{- if .root.Values.postgresql.enabled -}}
{{- if eq .field "host" -}}
{{- include "npdbchart.postgresql.fullname" .root -}}
{{- else if eq .field "port" -}}
{{- print "5432" -}}
{{- else if eq .field "name" -}}
{{- .root.Values.postgresql.auth.database -}}
{{- else if eq .field "user" -}}
{{- .root.Values.postgresql.auth.username -}}
{{- else if eq .field "password" -}}
{{- .root.Values.postgresql.auth.password -}}
{{- end -}}
{{- else -}}
{{- index (index .root.Values.database .connection) .field -}}
{{- end -}}
{{- end }}

{{/*
Render the value or Secret reference for an application database password.
The bundled PostgreSQL chart gives an existing Secret precedence over the
literal password, so application workloads must do the same.
*/}}
{{- define "npdbchart.databasePasswordEnv" -}}
{{- if and .root.Values.postgresql.enabled .root.Values.postgresql.auth.existingSecret -}}
valueFrom:
  secretKeyRef:
    name: {{ .root.Values.postgresql.auth.existingSecret | quote }}
    key: {{ .root.Values.postgresql.auth.secretKeys.userPasswordKey | quote }}
{{- else -}}
value: {{ include "npdbchart.databaseValue" (dict "root" .root "connection" .connection "field" "password") | quote }}
{{- end -}}
{{- end }}

{{/* Render the database environment shared by Django and its migration init container. */}}
{{- define "npdbchart.djangoDatabaseEnv" -}}
- name: POSTGRES_HOST_W
  value: {{ if .Values.pgbouncer.enabled }}{{ include "npdbchart.fullname" . }}-pgbouncer{{ else }}{{ include "npdbchart.databaseValue" (dict "root" . "connection" "writer" "field" "host") }}{{ end }}
- name: POSTGRES_DB_W
  value: {{ include "npdbchart.databaseValue" (dict "root" . "connection" "writer" "field" "name") }}
- name: POSTGRES_USER_W
  value: {{ include "npdbchart.databaseValue" (dict "root" . "connection" "writer" "field" "user") }}
- name: POSTGRES_PASSWORD_W
  {{- include "npdbchart.databasePasswordEnv" (dict "root" . "connection" "writer") | nindent 2 }}
- name: POSTGRES_PORT_W
  value: {{ if .Values.pgbouncer.enabled }}"6432"{{ else }}{{ include "npdbchart.databaseValue" (dict "root" . "connection" "writer" "field" "port") | quote }}{{ end }}
- name: POSTGRES_HOST_R1
  value: {{ if .Values.pgbouncer.enabled }}{{ include "npdbchart.fullname" . }}-pgbouncer{{ else }}{{ include "npdbchart.databaseValue" (dict "root" . "connection" "reader1" "field" "host") }}{{ end }}
- name: POSTGRES_DB_R1
  value: {{ include "npdbchart.databaseValue" (dict "root" . "connection" "reader1" "field" "name") }}
- name: POSTGRES_USER_R1
  value: {{ include "npdbchart.databaseValue" (dict "root" . "connection" "reader1" "field" "user") }}
- name: POSTGRES_PASSWORD_R1
  {{- include "npdbchart.databasePasswordEnv" (dict "root" . "connection" "reader1") | nindent 2 }}
- name: POSTGRES_PORT_R1
  value: {{ if .Values.pgbouncer.enabled }}"6432"{{ else }}{{ include "npdbchart.databaseValue" (dict "root" . "connection" "reader1" "field" "port") | quote }}{{ end }}
- name: POSTGRES_HOST_R2
  value: {{ if .Values.pgbouncer.enabled }}{{ include "npdbchart.fullname" . }}-pgbouncer{{ else }}{{ include "npdbchart.databaseValue" (dict "root" . "connection" "reader2" "field" "host") }}{{ end }}
- name: POSTGRES_DB_R2
  value: {{ include "npdbchart.databaseValue" (dict "root" . "connection" "reader2" "field" "name") }}
- name: POSTGRES_USER_R2
  value: {{ include "npdbchart.databaseValue" (dict "root" . "connection" "reader2" "field" "user") }}
- name: POSTGRES_PASSWORD_R2
  {{- include "npdbchart.databasePasswordEnv" (dict "root" . "connection" "reader2") | nindent 2 }}
- name: POSTGRES_PORT_R2
  value: {{ if .Values.pgbouncer.enabled }}"6432"{{ else }}{{ include "npdbchart.databaseValue" (dict "root" . "connection" "reader2" "field" "port") | quote }}{{ end }}
{{- end }}

{{/*
Render the payload-file locations shared by both NGINX virtual hosts. Downloads
remain public unless explicitly protected, while uploads are always
authenticated.
*/}}
{{- define "npdbchart.dbstoreLocations" -}}
{{- $authenticationRequired := or .Values.files.upload.enabled .Values.files.authentication.requireForDownloads -}}
{{- if $authenticationRequired }}
location = /_npdb_files_auth {
    internal;
    proxy_pass {{ required "files.authentication.userinfoUrl is required when file authentication is enabled" .Values.files.authentication.userinfoUrl | quote }};
    proxy_method GET;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
    proxy_set_header Authorization $http_authorization;
    proxy_ssl_server_name on;
    proxy_cache off;
}
{{- end }}

location /dbstore {
    root /usr/share/nginx/html;
    proxy_hide_header Cache-Control;
    add_header Cache-Control {{ .Values.nginx.cacheControl | quote }};
    {{- if .Values.files.authentication.requireForDownloads }}
    auth_request /_npdb_files_auth;
    {{- end }}
    limit_except GET HEAD {
        deny all;
    }
}
{{- if .Values.files.upload.enabled }}

location /upload/ {
    alias /usr/share/nginx/html/dbstore/;
    auth_request /_npdb_files_auth;
    dav_methods PUT;
    create_full_put_path on;
    dav_access user:rw group:rw all:r;
    limit_except PUT {
        deny all;
    }
}
{{- end }}
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
