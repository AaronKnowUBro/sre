{{/*
Nombre base del chart, recortado a 63 caracteres porque es el limite de
longitud de una etiqueta en Kubernetes.
*/}}
{{- define "sre-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Nombre completo de los recursos. Si el nombre del release ya contiene el
nombre del chart, no se duplica.
*/}}
{{- define "sre-app.fullname" -}}
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
Etiquetas estandar recomendadas por Kubernetes. Permiten identificar quien
desplego el recurso y con que version del chart.
*/}}
{{- define "sre-app.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "sre-app.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Etiquetas de seleccion: son inmutables en un Deployment, por eso se mantienen
separadas de las etiquetas informativas.
*/}}
{{- define "sre-app.selectorLabels" -}}
app: {{ include "sre-app.name" . }}
app.kubernetes.io/name: {{ include "sre-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
