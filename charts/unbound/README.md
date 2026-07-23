# unbound

[Unbound](https://nlnetlabs.nl/projects/unbound/) recursive DNS resolver
([klutchell/unbound](https://hub.docker.com/r/klutchell/unbound)), forwarding
upstream over DNS-over-TLS, with a Prometheus exporter sidecar. Rendered through
the [`common`](../common) library chart.

Requires **`common` >= 0.3.0** for `extraContainers`.

## Controller

**Deployment.** Unbound holds only an in-memory cache — no PVC, no node-local
hardware — so per the homelab bright-line rule it is a plain Deployment.

## Two containers

This is the first chart in the repo with a sidecar, and the reason `common`
gained `extraContainers`:

| Container | Role |
|---|---|
| `unbound` | The resolver. Binds :53 UDP+TCP, writes its remote-control socket to `/var/run/unbound`. |
| `exporter` | [`cyb3rjak3/unbound-exporter`](https://hub.docker.com/r/cyb3rjak3/unbound-exporter). Connects to that socket via `-unbound.host=unix:///var/run/unbound/unbound.ctl` and serves metrics on :9167. |

They share an **emptyDir at `/var/run/unbound`** — that shared socket is the
whole reason the two run in one pod rather than as separate workloads. The
ServiceMonitor scrapes the sidecar through the Service's `metrics` port.

`extraContainers` is passed through **verbatim**, so the sidecar's image is a
combined `repo:tag` string rather than the structured `image.repository` /
`image.tag` used for the main container. The `# renovate:` comment sits directly
above the `image:` line and is matched by the second `customManager` in
[`renovate.json`](../../renovate.json) — **keep those two lines adjacent** or the
sidecar silently stops receiving updates.

## Non-standard security context

Unbound does **not** use the usual homelab uid/gid 1000:

```yaml
podSecurityContext:
  runAsUser: 101    # must match unbound's user inside the image
  runAsGroup: 102
  fsGroup: 102      # matches the "unbound" group
```

Both containers must be able to read/write the shared control socket, so the ids
have to match the image's own `unbound` user. There is also deliberately **no
`seccompProfile`** here, matching the original manifest.

`readOnlyRootFilesystem` is `false` — unbound needs to write `/var/unbound`
(`root.hints`, `root.key`). The corresponding `ignore-check.kube-linter.io/…`
waiver is preserved on the Deployment via `controller.annotations`.
`NET_BIND_SERVICE` is added back after dropping `ALL` so it can bind port 53.

## Generic chart vs. deployment values

Unusually, the two files are **identical** — same situation as vcgen-exporter.
Nothing in `unbound.conf` or `forward-records.conf` is homelab-specific: it is
stock upstream tuning, RFC1918 `access-control` ranges, and Cloudflare DoT
forwarders. The GitOps copy is kept in full anyway so
`apps/unbound/values.yaml` remains the complete statement of what is deployed.

Both ConfigMaps are chart-owned, so `checksum/config` covers them: editing either
file rolls the pod. That matters here — a resolver's entire behaviour is defined
by those files.

## No IngressRoute

unbound is reached in-cluster by Service (and via MetalLB), never through
Traefik. `ingressRoute: {}` omits the object entirely.

## Scope boundary

The Grafana dashboard and the `unbound-alerts` PrometheusRule are **not** in this
chart. They live in the ArgoCD repo under `apps/unbound/post-install/` and sync
as a separate Application source — see [PLAN.md](../../PLAN.md) "Scope boundary".
They were already there before the migration, so nothing had to be relocated.

## Migration notes

Verified byte-identical against the pre-migration manifests: **both config files**
(334 and 37 lines), the **ServiceMonitor spec**, and the **entire exporter
sidecar**. Remaining deltas:

- ServiceMonitor renamed `unbound-exporter` → `unbound` (chart names it after the
  app), matching the change made for nut-exporter. ArgoCD prunes the old object
  and creates the new one; expect a brief gap in unbound metrics at cutover.
- The two ConfigMaps were kustomize-generated with hash suffixes; they are now
  statically named, with `checksum/config` preserving the roll-on-change
  behaviour.
- The ConfigMaps' `app.kubernetes.io/component` changes from `config` to
  `unbound`, and they gain `app: unbound` — the chart applies one standard label
  block everywhere. Cosmetic: they are mounted by name, never selected by label.

## Values

All values below are set in [`values.yaml`](values.yaml) with their effective
defaults. This table documents them.

| Key | Default | Description |
|-----|---------|-------------|
| `name` | `unbound` | App name — drives resource names, labels, namespace. |
| `namespace` | `unbound` | Target namespace. |
| `image.repository` | `klutchell/unbound` | Main container image. |
| `image.tag` | `1.25.2` | Image tag — **single source of truth for app version**; bumped by Renovate. |
| `controller.type` | `deployment` | In-memory cache only ⇒ Deployment. |
| `controller.annotations` | kube-linter waiver | Preserved `no-read-only-root-fs` waiver. |
| `serviceAccount.create` | `false` | Runs under the namespace `default` SA. |
| `podSecurityContext` | uid 101 / gid 102, no seccomp | Must match the image's `unbound` user (socket sharing). |
| `securityContext` | RW rootfs, drop ALL, add NET_BIND_SERVICE | Main container; needs :53 and a writable `/var/unbound`. |
| `podAntiAffinity` | `true` | At most one replica per node. |
| `ports` | `dns-udp` 53/UDP, `dns-tcp` 53/TCP | Main container ports. |
| `envFromConfigMap` / `env` | empty | Unbound is configured entirely by file. |
| `configMaps` | `unbound-main-conf`, `unbound-forward-records-conf` | The two config files, mounted by `subPath`. |
| `externalSecrets` | `[]` | None — unbound authenticates to nothing. |
| `resources` | 32–128Mi / 100–200m | Main container requests/limits. |
| `readinessProbe` / `livenessProbe` | tcpSocket :53 | A TCP connect is the meaningful signal for a resolver. |
| `volumes` / `volumeMounts` | socket emptyDir + 2 ConfigMaps | The emptyDir is shared with the sidecar. |
| `extraContainers` | `exporter` sidecar | Metrics on :9167 from the shared control socket. |
| `services` | `unbound` ClusterIP :53 UDP+TCP, :9167 | Service list. |
| `ingressRoute` | `{}` | None — in-cluster resolver. |
| `serviceMonitor.enabled` | `true` | Scrapes the sidecar via the `metrics` port. |
| `persistentVolumeClaims` / `persistentVolumes` | `[]` | None. |
| `extraLabels` | `{}` | Extra labels merged into the standard label block. |

## Verify locally

```bash
helm dependency build charts/unbound
helm lint charts/unbound
helm template unbound charts/unbound | kubeconform -strict -ignore-missing-schemas
# regression vs the last proven render (the gate that matters after cutover):
bash hack/diff-charts.sh
```
