{{/*
common.servicemonitor — Prometheus Operator ServiceMonitor. Optional
(serviceMonitor.enabled). Selects the app's own service by app.kubernetes.io/name.
*/}}
{{- define "common.servicemonitor" -}}
{{- if .Values.serviceMonitor.enabled -}}
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: {{ include "common.name" . }}
  namespace: {{ include "common.namespace" . }}
  labels:
{{ include "common.labels" . | indent 4 }}
{{- with .Values.serviceMonitor.labels }}
{{ toYaml . | indent 4 }}
{{- end }}
spec:
  selector:
    matchLabels:
{{ include "common.selectorLabels" . | indent 6 }}
  namespaceSelector:
    matchNames:
      - {{ include "common.namespace" . }}
  endpoints:
{{ toYaml .Values.serviceMonitor.endpoints | indent 4 }}
{{- end -}}
{{- end -}}
