{{/*
common.database — a CNPG (postgresql.cnpg.io/v1) Database on the shared cluster.
This is the app's MANDATORY data dependency, so it lives in the chart even though
it targets ANOTHER namespace (databases): the render carries an explicit
`namespace` (values-driven, default "databases"). Renders nothing when `database`
is unset/empty, so it is additive to every app that has no database.

Sensible defaults keep the common case (object <app>-db, db/owner = <app>) to a
few lines; the object/db/owner names are overridable for apps whose DB name
differs from the app name (e.g. paperless-ngx → paperless).

  database:
    name: <app>-db          # optional; metadata.name of the Database object
    namespace: databases     # optional; default databases
    cluster: postgres        # optional; spec.cluster.name, default postgres
    dbName: <app>            # optional; spec.name (the actual database)
    owner: <app>             # optional; spec.owner (the managed role)
    encoding: UTF8           # optional; omitted if unset (CNPG default otherwise)
    localeCType: C           # optional
    localeCollate: C         # optional
    template: template0      # optional
*/}}
{{- define "common.database" -}}
{{- with .Values.database }}
---
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: {{ .name | default (printf "%s-db" (include "common.name" $)) }}
  namespace: {{ .namespace | default "databases" }}
  labels:
{{ include "common.labels" $ | indent 4 }}
spec:
  name: {{ .dbName | default (include "common.name" $) }}
  owner: {{ .owner | default (include "common.name" $) }}
  cluster:
    name: {{ .cluster | default "postgres" }}
  {{- with .encoding }}
  encoding: {{ . }}
  {{- end }}
  {{- with .localeCType }}
  localeCType: {{ . }}
  {{- end }}
  {{- with .localeCollate }}
  localeCollate: {{ . }}
  {{- end }}
  {{- with .template }}
  template: {{ . }}
  {{- end }}
{{- end }}
{{- end -}}
