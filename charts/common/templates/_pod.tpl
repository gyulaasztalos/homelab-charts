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
{{- with .Values.volumes }}
volumes:
{{ toYaml . | indent 2 }}
{{- end }}
{{- with .Values.podSecurityContext }}
securityContext:
{{ toYaml . | indent 2 }}
{{- end }}
{{- if .Values.podAntiAffinity | default true }}
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
