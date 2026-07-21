{{/*
common.externalsecrets — External Secrets Operator ExternalSecret objects that
pull from the in-cluster onepassword-connect ClusterSecretStore.
NO secret material lives here — only references and (optional) rendering templates.

  externalSecrets:
    - name: <app>-secret
      refreshInterval: 1h                 # optional, default 1h
      target:                             # optional; template block passed through verbatim
        template:
          engineVersion: v2
          type: Opaque
          data:
            KEY: "{{`{{ .someRef }}`}}"
      data:
        - secretKey: someRef
          remoteRef:
            key: <1password-item>
            property: <field>
*/}}
{{- define "common.externalsecrets" -}}
{{- range $es := .Values.externalSecrets }}
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: {{ $es.name }}
  namespace: {{ include "common.namespace" $ }}
  labels:
{{ include "common.labels" $ | indent 4 }}
spec:
  refreshInterval: {{ $es.refreshInterval | default "1h" }}
  secretStoreRef:
    name: {{ $es.secretStoreRef | default "onepassword-connect" }}
    kind: {{ $es.secretStoreKind | default "ClusterSecretStore" }}
  target:
    name: {{ $es.targetName | default $es.name }}
    creationPolicy: {{ $es.creationPolicy | default "Owner" }}
    {{- with $es.target }}
    {{- with .template }}
    template:
{{ toYaml . | indent 6 }}
    {{- end }}
    {{- end }}
  data:
{{ toYaml $es.data | indent 4 }}
{{- end }}
{{- end -}}
