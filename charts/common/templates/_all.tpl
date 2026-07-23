{{/*
common.all — the single entry point a wrapper chart includes. Emits every enabled
resource. Each resource helper emits its own leading `---` document separator (and
renders nothing when disabled), so documents never glue together. Order mirrors the
kustomize resource ordering (secrets/config first, storage, controller, service,
ingress, monitoring) for readable diffs.
*/}}
{{- define "common.all" -}}
{{ include "common.externalsecrets" . }}
{{ include "common.configmaps" . }}
{{ include "common.pvcs" . }}
{{ include "common.serviceaccount" . }}
{{ include "common.controller" . }}
{{ include "common.service" . }}
{{ include "common.ingressroute" . }}
{{ include "common.servicemonitor" . }}
{{- end -}}
