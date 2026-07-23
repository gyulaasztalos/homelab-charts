{{/*
common.serviceaccount — optional ServiceAccount for the workload, plus an
optional long-lived ServiceAccount **token Secret**.

  serviceAccount:
    create: true
    name: <app>                 # optional; defaults to the app name
    annotations: {...}          # optional
    secrets:                    # optional; the SA's own `secrets:` back-reference
      - name: <app>
    tokenSecret:
      create: true              # optional; default false
      name: <app>               # optional; defaults to serviceAccount.name

The pod references the SA via .Values.serviceAccountName (see common.podSpec).

Why tokenSecret exists: since Kubernetes 1.24 a ServiceAccount no longer gets an
auto-generated token Secret. An app that needs a LONG-LIVED API token (rather
than the short-lived projected volume token) must declare one explicitly: a
Secret of type kubernetes.io/service-account-token carrying the
`kubernetes.io/service-account.name` annotation, which kube-controller-manager
then populates in-cluster. homepage's `kubernetes` widget (mode: cluster) is the
case this was added for.

NOTE: this template deliberately has NO `data` / `stringData` field. It can only
ever emit an EMPTY token holder that Kubernetes fills in at runtime, so it cannot
be used to smuggle secret material into the repo.
*/}}
{{- define "common.serviceaccount" -}}
{{- $sa := .Values.serviceAccount | default dict -}}
{{- $saName := $sa.name | default (include "common.name" .) -}}
{{- if $sa.create -}}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ $saName }}
  namespace: {{ include "common.namespace" . }}
  labels:
{{ include "common.labels" . | indent 4 }}
  {{- with $sa.annotations }}
  annotations:
{{ toYaml . | indent 4 }}
  {{- end }}
{{- with $sa.secrets }}
secrets:
{{ toYaml . | indent 2 }}
{{- end }}
{{- end }}
{{- $ts := $sa.tokenSecret | default dict -}}
{{- if $ts.create }}
---
apiVersion: v1
kind: Secret
type: kubernetes.io/service-account-token
metadata:
  name: {{ $ts.name | default $saName }}
  namespace: {{ include "common.namespace" . }}
  labels:
{{ include "common.labels" . | indent 4 }}
  annotations:
    kubernetes.io/service-account.name: {{ $saName }}
{{- end }}
{{- end -}}
