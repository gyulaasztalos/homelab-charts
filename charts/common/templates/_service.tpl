{{/*
common.service — ClusterIP service. Selects on `app` label (matches existing
manifests). Ports come from .Values.service.ports.
*/}}
{{- define "common.service" -}}
{{- if .Values.service.enabled | default true -}}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ include "common.name" . }}
  namespace: {{ include "common.namespace" . }}
  labels:
{{ include "common.labels" . | indent 4 }}
spec:
  type: {{ .Values.service.type | default "ClusterIP" }}
  selector:
{{ include "common.serviceSelector" . | indent 4 }}
  ports:
{{ toYaml .Values.service.ports | indent 4 }}
{{- end -}}
{{- end -}}
