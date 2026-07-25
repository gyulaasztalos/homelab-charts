{{/*
common.cronjobs — batch/v1 CronJobs for the app's scheduled maintenance
(price-sync, GDPR purge). Same-namespace, mandatory app parts → rendered by the
chart. The jobTemplate pod body is the SAME helper Jobs use (common.jobPodSpec), so
image defaulting to the app image and the env/security passthrough are identical.

  cronJobs:
    - name: <app>-purge             # FULL object name
      component: <app>-purge         # optional; default = name
      schedule: "20 3 * * *"         # required
      timeZone: Europe/Budapest      # optional
      concurrencyPolicy: Forbid      # optional; default Forbid
      startingDeadlineSeconds: 3600  # optional; emitted only when set
      successfulJobsHistoryLimit: 3  # optional; default 3
      failedJobsHistoryLimit: 1      # optional; default 1
      annotations: {}                # optional; on the CronJob (e.g. ttl waiver)
      # --- jobTemplate ---
      backoffLimit: 1                # optional; default 1
      ttlSecondsAfterFinished: 86400 # optional; emitted only when set
      # --- pod body (see common.jobs for the full pod field list) ---
      command: [...]
      env: [] / envFromSecrets: [] / ...
*/}}
{{- define "common.cronjobs" -}}
{{- range $cj := .Values.cronJobs }}
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: {{ $cj.name }}
  namespace: {{ include "common.namespace" $ }}
  labels:
    app: {{ include "common.name" $ }}
    app.kubernetes.io/name: {{ include "common.name" $ }}
    app.kubernetes.io/part-of: {{ include "common.name" $ }}
    app.kubernetes.io/instance: {{ include "common.name" $ }}
    app.kubernetes.io/component: {{ $cj.component | default $cj.name }}
  {{- with $cj.annotations }}
  annotations:
{{ toYaml . | indent 4 }}
  {{- end }}
spec:
  schedule: {{ $cj.schedule | quote }}
  {{- with $cj.timeZone }}
  timeZone: {{ . | quote }}
  {{- end }}
  concurrencyPolicy: {{ $cj.concurrencyPolicy | default "Forbid" }}
  {{- if hasKey $cj "startingDeadlineSeconds" }}
  startingDeadlineSeconds: {{ $cj.startingDeadlineSeconds }}
  {{- end }}
  successfulJobsHistoryLimit: {{ $cj.successfulJobsHistoryLimit | default 3 }}
  failedJobsHistoryLimit: {{ $cj.failedJobsHistoryLimit | default 1 }}
  jobTemplate:
    spec:
      backoffLimit: {{ $cj.backoffLimit | default 1 }}
      {{- if hasKey $cj "ttlSecondsAfterFinished" }}
      ttlSecondsAfterFinished: {{ $cj.ttlSecondsAfterFinished }}
      {{- end }}
      template:
        metadata:
          {{- /* app.kubernetes.io/name only, NOT `app` — see common.jobs. */}}
          labels:
            app.kubernetes.io/name: {{ include "common.name" $ }}
        spec:
{{ include "common.jobPodSpec" (dict "item" $cj "root" $) | indent 10 }}
{{- end }}
{{- end -}}
