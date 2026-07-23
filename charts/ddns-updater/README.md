# ddns-updater

Cloudflare dynamic-DNS updater ([qmcgaw/ddns-updater](https://github.com/qdm12/ddns-updater)).
Rendered through the [`common`](../common) library chart.

## Controller

**StatefulSet.** ddns-updater owns a writable RWO data volume and cannot run more
than one replica, so per the homelab rule (*owns an RWO volume ⇒ StatefulSet*) it
uses a `volumeClaimTemplate` rather than a Deployment + static PVC. The data is
regenerable, so migration is a delete-and-recreate (no data move).

## Generic chart vs. deployment values

This chart's [`values.yaml`](values.yaml) holds **generic, shareable example
config** (`example.com` hostnames, sample 1Password refs) plus every default, so
it renders on its own and anyone can fork it. The **real deployment config** lives
in the GitOps repo (`apps/ddns-updater/values.yaml`) and is layered over this chart
by the ArgoCD Application via `helm.valueFiles`. Override at minimum:
`ingressRoute.routes[].host`, `ingressRoute.tlsSecretName`, the `externalSecrets`
domains/refs and `SHOUTRRR_ADDRESSES`.

## Values

All values below are set in [`values.yaml`](values.yaml) with their effective
defaults (generic example values). This table documents them.

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
| `services` | `[{name: ddns-updater, ClusterIP, webui 8000}]` | Service **list** — one workload can expose several; `enabled: false` skips one. |
| `ingressRoute.enabled` | `true` | Render the Traefik IngressRoute (set false to skip). |
| `ingressRoute.tlsSecretName` | `example-com-tls` | TLS secret (override in GitOps values). |
| `ingressRoute.routes` | 1 route → webui 8000 | `routes` **list** inside the single IngressRoute (host/serviceName/port/priority/middlewares per route). |
| `ingressRoute.routes[].host` | `ddns-updater.example.com` | Route host (override in GitOps values). |
| `ingressRoute.routes[].middlewares` | authentik + default-headers | Browser-path auth middlewares. |
| `serviceMonitor.enabled` | `false` | **See note** — believed to be a bug that this is off; tracked in the project backlog. |
| `persistentVolumeClaims` / `persistentVolumes` | `[]` | None (RWO handled by volumeClaimTemplates). |
| `extraLabels` | `{}` | Extra labels merged into the standard label block. |

## Secrets

The `ddns-updater-secret` ExternalSecret pulls the DNS-provider token and zone id
from a 1Password item via the `onepassword-connect` ClusterSecretStore and renders
them into `config.json`. The `{{ .cloudflare_* }}` placeholders in `values.yaml`
are the **ExternalSecret's own** templating (resolved by External Secrets Operator
at runtime), written raw because `values.yaml` / valueFiles are not Helm-processed.
No secret material is stored in either repo.

## Verify locally

```bash
helm dependency build charts/ddns-updater
helm lint charts/ddns-updater
# renders on generic defaults alone:
helm template ddns-updater charts/ddns-updater | kubeconform -strict -ignore-missing-schemas -skip IngressRoute
# migration equivalence against install/ — renders with the TAILORED GitOps values
# (auto-picked up from ../ArgoCD/apps/ddns-updater/values.yaml):
bash hack/diff-migration.sh ddns-updater
```
