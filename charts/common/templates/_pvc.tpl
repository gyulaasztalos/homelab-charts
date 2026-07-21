{{/*
common.pvcs — static PersistentVolumeClaims (and optional static PVs, e.g. NFS
shares). For RWO volumes owned by a StatefulSet, prefer volumeClaimTemplates on the
controller instead of a static PVC here.

  persistentVolumes: [ {full PV spec incl. metadata.name} ]   # rarely needed (NFS)
  persistentVolumeClaims:
    - name: <app>-data
      accessModes: ["ReadWriteOnce"]
      storageClassName: longhorn
      size: 1Gi
*/}}
{{- define "common.pvcs" -}}
{{- range .Values.persistentVolumes }}
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: {{ .name }}
spec:
{{ toYaml .spec | indent 2 }}
{{- end }}
{{- range $pvc := .Values.persistentVolumeClaims }}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ $pvc.name }}
  namespace: {{ include "common.namespace" $ }}
  labels:
{{ include "common.labels" $ | indent 4 }}
spec:
  accessModes:
{{ toYaml ($pvc.accessModes | default (list "ReadWriteOnce")) | indent 4 }}
  storageClassName: {{ $pvc.storageClassName | default "longhorn" }}
  resources:
    requests:
      storage: {{ required "persistentVolumeClaims[].size is required" $pvc.size }}
{{- end }}
{{- end -}}
