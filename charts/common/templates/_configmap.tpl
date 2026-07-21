{{/*
common.configmaps — ConfigMaps replacing kustomize configMapGenerator.
Supports env-style key/values and whole-file entries.

  configMaps:
    - name: <app>-config
      data:                       # rendered as-is
        KEY: value
      files:                      # file-name: file-contents (use .Files.Get in wrapper)
        notification.sh: |
          #!/bin/sh
*/}}
{{- define "common.configmaps" -}}
{{- range $cm := .Values.configMaps }}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ $cm.name }}
  namespace: {{ include "common.namespace" $ }}
  labels:
{{ include "common.labels" $ | indent 4 }}
data:
{{- with $cm.data }}
{{ toYaml . | indent 2 }}
{{- end }}
{{- with $cm.files }}
{{- range $k, $v := . }}
  {{ $k }}: |
{{ $v | indent 4 }}
{{- end }}
{{- end }}
{{- end }}
{{- end -}}
