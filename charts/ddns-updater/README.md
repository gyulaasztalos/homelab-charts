# ddns-updater

Cloudflare dynamic-DNS updater ([qmcgaw/ddns-updater](https://github.com/qdm12/ddns-updater))
for the homelab. Rendered through the [`common`](../common) library chart.

## Controller

**StatefulSet.** ddns-updater owns a writable RWO data volume and cannot run more
than one replica, so per the homelab rule (*owns an RWO volume ⇒ StatefulSet*) it
uses a `volumeClaimTemplate` rather than a Deployment + static PVC. The data is
regenerable, so migration is a delete-and-recreate (no data move).

## Values

All values below are set in [`values.yaml`](values.yaml) with their effective
defaults. This table documents them.

| Key | Default | Description |
|-----|---------|-------------|
| `name` | `ddns-updater` | App name — drives resource names, labels, namespace. |
| `namespace` | `ddns-updater` | Target namespace. |
| `image.repository` | `qmcgaw/ddns-updater` | Container image. |
| `image.tag` | `v2.10.0` | Image tag — **single source of truth for app version**; bumped by Renovate. |
| `image.pullPolicy` | `IfNotPresent` | Image pull policy. |
| `controller.type` | `statefulset` | `deployment` \| `statefulset` \| `daemonset`. |
| `controller.replicas` | `1` | Replica count (keep 1 — single writer). |
| `controller.revisionHistoryLimit` | `2` | Retained controller revisions. |
| `controller.updateStrategy` | `{type: RollingUpdate}` | StatefulSet update strategy. |
| `volumeClaimTemplates` | `data` / 1Mi / longhorn / RWO | Per-replica RWO volume (→ `data-ddns-updater-0`). |
| `podSecurityContext` | non-root, fsGroup/runAs 1000, RuntimeDefault | Pod-level security context. |
| `securityContext` | RO rootfs, no privesc | Container-level security context. |
| `podAntiAffinity` | `true` | One replica per node. |
| `ports` | webui 8000, health 9999 | Container ports. |
| `envFromConfigMap` | `ddns-updater-env` | ConfigMap providing env vars. |
| `envFromSecrets` | `[]` | Secrets loaded via `envFrom`. |
| `env` | `[]` | Individual env vars. |
| `configMaps` | `ddns-updater-env` (all app settings) | Generated ConfigMap(s). |
| `externalSecrets` | `ddns-updater-secret` | ExternalSecret refs (1Password Connect); renders `config.json`. **No secret material in-repo.** |
| `resources` | 32–64Mi / 50–100m | Requests/limits. |
| `readinessProbe` / `livenessProbe` | httpGet `/` :9999 | Health checks against the health server. |
| `volumeMounts` | secret→config.json, data→/updater/data | Container mounts. |
| `volumes` | `ddns-updater-secret` (secret) | Non-PVC volumes (the `data` PVC comes from the volumeClaimTemplate). |
| `initContainers` | `[]` | None. |
| `service.enabled` | `true` | Render the Service. |
| `service.type` | `ClusterIP` | Service type. |
| `service.ports` | webui 8000 | Service ports. |
| `ingress.enabled` | `true` | Render the Traefik IngressRoute. |
| `ingress.host` | `ddns-updater.local.asztalos.net` | Route host. |
| `ingress.port` | `8000` | Backend port. |
| `ingress.middlewares` | authentik + default-headers | Browser-path auth middlewares. |
| `ingress.tlsSecretName` | `local-asztalos-net-tls` | TLS secret. |
| `serviceMonitor.enabled` | `false` | **See note** — believed to be a bug that this is off; tracked in the project backlog. |
| `persistentVolumeClaims` / `persistentVolumes` | `[]` | None (RWO handled by volumeClaimTemplates). |
| `extraLabels` | `{}` | Extra labels merged into the standard label block. |

## Secrets

The `ddns-updater-secret` ExternalSecret pulls the Cloudflare token and zone id
from the `cloudflare-token-secret` 1Password item via the `onepassword-connect`
ClusterSecretStore and renders them into `config.json`. The `{{ .cloudflare_* }}`
placeholders in `values.yaml` are the **ExternalSecret's own** templating (resolved
by External Secrets Operator at runtime), written raw because `values.yaml` is not
Helm-processed.

## Verify locally

```bash
helm dependency build charts/ddns-updater
helm lint charts/ddns-updater
helm template ddns-updater charts/ddns-updater | kubeconform -strict -ignore-missing-schemas -skip IngressRoute
# migration equivalence (while apps/ddns-updater/install still exists):
bash hack/diff-migration.sh ddns-updater
```
