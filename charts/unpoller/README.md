# unpoller

[UniFi Poller](https://github.com/unpoller/unpoller)
(`ghcr.io/unpoller/unpoller`) — polls a UniFi controller and exposes the network,
client, DPI and device metrics to Prometheus. Rendered through the
[`common`](../common) library chart.

## Controller

**Deployment.** unpoller polls the controller over HTTP and serves the result on
`/metrics`; it owns no PVC and no host hardware ⇒ Deployment. Fully non-root on a
read-only root filesystem.

## Configuration is entirely in the ExternalSecret

unpoller reads a single TOML file, `/etc/unpoller/up.conf`, which embeds the UniFi
controller **credentials** — so the whole file is rendered by the ExternalSecret
(via ESO templating for `user`/`pass`) and mounted by `subPath`. There is no
separate non-secret ConfigMap: `configMaps: []`.

A consequence worth noting: the pod template gets **no `checksum/config`
annotation**, because that hash only covers chart-owned ConfigMaps. unpoller's
config lives in the ExternalSecret, which is deliberately excluded from the
checksum (its manifest is a reference; the real value rotates in 1Password without
changing it — see PLAN.md "checksum/config"). Editing `up.conf` here changes the
rendered ExternalSecret manifest, which ESO re-applies; roll the pod by hand if a
config change needs to take effect immediately.

## No IngressRoute

Metrics-only — Prometheus scrapes the Service in-cluster, nothing routes to it
through Traefik. `ingressRoute: {}` omits the object.

## Scope boundary

`apps/unpoller/post-install/` (a kustomize dir in the ArgoCD repo, synced as a
separate Application source) owns:

- **six Grafana dashboards** (`unpoller-*-insights`, `-dpi`, `-network-sites`),
  labelled `grafana_dashboard: "1"` and discovered by the kube-prometheus-stack
  sidecar in any namespace. Together ~1.2 MB of JSON — exactly what does not
  belong in `values.yaml`.
- the **`unpoller-alerts` PrometheusRule**.

> **`ServerSideApply=true` is mandatory** on the Application (preserved from the
> original). The client-dpi dashboard alone is ~834 KB; client-side apply would
> try to stash `last-applied-configuration` in an annotation and blow past the
> 256 KB metadata limit. Unlike homepage's images, the dashboards need no
> `disableNameSuffixHash` — nothing references them by name (the Grafana sidecar
> finds them by label), so the kustomize hash suffix is harmless here.

## Generic chart vs. deployment values

This chart's [`values.yaml`](values.yaml) points the controller at
`unifi.example.com`; `apps/unpoller/values.yaml` carries the real
`unifi.local.asztalos.net`. Everything else is identical.

## Migration notes

Verified byte-identical against the pre-migration manifests: **`up.conf`** (25
lines), the **ExternalSecret `data` remoteRefs**, the **ServiceMonitor spec**, and
all **six dashboard ConfigMaps** (their kustomize hash suffixes are unchanged,
which is content-derived proof). Deltas:

- ServiceMonitor renamed `unpoller-exporter` → `unpoller`, matching nut-exporter,
  unbound and apprise. Expect a brief metrics gap at cutover.
- The ExternalSecret gains the standard five-label block; the Service already had
  it. Cosmetic.
- Image string quoted (Helm rendering artifact).

## Values

| Key | Default | Description |
|-----|---------|-------------|
| `name` | `unpoller` | App name — drives resource names, labels, namespace. |
| `image.repository` | `ghcr.io/unpoller/unpoller` | Container image. |
| `image.tag` | `v3.3.3` | Image tag — single source of truth; Renovate-managed. |
| `controller.type` | `deployment` | HTTP poller ⇒ Deployment. |
| `serviceAccount.create` | `false` | Runs under the namespace `default` SA. |
| `podSecurityContext` | RuntimeDefault seccomp, uid/gid 1000, non-root | Homelab standard. |
| `securityContext` | RO rootfs, no privilege escalation | Container security context. |
| `podAntiAffinity` | `true` | At most one replica per node. |
| `ports` | `http` 9130 | Matches `http_listen` in up.conf. |
| `configMaps` | `[]` | None — config is entirely in the ExternalSecret. |
| `externalSecrets` | `unpoller-secret` | Renders up.conf; 1Password refs for the UniFi user/pass. |
| `resources` | 32–128Mi / 50–150m | Requests/limits. |
| `readinessProbe` / `livenessProbe` | httpGet `/metrics` :9130 | Health checks. |
| `volumes` / `volumeMounts` | `config-volume` (secret) → up.conf | Mounted by subPath. |
| `services` | `unpoller` ClusterIP :9130 | Service list. |
| `ingressRoute` | `{}` | None — metrics-only. |
| `serviceMonitor.enabled` | `true` | Scrapes `/metrics` at 60s (unpoller refreshes controller data every 60s). |
| `extraContainers` / `initContainers` | `[]` | None. |
| `persistentVolumeClaims` / `persistentVolumes` | `[]` | None. |

## Verify locally

```bash
helm dependency build charts/unpoller
helm lint charts/unpoller
helm template unpoller charts/unpoller | kubeconform -strict -ignore-missing-schemas
bash hack/diff-charts.sh      # regression vs the last proven render
```
