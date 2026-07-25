{{/*
common.jobs — batch/v1 Jobs for mandatory, same-namespace one-shot workloads that
belong to the app (DB migrations, one-off maintenance). Rendered by the chart, NOT
dumped in post-install: only cross-namespace objects stay there now.

A job item's image DEFAULTS to the app image (.Values.image), so a migrate Job
tracks the deployment tag automatically — no more hardcoded "…:1.2.3" kept in
manual lockstep. Override per-job with `image: {repository, tag}` when the Job runs
a different image.

  jobs:
    - name: <app>-migrate           # FULL object name (like externalSecrets)
      component: <app>-migrate       # optional; app.kubernetes.io/component, default = name
      hook: PreSync                  # optional; argocd.argoproj.io/hook (+ delete-policy)
      hookDeletePolicy: BeforeHookCreation   # optional; default when hook set
      annotations: {}                # optional; extra metadata annotations (e.g. waivers)
      backoffLimit: 2                # optional; default 2
      ttlSecondsAfterFinished: 300   # optional; emitted only when set
      # --- pod body (shared with cronJobs via common.jobPodSpec) ---
      image: {repository: ..., tag: ...}   # optional; default = app image
      command: [...]
      args: [...]
      securityContext: {}            # container-level
      podSecurityContext: {}         # pod-level
      restartPolicy: Never           # optional; default Never
      resources: {}
      env: [] / envFrom: [] / envFromSecrets: [] / envFromConfigMap: <name>
      volumeMounts: [] / volumes: []
      serviceAccountName: <name>     # optional
      nodeSelector: {} / tolerations: []
*/}}
{{- define "common.jobs" -}}
{{- range $job := .Values.jobs }}
---
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ $job.name }}
  namespace: {{ include "common.namespace" $ }}
  labels:
    app: {{ include "common.name" $ }}
    app.kubernetes.io/name: {{ include "common.name" $ }}
    app.kubernetes.io/part-of: {{ include "common.name" $ }}
    app.kubernetes.io/instance: {{ include "common.name" $ }}
    app.kubernetes.io/component: {{ $job.component | default $job.name }}
  {{- if or $job.hook $job.annotations }}
  annotations:
    {{- if $job.hook }}
    argocd.argoproj.io/hook: {{ $job.hook }}
    argocd.argoproj.io/hook-delete-policy: {{ $job.hookDeletePolicy | default "BeforeHookCreation" }}
    {{- end }}
    {{- with $job.annotations }}
{{ toYaml . | indent 4 }}
    {{- end }}
  {{- end }}
spec:
  backoffLimit: {{ $job.backoffLimit | default 2 }}
  {{- if hasKey $job "ttlSecondsAfterFinished" }}
  ttlSecondsAfterFinished: {{ $job.ttlSecondsAfterFinished }}
  {{- end }}
  template:
    metadata:
      {{- /*
        Pod labels deliberately carry app.kubernetes.io/name (so name-based
        NetworkPolicies still grant the job pod its egress) but NOT `app`.
        The app Service selects on `app: <name>`, so a running job pod carrying
        `app` would be added as a Service endpoint and scraped on the metrics
        port it does not serve → a spurious TargetDown while the job runs.
      */}}
      labels:
        app.kubernetes.io/name: {{ include "common.name" $ }}
    spec:
{{ include "common.jobPodSpec" (dict "item" $job "root" $) | indent 6 }}
{{- end }}
{{- end -}}

{{/*
common.jobPodSpec — the pod-template body shared by Jobs and CronJobs. Takes a dict
{item: <job|cronjob spec>, root: $}. Mirrors common.podSpec but is driven by the
per-item map (each Job/CronJob carries its own image/command/env/security), not the
main workload's top-level .Values. No probes or anti-affinity — one-shot pods.
*/}}
{{- define "common.jobPodSpec" -}}
{{- $job := .item -}}
{{- $root := .root -}}
containers:
  - name: {{ $job.name }}
    {{- with $job.image }}
    image: "{{ .repository | default $root.Values.image.repository }}:{{ .tag | default $root.Values.image.tag }}"
    {{- else }}
    image: "{{ $root.Values.image.repository }}:{{ $root.Values.image.tag }}"
    {{- end }}
    imagePullPolicy: {{ $job.imagePullPolicy | default $root.Values.image.pullPolicy | default "IfNotPresent" }}
    {{- with $job.command }}
    command:
{{ toYaml . | indent 6 }}
    {{- end }}
    {{- with $job.args }}
    args:
{{ toYaml . | indent 6 }}
    {{- end }}
    {{- with $job.securityContext }}
    securityContext:
{{ toYaml . | indent 6 }}
    {{- end }}
    {{- if or $job.envFromConfigMap $job.envFromSecrets $job.envFrom }}
    envFrom:
      {{- if $job.envFromConfigMap }}
      - configMapRef:
          name: {{ $job.envFromConfigMap }}
      {{- end }}
      {{- range $job.envFromSecrets }}
      - secretRef:
          name: {{ . }}
      {{- end }}
      {{- with $job.envFrom }}
{{ toYaml . | indent 6 }}
      {{- end }}
    {{- end }}
    {{- with $job.env }}
    env:
{{ toYaml . | indent 6 }}
    {{- end }}
    {{- with $job.resources }}
    resources:
{{ toYaml . | indent 6 }}
    {{- end }}
    {{- with $job.volumeMounts }}
    volumeMounts:
{{ toYaml . | indent 6 }}
    {{- end }}
restartPolicy: {{ $job.restartPolicy | default "Never" }}
{{- if $job.serviceAccountName }}
serviceAccountName: {{ $job.serviceAccountName }}
{{- end }}
{{- with $job.volumes }}
volumes:
{{ toYaml . | indent 2 }}
{{- end }}
{{- with $job.podSecurityContext }}
securityContext:
{{ toYaml . | indent 2 }}
{{- end }}
{{- with $job.nodeSelector }}
nodeSelector:
{{ toYaml . | indent 2 }}
{{- end }}
{{- with $job.tolerations }}
tolerations:
{{ toYaml . | indent 2 }}
{{- end }}
{{- end -}}
