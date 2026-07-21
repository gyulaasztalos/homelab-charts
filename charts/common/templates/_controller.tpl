{{/*
common.controller — renders one of Deployment / StatefulSet / DaemonSet based on
.Values.controller.type. Shares the pod body via common.podSpec.

  controller.type: deployment | statefulset | daemonset   (default: deployment)
*/}}
{{- define "common.controller" -}}
{{- $type := .Values.controller.type | default "deployment" -}}
---
{{ if eq $type "deployment" -}}
{{ include "common.deployment" . }}
{{- else if eq $type "statefulset" -}}
{{ include "common.statefulset" . }}
{{- else if eq $type "daemonset" -}}
{{ include "common.daemonset" . }}
{{- else -}}
{{ fail (printf "controller.type must be deployment|statefulset|daemonset, got %q" $type) }}
{{- end -}}
{{- end -}}


{{- define "common.deployment" -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "common.name" . }}
  namespace: {{ include "common.namespace" . }}
  labels:
{{ include "common.labels" . | indent 4 }}
  {{- with .Values.controller.annotations }}
  annotations:
{{ toYaml . | indent 4 }}
  {{- end }}
spec:
  replicas: {{ .Values.controller.replicas | default 1 }}
  progressDeadlineSeconds: {{ .Values.controller.progressDeadlineSeconds | default 600 }}
  revisionHistoryLimit: {{ .Values.controller.revisionHistoryLimit | default 2 }}
  strategy:
{{ toYaml (.Values.controller.strategy | default (dict "type" "RollingUpdate" "rollingUpdate" (dict "maxSurge" 1 "maxUnavailable" 1))) | indent 4 }}
  selector:
    matchLabels:
{{ include "common.selectorLabels" . | indent 6 }}
  template:
    metadata:
      labels:
{{ include "common.labels" . | indent 8 }}
    spec:
{{ include "common.podSpec" . | indent 6 }}
{{- end -}}


{{- define "common.statefulset" -}}
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: {{ include "common.name" . }}
  namespace: {{ include "common.namespace" . }}
  labels:
{{ include "common.labels" . | indent 4 }}
  {{- with .Values.controller.annotations }}
  annotations:
{{ toYaml . | indent 4 }}
  {{- end }}
spec:
  serviceName: {{ include "common.name" . }}
  replicas: {{ .Values.controller.replicas | default 1 }}
  revisionHistoryLimit: {{ .Values.controller.revisionHistoryLimit | default 2 }}
  {{- with .Values.controller.updateStrategy }}
  updateStrategy:
{{ toYaml . | indent 4 }}
  {{- end }}
  selector:
    matchLabels:
{{ include "common.selectorLabels" . | indent 6 }}
  template:
    metadata:
      labels:
{{ include "common.labels" . | indent 8 }}
    spec:
{{ include "common.podSpec" . | indent 6 }}
  {{- with .Values.volumeClaimTemplates }}
  volumeClaimTemplates:
{{ toYaml . | indent 4 }}
  {{- end }}
{{- end -}}


{{- define "common.daemonset" -}}
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: {{ include "common.name" . }}
  namespace: {{ include "common.namespace" . }}
  labels:
{{ include "common.labels" . | indent 4 }}
  {{- with .Values.controller.annotations }}
  annotations:
{{ toYaml . | indent 4 }}
  {{- end }}
spec:
  revisionHistoryLimit: {{ .Values.controller.revisionHistoryLimit | default 2 }}
  {{- with .Values.controller.updateStrategy }}
  updateStrategy:
{{ toYaml . | indent 4 }}
  {{- end }}
  selector:
    matchLabels:
{{ include "common.selectorLabels" . | indent 6 }}
  template:
    metadata:
      labels:
{{ include "common.labels" . | indent 8 }}
    spec:
{{ include "common.podSpec" . | indent 6 }}
{{- end -}}
