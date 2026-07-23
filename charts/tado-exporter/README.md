# tado-exporter

tado° Prometheus exporter (`asztalosgyula/tado-exporter`, a self-maintained
image) — polls the tado° cloud API and exposes smart-thermostat zone metrics.
Rendered through the [`common`](../common) library chart.

## Controller

**Deployment.** A stateless cloud poller — no owned PVC, no host hardware ⇒
Deployment. Fully non-root on a read-only root filesystem.

## Exec liveness probe

Readiness is a plain `httpGet /metrics`, but **liveness is an `exec` probe**:

```sh
wget -q -O - http://localhost:9898/metrics | awk '{if (NR>1) ok=1};END{if (ok==1) exit 0; else exit 1}'
```

The exporter serves `/metrics` (so httpGet would always 200) but only fills it
with data after a successful tado° poll. The exec probe asserts the body has more
than the header line — i.e. the upstream poll is actually working — which a status
check alone would miss. `common` passes `livenessProbe` through verbatim, so the
exec block renders as-is. Preserved from the original manifest.

## Configuration

Non-secret tuning (`EXPORTER_TICKER`, `RUST_LOG`) comes from a chart-owned
ConfigMap via `envFrom`; the tado° account credentials come from the
ExternalSecret-created Secret, also via `envFrom`. `checksum/config` covers the
ConfigMap, so tuning edits roll the pod.

## Image tag

The image tag is a **build date** (`YYYYMMDD`). Renovate's default docker
versioning tracks it fine — a newer date is a larger number, so it bumps in the
right direction. It is a self-maintained image, so a Renovate PR simply signals
"a newer build exists".

## No IngressRoute

Metrics-only — scraped in-cluster by Prometheus. `ingressRoute: {}` omits it.

## Scope boundary

`apps/tado-exporter/post-install/` (a kustomize dir, separate ArgoCD source) owns
the Grafana dashboard and the `tado-exporter-alerts` PrometheusRule. The dashboard
is now **generated from `tado-grafana-dashboard.json` via `configMapGenerator`**,
replacing the old hand-written literal ConfigMap — the JSON lives as a plain,
diffable file and kustomize wraps it. Nothing references the ConfigMap by name
(the Grafana sidecar finds it by the `grafana_dashboard` label), so the generated
hash suffix is harmless.

## Migration notes

Verified byte-identical against the pre-migration manifests: the config data, the
**dashboard JSON** (2212 lines), the ExternalSecret spec, the ServiceMonitor spec,
and the PrometheusRule spec. Deltas:

- The dashboard ConfigMap changes from a literal name to a generated
  hashed name (`tado-exporter-grafana-dashboard` →
  `tado-exporter-grafana-dashboard-<hash>`) — the intended standardization to
  generated dashboards. Content unchanged.
- The config ConfigMap's kustomize hash → static name, plus `checksum/config` on
  the pod so edits still roll it.
- ServiceMonitor was **already** named `tado-exporter` (no rename); it gains the
  standard five-label block on top of its `release:` label. Cosmetic.
- ExternalSecret gains the five-label block; image string quoted.

## Values

| Key | Default | Description |
|-----|---------|-------------|
| `name` | `tado-exporter` | App name — drives resource names, labels, namespace. |
| `image.repository` | `asztalosgyula/tado-exporter` | Self-maintained image. |
| `image.tag` | `20260504` | Build date (YYYYMMDD); Renovate-tracked. |
| `controller.type` | `deployment` | Stateless cloud poller. |
| `serviceAccount.create` | `false` | Runs under the namespace `default` SA. |
| `podSecurityContext` | RuntimeDefault seccomp, uid/gid 1000, non-root | Homelab standard. |
| `securityContext` | RO rootfs, no privilege escalation | Container security context. |
| `podAntiAffinity` | `true` | At most one replica per node. |
| `ports` | `metrics` 9898 | Container port. |
| `envFromConfigMap` | `tado-exporter-config` | `EXPORTER_TICKER`, `RUST_LOG`. |
| `envFromSecrets` | `[tado-exporter-secret]` | tado° credentials as env. |
| `externalSecrets` | `tado-exporter-secret` | 1Password refs → `EXPORTER_USERNAME`/`_PASSWORD`. |
| `readinessProbe` | httpGet `/metrics` :9898 | Simple up-check. |
| `livenessProbe` | exec (see above) | Asserts real data, not just a 200. |
| `services` | `tado-exporter` ClusterIP :9898 | Service list. |
| `ingressRoute` | `{}` | None — metrics-only. |
| `serviceMonitor.enabled` | `true` | Scrapes `/metrics` at 30s. |
| `volumeMounts` / `volumes` / `initContainers` / `extraContainers` | `[]` | None. |
| `persistentVolumeClaims` / `persistentVolumes` | `[]` | None. |

## Verify locally

```bash
helm dependency build charts/tado-exporter
helm lint charts/tado-exporter
helm template tado-exporter charts/tado-exporter | kubeconform -strict -ignore-missing-schemas
bash hack/diff-charts.sh
```
