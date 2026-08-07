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


{{/*
common.assertNoRwoSurge — render-time guard against a silent rollout deadlock.

A Deployment whose pod mounts a ReadWriteOnce PVC cannot roll with maxSurge > 0:
the replacement pod is scheduled BEFORE the old one terminates, it tries to mount
a volume the outgoing pod still holds, and — because RWO means exactly one node —
it blocks forever. The rollout does not fail, it HANGS, until someone deletes the
old pod by hand. Nothing in the manifest hints that this will happen.

This is latent rather than live: every persistent app in this repo is currently a
StatefulSet, which terminates before creating and so is immune. The trap only
arms the day someone adds persistentVolumeClaims to a Deployment-based app, which
is exactly when a loud failure is cheapest.

Deliberately a hard `fail` rather than silently switching to Recreate: swapping
the strategy behind the author's back means the app quietly gains downtime on
every rollout, which is a real trade-off that belongs to whoever owns the app.
The message names both escapes.

Fires only when ALL of: controller.type is deployment, an RWO PVC is declared,
and the effective strategy is RollingUpdate with a non-zero maxSurge.
*/}}
{{- define "common.assertNoRwoSurge" -}}
{{- $ctx := .ctx -}}
{{- $strategy := .strategy -}}
{{- if eq ($strategy.type | default "RollingUpdate") "RollingUpdate" -}}
{{- $surge := toString (dig "rollingUpdate" "maxSurge" 1 $strategy) -}}
{{- if and (ne $surge "0") (ne $surge "0%") -}}
{{- range $pvc := $ctx.Values.persistentVolumeClaims -}}
{{- if has "ReadWriteOnce" ($pvc.accessModes | default (list "ReadWriteOnce")) -}}
{{- fail (printf "\n\n  %s: Deployment mounts the ReadWriteOnce PVC %q but uses RollingUpdate with maxSurge=%s.\n  The new pod would be created before the old one releases the volume and the rollout would HANG (not fail) forever.\n  Pick one:\n    controller.strategy: {type: Recreate}                                  # brief downtime, correct for single-writer state\n    controller.strategy: {type: RollingUpdate, rollingUpdate: {maxSurge: 0, maxUnavailable: 1}}\n    controller.type: statefulset                                           # preferred for RWO state\n"
  (include "common.name" $ctx) $pvc.name $surge) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}


{{- define "common.deployment" -}}
{{- $strategy := .Values.controller.strategy | default (dict "type" "RollingUpdate" "rollingUpdate" (dict "maxSurge" 1 "maxUnavailable" 1)) -}}
{{- include "common.assertNoRwoSurge" (dict "ctx" . "strategy" $strategy) -}}
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
{{ toYaml $strategy | indent 4 }}
  selector:
    matchLabels:
{{ include "common.controllerSelector" . | indent 6 }}
  template:
{{ include "common.podTemplateMeta" . | indent 4 }}
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
{{ include "common.controllerSelector" . | indent 6 }}
  template:
{{ include "common.podTemplateMeta" . | indent 4 }}
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
{{ include "common.controllerSelector" . | indent 6 }}
  template:
{{ include "common.podTemplateMeta" . | indent 4 }}
    spec:
{{ include "common.podSpec" . | indent 6 }}
{{- end -}}
