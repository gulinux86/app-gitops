{{/* Resource names and the selector value. */}}
{{- define "service.name" -}}
{{- default .Release.Name .Values.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
`app: <name>` is the selector, kept from the plain manifests the chart replaced:
a Deployment's selector cannot change in place.
*/}}
{{- define "service.selector" -}}
app: {{ include "service.name" . }}
{{- end -}}

{{- define "service.labels" -}}
{{ include "service.selector" . }}
app.kubernetes.io/name: {{ include "service.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/*
What the schema cannot express: relations between values.
*/}}
{{- define "service.validate" -}}
{{- if ne (toString .Values.resources.requests.memory) (toString .Values.resources.limits.memory) -}}
{{- fail (printf "resources: memory request (%v) must equal its limit (%v) — Karpenter packs by requests" .Values.resources.requests.memory .Values.resources.limits.memory) -}}
{{- end -}}
{{- if le (int .Values.terminationGracePeriodSeconds) (int .Values.preStopSeconds) -}}
{{- fail (printf "terminationGracePeriodSeconds (%v) must exceed preStopSeconds (%v), or the kubelet kills the container mid-sleep" .Values.terminationGracePeriodSeconds .Values.preStopSeconds) -}}
{{- end -}}
{{- end -}}
