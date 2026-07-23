{{/*
common.service — renders the app's Service(s) from a `services:` LIST, so one
workload can expose several Services (e.g. a regular ClusterIP plus a headless
service, or web + metrics on different specs). Each list item:

  services:
    - name: <app>              # optional; defaults to the app name
      enabled: true            # optional; set false to skip this one
      type: ClusterIP          # optional; default ClusterIP
      clusterIP: None          # optional; e.g. for a headless service
      selector: {...}          # optional; defaults to common.serviceSelector (app=<name>)
      labels: {...}            # optional; merged into the standard label block
      annotations: {...}       # optional
      ports: [...]

A service is skipped when its own `enabled` is explicitly false.
*/}}
{{- define "common.service" -}}
{{- range $svc := .Values.services }}
{{- if ne ($svc.enabled | toString) "false" }}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ $svc.name | default (include "common.name" $) }}
  namespace: {{ include "common.namespace" $ }}
  labels:
{{ include "common.labels" $ | indent 4 }}
  {{- with $svc.labels }}
{{ toYaml . | indent 4 }}
  {{- end }}
  {{- with $svc.annotations }}
  annotations:
{{ toYaml . | indent 4 }}
  {{- end }}
spec:
  type: {{ $svc.type | default "ClusterIP" }}
  {{- with $svc.clusterIP }}
  clusterIP: {{ . }}
  {{- end }}
  selector:
  {{- with $svc.selector }}
{{ toYaml . | indent 4 }}
  {{- else }}
{{ include "common.serviceSelector" $ | indent 4 }}
  {{- end }}
  ports:
{{ toYaml $svc.ports | indent 4 }}
{{- end }}
{{- end }}
{{- end -}}
