{{/*
common.configChecksum — sha256 of the rendered ConfigMaps, used as a pod-template
annotation so pods auto-roll when their config changes (the Helm-idiomatic
equivalent of kustomize's configMapGenerator hash suffix). ExternalSecrets are
intentionally excluded: their manifest is only a reference, and the real secret
value (rotated in 1Password) doesn't change the manifest — matching the old
kustomize behavior, which only hashed generated ConfigMaps/Secrets.
*/}}
{{- define "common.configChecksum" -}}
{{- include "common.configmaps" . | sha256sum -}}
{{- end -}}

{{/*
common.podTemplateMeta — the shared `spec.template.metadata` block (labels +
optional annotations). Used by all three controllers so the metadata stays
identical. The `checksum/config` annotation is emitted ONLY when the chart owns
ConfigMaps (so config changes roll the pods); apps with no ConfigMaps get no
spurious annotation. The annotations block itself is omitted entirely when there
is nothing to put in it.
*/}}
{{- define "common.podTemplateMeta" -}}
metadata:
  labels:
{{ include "common.labels" . | indent 4 }}
{{- if or .Values.configMaps .Values.podAnnotations }}
  annotations:
{{- if .Values.configMaps }}
    checksum/config: {{ include "common.configChecksum" . | quote }}
{{- end }}
{{- with .Values.podAnnotations }}
{{ toYaml . | indent 4 }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
common.podSpec — the shared pod template body (spec.template.spec content).
Included by the deployment/statefulset/daemonset controllers. Encodes the homelab
defaults: standard securityContext, pod anti-affinity, RuntimeDefault seccomp.
Everything is values-driven with sensible defaults so simple apps stay terse.
*/}}
{{- define "common.podSpec" -}}
{{- $top := . -}}
{{- with .Values.initContainers }}
initContainers:
{{ toYaml . | indent 2 }}
{{- end }}
containers:
  - name: {{ include "common.name" . }}
    image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
    imagePullPolicy: {{ .Values.image.pullPolicy | default "IfNotPresent" }}
    {{- with .Values.securityContext }}
    securityContext:
{{ toYaml . | indent 6 }}
    {{- end }}
    {{- with .Values.command }}
    command:
{{ toYaml . | indent 6 }}
    {{- end }}
    {{- with .Values.args }}
    args:
{{ toYaml . | indent 6 }}
    {{- end }}
    {{- with .Values.ports }}
    ports:
{{ toYaml . | indent 6 }}
    {{- end }}
    {{- if or .Values.envFromConfigMap .Values.envFromSecrets .Values.envFrom }}
    envFrom:
      {{- if .Values.envFromConfigMap }}
      - configMapRef:
          name: {{ .Values.envFromConfigMap }}
      {{- end }}
      {{- range .Values.envFromSecrets }}
      - secretRef:
          name: {{ . }}
      {{- end }}
      {{- with .Values.envFrom }}
{{ toYaml . | indent 6 }}
      {{- end }}
    {{- end }}
    {{- with .Values.env }}
    env:
{{ toYaml . | indent 6 }}
    {{- end }}
    {{- with .Values.resources }}
    resources:
{{ toYaml . | indent 6 }}
    {{- end }}
    {{- with .Values.readinessProbe }}
    readinessProbe:
{{ toYaml . | indent 6 }}
    {{- end }}
    {{- with .Values.livenessProbe }}
    livenessProbe:
{{ toYaml . | indent 6 }}
    {{- end }}
    {{- with .Values.volumeMounts }}
    volumeMounts:
{{ toYaml . | indent 6 }}
    {{- end }}
restartPolicy: {{ .Values.restartPolicy | default "Always" }}
{{- if .Values.serviceAccountName }}
serviceAccountName: {{ .Values.serviceAccountName }}
{{- end }}
{{- if .Values.hostNetwork }}
hostNetwork: {{ .Values.hostNetwork }}
{{- end }}
{{- with .Values.volumes }}
volumes:
{{ toYaml . | indent 2 }}
{{- end }}
{{- with .Values.podSecurityContext }}
securityContext:
{{ toYaml . | indent 2 }}
{{- end }}
{{- if ne (.Values.podAntiAffinity | toString) "false" }}
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchExpressions:
            - key: app
              operator: In
              values:
                - {{ include "common.name" $top }}
        topologyKey: kubernetes.io/hostname
{{- end }}
{{- with .Values.nodeSelector }}
nodeSelector:
{{ toYaml . | indent 2 }}
{{- end }}
{{- with .Values.tolerations }}
tolerations:
{{ toYaml . | indent 2 }}
{{- end }}
{{- end -}}
