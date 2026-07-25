{{/*
common.middlewares — Traefik (traefik.io/v1alpha1) Middleware objects owned by the
app. These pair with the IngressRoute common already renders (and references): an
app's per-route middleware (e.g. its security-headers) is the other half of the
same "edge" concern, so it lives with the route, not in a separate post-install
source (which would let the route sync before the middleware it references exists).

Cross-namespace like the CNPG database: the Middleware targets the ingress
namespace, so the render carries an explicit `namespace` (values-driven, default
"traefik"). The whole `spec` is passed through verbatim, so this handles any
middleware type (headers, forwardAuth, stripPrefix, …), not just headers. Renders
nothing when `middlewares` is unset.

  middlewares:
    - name: <app>-headers
      namespace: traefik        # optional; default traefik
      spec:                      # verbatim Traefik Middleware spec
        headers:
          browserXssFilter: true
          ...
*/}}
{{- define "common.middlewares" -}}
{{- range $mw := .Values.middlewares }}
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: {{ $mw.name }}
  namespace: {{ $mw.namespace | default "traefik" }}
  labels:
{{ include "common.labels" $ | indent 4 }}
spec:
{{ toYaml $mw.spec | indent 2 }}
{{- end }}
{{- end -}}
