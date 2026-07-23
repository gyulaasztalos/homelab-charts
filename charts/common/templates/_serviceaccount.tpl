{{/*
common.serviceaccount — optional ServiceAccount for the workload. Rendered only
when .Values.serviceAccount.create is true. The pod references it via
.Values.serviceAccountName (see common.podSpec). Name defaults to the app name.
*/}}
{{- define "common.serviceaccount" -}}
{{- if .Values.serviceAccount }}
{{- if .Values.serviceAccount.create -}}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ .Values.serviceAccount.name | default (include "common.name" .) }}
  namespace: {{ include "common.namespace" . }}
  labels:
{{ include "common.labels" . | indent 4 }}
  {{- with .Values.serviceAccount.annotations }}
  annotations:
{{ toYaml . | indent 4 }}
  {{- end }}
{{- end -}}
{{- end -}}
{{- end -}}
