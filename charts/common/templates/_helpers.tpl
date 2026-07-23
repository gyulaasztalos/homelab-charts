{{/*
Common helpers: naming, labels, selector labels.
The app name comes from values (.Values.name) falling back to the chart name so a
wrapper chart usually needs to set nothing.
*/}}

{{- define "common.name" -}}
{{- default .Chart.Name .Values.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "common.namespace" -}}
{{- default (include "common.name" .) .Values.namespace -}}
{{- end -}}

{{/*
Standard label block — matches the existing kustomize convention exactly:
app + the four app.kubernetes.io/* labels all set to the app name.
*/}}
{{- define "common.labels" -}}
app: {{ include "common.name" . }}
app.kubernetes.io/name: {{ include "common.name" . }}
app.kubernetes.io/part-of: {{ include "common.name" . }}
app.kubernetes.io/instance: {{ include "common.name" . }}
app.kubernetes.io/component: {{ include "common.name" . }}
{{- with .Values.extraLabels }}
{{ toYaml . }}
{{- end -}}
{{- end -}}

{{/*
Selector labels — the stable subset used by Deployment/StatefulSet/DaemonSet
selectors and the Service. Existing manifests select on app.kubernetes.io/name;
Service selects on `app`. We keep both stable so both continue to work.
*/}}
{{- define "common.selectorLabels" -}}
app.kubernetes.io/name: {{ include "common.name" . }}
{{- end -}}

{{- define "common.serviceSelector" -}}
app: {{ include "common.name" . }}
{{- end -}}

{{/*
common.controllerSelector — the matchLabels used by the controller's
spec.selector. Defaults to common.selectorLabels. Can be overridden per app via
.Values.controller.selectorLabels — needed when migrating an existing controller
whose selector is immutable (e.g. a DaemonSet that stays a DaemonSet): reproduce
the original selector exactly so the in-place apply doesn't hit an immutable-field
error. The pod template always carries the full common.labels set, so any subset
selector remains satisfied.
*/}}
{{- define "common.controllerSelector" -}}
{{- with .Values.controller.selectorLabels -}}
{{ toYaml . }}
{{- else -}}
{{ include "common.selectorLabels" . }}
{{- end -}}
{{- end -}}
