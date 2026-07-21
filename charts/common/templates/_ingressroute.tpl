{{/*
common.ingressroute — Traefik IngressRoute. Homelab defaults: websecure entrypoint,
authentik + default-headers middlewares (browser path), the local wildcard TLS
secret. Set ingress.enabled: false to skip; ingress.middlewares: [] to drop auth
(e.g. pure API/metrics endpoints hit in-cluster).
*/}}
{{- define "common.ingressroute" -}}
{{- if .Values.ingress.enabled -}}
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: {{ include "common.name" . }}
  namespace: {{ include "common.namespace" . }}
  labels:
{{ include "common.labels" . | indent 4 }}
spec:
  ingressClassName: {{ .Values.ingress.ingressClassName | default "traefik-external" }}
  entryPoints:
    - {{ .Values.ingress.entryPoint | default "websecure" }}
  routes:
    - kind: Rule
      match: Host(`{{ required "ingress.host is required when ingress.enabled" .Values.ingress.host }}`)
      priority: {{ .Values.ingress.priority | default 10 }}
      {{- $mw := .Values.ingress.middlewares | default (list (dict "name" "authentik" "namespace" "traefik") (dict "name" "default-headers" "namespace" "traefik")) }}
      {{- with $mw }}
      middlewares:
{{ toYaml . | indent 8 }}
      {{- end }}
      services:
        - name: {{ include "common.name" . }}
          namespace: {{ include "common.namespace" . }}
          port: {{ required "ingress.port is required when ingress.enabled" .Values.ingress.port }}
  tls:
    secretName: {{ .Values.ingress.tlsSecretName | default "local-asztalos-net-tls" }}
{{- end -}}
{{- end -}}
