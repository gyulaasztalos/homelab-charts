# flexget

[FlexGet](https://flexget.com) automation (LinuxServer.io build,
`lscr.io/linuxserver/flexget`) — RSS/feed download automation with a web UI.
Rendered through the [`common`](../common) library chart.

## Controller — StatefulSet

flexget owns a **writable RWO Longhorn volume** for `/config` (its task database,
logs, working files), so per the homelab bright-line rule it is a **StatefulSet**
with a `volumeClaimTemplate`, not a Deployment.

The original manifest was a `Deployment` + static PVC + `RollingUpdate`, which on
an RWO volume causes multi-attach flaps (the new pod attaches before the old
releases). The StatefulSet (single replica, ordered update) fixes that
structurally. The `config` volumeClaimTemplate provisions **`config-flexget-0`**
(RWO, longhorn, 350Mi — same size as the old PVC).

> **Migrating an existing deployment:** the PVC name changes
> `flexget-config-pvc` → `config-flexget-0`, so the data must be moved. The
> one-time, reversible, data-preserving cutover (Longhorn clone) is documented in
> `../ArgoCD/apps/flexget/MIGRATION-statefulset.md`. **The cutover push deletes
> the old PVC via ArgoCD prune — clone first, per that doc.**

## LinuxServer.io security pattern

Same as apprise: the image drops privileges itself via `PUID`/`PGID` env, so the
pod only pins `fsGroup: 1000` and does not force the container non-root — hence
the two preserved kube-linter waivers (`no-read-only-root-fs`, `run-as-non-root`).

## Configuration

Non-secret env (`PUID`/`PGID`/`TZ`, log + config file paths) comes from a
chart-owned ConfigMap via `envFrom`, so `checksum/config` covers it.

flexget's **entire `config.yml`** (feeds, trackers, rules) lives in 1Password and
is pulled verbatim by the ExternalSecret, then mounted over `/config/config.yml`
via `subPath` — so the config overlays the persistent volume, and flexget reads
its rules from 1Password while its state DB lives on the PVC. The web-UI password
(`FG_WEBUI_PASSWORD`) is a second key from the same 1Password item, injected as an
env var.

## No metrics, no post-install

flexget exposes no Prometheus endpoint (`serviceMonitor.enabled: false`), and
there are no auxiliary post-install assets.

## Generic chart vs. deployment values

This chart's [`values.yaml`](values.yaml) points the IngressRoute at
`flexget.example.com`; `apps/flexget/values.yaml` carries the real
`flexget.local.asztalos.net`. Everything else is identical.

## Migration notes

Verified against the pre-migration manifests: the ConfigMap data (6 keys), the
ExternalSecret `data`/`target`, and the container (env, envFrom, probes,
resources, mounts) are all **identical**. Intentional deltas:

- **Deployment → StatefulSet** (the controller-kind change).
- **static PVC `flexget-config-pvc` → volumeClaimTemplate `config-flexget-0`**
  (the pod's `config` volume moves out of `spec.volumes` into the template).
- ConfigMap kustomize-hash → static name, plus `checksum/config` on the pod.
- Service/ExternalSecret gain the standard five-label block; Service gains an
  explicit `type: ClusterIP` (was the implicit default); the IngressRoute route
  gains `priority: 10` (the chart default — immaterial for a single route on a
  unique host). Image string quoted.

## Values

| Key | Default | Description |
|-----|---------|-------------|
| `name` | `flexget` | App name — drives resource names, labels, namespace. |
| `image.repository` | `lscr.io/linuxserver/flexget` | LinuxServer.io image. |
| `image.tag` | `v3.16.14-ls239` | Image tag — single source of truth; Renovate-managed. |
| `controller.type` | `statefulset` | Owns a writable RWO volume ⇒ StatefulSet. |
| `controller.updateStrategy` | RollingUpdate | Ordered, one-at-a-time (no RWO overlap). |
| `controller.annotations` | 2 kube-linter waivers | RO-rootfs + run-as-non-root. |
| `volumeClaimTemplates` | `config` RWO longhorn 350Mi | → `config-flexget-0` at `/config`. |
| `serviceAccount.create` | `false` | Runs under the namespace `default` SA. |
| `podSecurityContext` | `fsGroup: 1000` only | LinuxServer.io drops privileges via PUID/PGID. |
| `securityContext` | `allowPrivilegeEscalation: false` | Container security context. |
| `podAntiAffinity` | `true` | At most one replica per node. |
| `ports` | `webui` 5050 | Container port. |
| `envFromConfigMap` | `flexget-config` | PUID/PGID/TZ, log + config file paths. |
| `env` | `FG_WEBUI_PASSWORD` (secretKeyRef) | Web-UI password from the Secret. |
| `configMaps` | `flexget-config` | 6 env keys; covered by `checksum/config`. |
| `externalSecrets` | `flexget-secret` | 1Password → `config.yml` + `FG_WEBUI_PASSWORD`. |
| `readinessProbe` / `livenessProbe` | httpGet `/` :5050 | Web-UI health. |
| `volumeMounts` / `volumes` | secret subPath + `config` (VCT) | See configuration. |
| `services` | `flexget` ClusterIP :5050 | Service list. |
| `ingressRoute` | `flexget.example.com` :5050 | authentik + default-headers. |
| `serviceMonitor.enabled` | `false` | No metrics endpoint. |
| `initContainers` / `extraContainers` | `[]` | None. |
| `persistentVolumeClaims` / `persistentVolumes` | `[]` | None (RWO via VCT). |

## Verify locally

```bash
helm dependency build charts/flexget
helm lint charts/flexget
helm template flexget charts/flexget | kubeconform -strict -ignore-missing-schemas -skip IngressRoute
bash hack/diff-charts.sh
```
