# nebula-sync

[nebula-sync](https://github.com/lovelaze/nebula-sync)
(`ghcr.io/lovelaze/nebula-sync`) — keeps a primary Pi-hole v6 and one or more
replicas in sync on a cron schedule. Rendered through the [`common`](../common)
library chart.

## Controller

**Deployment.** Stateless: it wakes on a cron (`CRON`), pulls config/gravity from
the primary Pi-hole and pushes to the replicas over HTTP, then sleeps. The only
writable path under its read-only root filesystem is an emptyDir at `/config`. No
owned PVC, no node-local hardware ⇒ Deployment.

## No Service — the point of interest

This is the **first migrated app with no Service at all**, and it exercises that
path through `common`:

- `services: []` → no Service object rendered
- `ingressRoute: {}` → no IngressRoute (no `routes`)
- `serviceMonitor.enabled: false` → no ServiceMonitor

nebula-sync only ever dials *out* — to the Pi-hole instances, and to apprise for
success/failure webhooks. Nothing connects *to* it. The container does serve a
`/health` endpoint on :8080, but that is used solely by the in-pod liveness and
readiness probes, so the port stays unexposed. The pod carries a `containerPort:
8080` for documentation; without a Service it routes nowhere.

## Configuration

All non-secret behaviour is environment, from a chart-owned ConfigMap
(`nebula-sync-env`) via `envFrom` — the sync toggles (`SYNC_CONFIG_*`,
`SYNC_GRAVITY_*`), the cron schedule, and the apprise webhook URLs/bodies. Being
chart-owned, `checksum/config` covers it, so editing any toggle rolls the pod.

The Pi-hole endpoints and their app-password tokens come from the
ExternalSecret-created Secret, also via `envFrom`. Each of `PRIMARY` and
`REPLICAS` is a single value combining a URL with its token
(`http://…|{{ token }}`), assembled by External Secrets Operator templating — so
the URLs live in the (non-secret) values file while only the tokens come from
1Password.

> **envFrom ordering:** `common` renders `configMapRef` before `secretRef`; the
> original manifest had them reversed. The two sets share no keys (the ConfigMap
> is all `SYNC_*`/`CRON`/webhook vars, the Secret is `PRIMARY`/`REPLICAS`), so
> the order has no effect — verified during migration.

## Scope boundary

Nothing lives outside the chart — no `pre-install/` or `post-install/`. There is
no Grafana dashboard or PrometheusRule for this app (it exposes no metrics).

## Generic chart vs. deployment values

This chart's [`values.yaml`](values.yaml) points `PRIMARY`/`REPLICAS` at
`pihole-*.example.com`. The deployment config in `apps/nebula-sync/values.yaml`
carries the real endpoints (the in-cluster `pihole-web` Service and the replica
at `10.10.50.5`). Everything else is identical.

## Migration notes

Verified against the pre-migration manifests: the **ConfigMap data** (29 keys,
including the emoji in the webhook bodies) and the **ExternalSecret spec** are
byte-identical. Deltas:

- The ConfigMap, ExternalSecret and Deployment pod template gain the standard
  five-label block and `checksum/config` — the hand-written ConfigMap was a plain
  manifest with no generator hash, so config edits did **not** previously roll the
  pod. Now they do (an improvement).
- `envFrom` order flipped, provably a no-op (see above).
- Image string quoted (Helm rendering artifact).

## Values

| Key | Default | Description |
|-----|---------|-------------|
| `name` | `nebula-sync` | App name — drives resource names, labels, namespace. |
| `image.repository` | `ghcr.io/lovelaze/nebula-sync` | Container image. |
| `image.tag` | `v0.11.2` | Image tag — single source of truth; Renovate-managed. |
| `controller.type` | `deployment` | Stateless cron worker ⇒ Deployment. |
| `serviceAccount.create` | `false` | Runs under the namespace `default` SA. |
| `podSecurityContext` | RuntimeDefault seccomp, uid/gid 1000, non-root | No fsGroup (emptyDir needs none). |
| `securityContext` | RO rootfs, no privilege escalation | Container security context. |
| `podAntiAffinity` | `true` | At most one replica per node. |
| `ports` | `8080` (unnamed, unexposed) | Health port for the probes only. |
| `envFromConfigMap` | `nebula-sync-env` | All sync toggles + webhook config. |
| `envFromSecrets` | `[nebula-sync-secret]` | `PRIMARY` / `REPLICAS` (URL + token). |
| `configMaps` | `nebula-sync-env` | 29 env keys; covered by `checksum/config`. |
| `externalSecrets` | `nebula-sync-secret` | 1Password refs → the two Pi-hole tokens. |
| `resources` | 32–64Mi / 100–200m | Requests/limits. |
| `readinessProbe` / `livenessProbe` | httpGet `/health` :8080 | Health checks. |
| `volumes` / `volumeMounts` | `config` emptyDir → /config | Only writable path. |
| `services` | `[]` | **None** — headless cron worker. |
| `ingressRoute` | `{}` | None. |
| `serviceMonitor.enabled` | `false` | Exposes no metrics. |
| `extraContainers` / `initContainers` | `[]` | None. |
| `persistentVolumeClaims` / `persistentVolumes` | `[]` | None. |

## Verify locally

```bash
helm dependency build charts/nebula-sync
helm lint charts/nebula-sync
helm template nebula-sync charts/nebula-sync | kubeconform -strict -ignore-missing-schemas
bash hack/diff-charts.sh      # regression vs the last proven render
```
