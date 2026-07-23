{{/*
common.ingressroute — renders a single Traefik IngressRoute whose `spec.routes`
is a LIST, so one workload can expose several routes (distinct hosts, distinct
path prefixes, or one host per backing service) from ONE IngressRoute object.

  ingressRoute:
    enabled: true                        # optional; set false to skip entirely
    ingressClassName: traefik-external   # optional; default traefik-external
    entryPoint: websecure                # optional; default websecure
    tlsSecretName: example-com-tls       # optional; default example-com-tls
    routes:
      - host: <app>.example.com          # REQUIRED per route
        pathPrefix: /api                 # optional; when set the match becomes
                                         # Host(`…`) && PathPrefix(`/api`)
        serviceName: <app>               # optional; defaults to the app name —
                                         # point at a specific Service when several exist
        port: 8000                       # REQUIRED per route
        priority: 10                     # optional; default 10
        middlewares:                     # OMIT the key entirely to get the
          - {name: authentik, namespace: traefik}        # default pair below;
          - {name: default-headers, namespace: traefik}  # set [] for NO auth.

Several routes on one host are disambiguated by `priority` — Traefik evaluates
higher priorities first, so a machine-facing `pathPrefix` route must outrank the
catch-all host route that carries authentik.

The whole IngressRoute is skipped when `ingressRoute.enabled` is explicitly
false, or when `ingressRoute` (or its `routes`) is omitted — metrics-only apps
hit in-cluster simply leave it out.

MIDDLEWARE DEFAULTING — the list-shaped sibling of the `false | default true`
trap. Helm's `default` treats an EMPTY LIST as empty, so
`$route.middlewares | default (list …)` returned the authentik pair for
`middlewares: []` just as it did for an absent key. The documented "set [] to
drop auth" therefore silently did the opposite, wrapping a machine-facing API in
forward-auth. `hasKey` is what actually distinguishes "absent" from "explicitly
empty"; `hack/test-toggles.sh` asserts both directions.
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
{{- $defaultMw := list (dict "name" "authentik" "namespace" "traefik") (dict "name" "default-headers" "namespace" "traefik") }}
{{- range $route := $ir.routes }}
    - kind: Rule
      {{- $match := printf "Host(`%s`)" (required "ingressRoute.routes[].host is required" $route.host) }}
      {{- with $route.pathPrefix }}
      {{- $match = printf "%s && PathPrefix(`%s`)" $match . }}
      {{- end }}
      match: {{ $match }}
      priority: {{ $route.priority | default 10 }}
      {{- $mw := $defaultMw }}
      {{- if hasKey $route "middlewares" }}
      {{- $mw = $route.middlewares }}
      {{- end }}
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
