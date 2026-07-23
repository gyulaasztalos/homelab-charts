{{/*
common.ingressroute — renders a single Traefik IngressRoute whose `spec.routes`
is a LIST, so one workload can expose several routes (distinct hosts, or one
host per backing service) from ONE IngressRoute object.

  ingressRoute:
    enabled: true                        # optional; set false to skip entirely
    ingressClassName: traefik-external   # optional; default traefik-external
    entryPoint: websecure                # optional; default websecure
    tlsSecretName: example-com-tls       # optional; default example-com-tls
    routes:
      - host: <app>.example.com          # REQUIRED per route
        serviceName: <app>               # optional; defaults to the app name —
                                         # point at a specific Service when several exist
        port: 8000                       # REQUIRED per route
        priority: 10                     # optional; default 10
        middlewares:                     # optional; defaults to authentik +
          - {name: authentik, namespace: traefik}         # default-headers.
          - {name: default-headers, namespace: traefik}   # set [] to drop auth

The whole IngressRoute is skipped when `ingressRoute.enabled` is explicitly
false, or when `ingressRoute` (or its `routes`) is omitted — metrics-only apps
hit in-cluster simply leave it out.
*/}}
{{- define "common.ingressroute" -}}
{{- $ir := .Values.ingressRoute | default dict }}
{{- if and (ne ($ir.enabled | toString) "false") $ir.routes }}
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: {{ $ir.name | default (include "common.name" .) }}
  namespace: {{ include "common.namespace" . }}
  labels:
{{ include "common.labels" . | indent 4 }}
spec:
  ingressClassName: {{ $ir.ingressClassName | default "traefik-external" }}
  entryPoints:
    - {{ $ir.entryPoint | default "websecure" }}
  routes:
{{- $ns := include "common.namespace" . }}
{{- $appName := include "common.name" . }}
{{- range $route := $ir.routes }}
    - kind: Rule
      match: Host(`{{ required "ingressRoute.routes[].host is required" $route.host }}`)
      priority: {{ $route.priority | default 10 }}
      {{- $mw := $route.middlewares | default (list (dict "name" "authentik" "namespace" "traefik") (dict "name" "default-headers" "namespace" "traefik")) }}
      {{- with $mw }}
      middlewares:
{{ toYaml . | indent 8 }}
      {{- end }}
      services:
        - name: {{ $route.serviceName | default $appName }}
          namespace: {{ $ns }}
          port: {{ required "ingressRoute.routes[].port is required" $route.port }}
{{- end }}
  tls:
    secretName: {{ $ir.tlsSecretName | default "example-com-tls" }}
{{- end }}
{{- end -}}
