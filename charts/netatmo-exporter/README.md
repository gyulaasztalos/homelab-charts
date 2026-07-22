# netatmo-exporter

Netatmo weather-station Prometheus exporter
([xperimental/netatmo-exporter](https://github.com/xperimental/netatmo-exporter))
for the homelab. Rendered through the [`common`](../common) library chart.

## Controller

**StatefulSet.** The exporter owns a writable RWO `config` volume that caches the
OAuth token, so per the homelab rule (*owns an RWO volume ⇒ StatefulSet*) it uses a
`volumeClaimTemplate`. The cached token is regenerable — an init container re-seeds
it from the ExternalSecret on first start — so migration is delete-and-recreate.

## Notes

- **ServiceMonitor is enabled** — this exporter is scraped (`/metrics` on :9210).
- **Init container** `add-netatmo-token` copies the initial token file from the
  secret into the config volume (idempotent; skips if already present).
- **Grafana dashboard is NOT in this chart.** The original `install/` inlined a
  3.8k-line dashboard ConfigMap; per the project convention it relocates to
  `apps/netatmo-exporter/post-install/` in the ArgoCD repo and is synced as a
  separate Application source. See `PLAN.md`.

## Values

All values are set in [`values.yaml`](values.yaml) with their effective defaults.

| Key | Default | Description |
|-----|---------|-------------|
| `name` / `namespace` | `netatmo-exporter` | App name → resource names, labels, namespace. |
| `image.repository` | `ghcr.io/xperimental/netatmo-exporter` | Image. |
| `image.tag` | `2.1.2` | **Single source of truth for version**; Renovate-managed. |
| `image.pullPolicy` | `IfNotPresent` | Pull policy. |
| `controller.type` | `statefulset` | Controller kind. |
| `controller.replicas` | `1` | Single writer. |
| `controller.updateStrategy` | `{type: RollingUpdate}` | STS update strategy. |
| `volumeClaimTemplates` | `config` / 10Mi / longhorn / RWO | Token-cache volume (→ `config-netatmo-exporter-0`), mounted at `/config`. |
| `podSecurityContext` | non-root, 1000, RuntimeDefault | Pod security. |
| `securityContext` | RO rootfs, no privesc | Container security. |
| `podAntiAffinity` | `true` | One replica per node. |
| `ports` | http 9210 | Container ports. |
| `envFromConfigMap` | `netatmo-exporter-config` | Env from ConfigMap (token-file path, external URL). |
| `env` | `NETATMO_CLIENT_ID/SECRET` from secret | Individual env from the ExternalSecret's Secret. |
| `configMaps` | `netatmo-exporter-config` | Generated ConfigMap. |
| `externalSecrets` | `netatmo-exporter-secret` | 1Password Connect refs; client creds + seed token. No secret material in-repo. |
| `initContainers` | `add-netatmo-token` | Seeds the token file into the config volume. |
| `resources` | 32–64Mi / 10–100m | Requests/limits. |
| `readinessProbe` / `livenessProbe` | httpGet `/metrics` :9210 | Health checks. |
| `volumeMounts` | `config` → /config | Container mounts. |
| `volumes` | `netatmo-exporter-secret` (secret) | Non-PVC volumes. |
| `service.*` | ClusterIP, http 9210 → targetPort http | Service. |
| `ingress.*` | host `netatmo-exporter.local.asztalos.net`, authentik + default-headers | Traefik IngressRoute. |
| `serviceMonitor.enabled` | `true` | Scraped. |
| `serviceMonitor.labels` | `release: prometheus-operator` | Preserved from original (harmless). |
| `serviceMonitor.endpoints` | `/metrics` @30s, targetPort http | Scrape config. |
| `persistentVolumeClaims` / `persistentVolumes` | `[]` | None. |
| `extraLabels` | `{}` | Extra labels. |

## Verify locally

```bash
helm dependency build charts/netatmo-exporter
helm lint charts/netatmo-exporter
helm template netatmo-exporter charts/netatmo-exporter | kubeconform -strict -ignore-missing-schemas -skip IngressRoute
bash hack/diff-migration.sh netatmo-exporter   # while apps/netatmo-exporter/install exists
```
