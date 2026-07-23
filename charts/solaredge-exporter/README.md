# solaredge-exporter

SolarEdge inverter Prometheus exporter (`asztalosgyula/solaredge-exporter`, a
self-maintained image) — reads a **local** SolarEdge inverter over Modbus TCP and
exposes the production metrics. Rendered through the [`common`](../common) library
chart.

## Controller

**Deployment.** Talks to a LAN inverter over Modbus and serves `/metrics`; owns no
PVC and no host hardware ⇒ Deployment. Fully non-root on a read-only root
filesystem, with one writable `emptyDir` at `/app` (the exporter writes there).

## No secrets

Unlike most exporters, there is **no ExternalSecret**: Modbus TCP to a local
inverter is unauthenticated, so there is no API key. All configuration — the
inverter's LAN address, port, poll interval and Modbus client id — is non-secret
and lives in a chart-owned ConfigMap via `envFrom`.

The inverter address is the one genuinely deployment-specific value, so the
generic chart uses a placeholder (`10.0.0.10`) and the tailored GitOps values
carry the real `10.10.20.14`.

## Exec liveness probe

Same pattern as tado-exporter: readiness is `httpGet /metrics`, but **liveness is
an `exec` probe** that asserts `/metrics` returns real data (more than the header
line), catching a silently-failed inverter poll that a 200 would not. `common`
passes `livenessProbe` through verbatim. Preserved from the original.

## Image tag

The tag is a **build date** (`YYYYMMDD`), Renovate-tracked as an increasing
number. Self-maintained image; a Renovate PR just signals a newer build exists.

## No IngressRoute

Metrics-only — scraped in-cluster. `ingressRoute: {}` omits it.

## Scope boundary

`apps/solaredge-exporter/post-install/` (a kustomize dir, separate ArgoCD source)
owns the Grafana dashboard and the `solaredge-exporter-alerts` PrometheusRule. The
dashboard is now **generated from `solaredge-grafana-dashboard.json` via
`configMapGenerator`**, replacing the old literal ConfigMap — the JSON is a plain
diffable file that kustomize wraps. Nothing references the ConfigMap by name (the
Grafana sidecar finds it by label), so the generated hash suffix is harmless.

## Migration notes

Verified byte-identical against the pre-migration manifests: the config data
(including the real inverter address), the **dashboard JSON** (1505 lines), the
ServiceMonitor spec, and the PrometheusRule spec. Deltas:

- ServiceMonitor renamed `solaredge-exporter-exporter` → `solaredge-exporter`
  (the chart names it after the app), matching nut-exporter, unbound, apprise and
  unpoller. Expect a brief metrics gap at cutover.
- The dashboard ConfigMap goes from a literal name to a generated hashed name —
  the intended standardization. Content unchanged.
- The config ConfigMap's kustomize hash → static name, plus `checksum/config` on
  the pod so edits still roll it.
- The config ConfigMap gains `app: solaredge-exporter`; image string quoted.

## Values

| Key | Default | Description |
|-----|---------|-------------|
| `name` | `solaredge-exporter` | App name — drives resource names, labels, namespace. |
| `image.repository` | `asztalosgyula/solaredge-exporter` | Self-maintained image. |
| `image.tag` | `20250905` | Build date (YYYYMMDD); Renovate-tracked. |
| `controller.type` | `deployment` | Modbus poller. |
| `serviceAccount.create` | `false` | Runs under the namespace `default` SA. |
| `podSecurityContext` | RuntimeDefault seccomp, uid/gid 1000, non-root | Homelab standard. |
| `securityContext` | RO rootfs, no privilege escalation | Container security context. |
| `podAntiAffinity` | `true` | At most one replica per node. |
| `ports` | `http` 2112 | Container port. |
| `envFromConfigMap` | `solaredge-exporter-config` | Inverter address/port/interval/client-id. |
| `externalSecrets` | `[]` | **None** — Modbus is unauthenticated. |
| `readinessProbe` | httpGet `/metrics` :2112 | Simple up-check. |
| `livenessProbe` | exec (see above) | Asserts real data, not just a 200. |
| `volumeMounts` / `volumes` | `app` emptyDir → /app | Writable dir under RO rootfs. |
| `services` | `solaredge-exporter` ClusterIP :2112 | Service list. |
| `ingressRoute` | `{}` | None — metrics-only. |
| `serviceMonitor.enabled` | `true` | Scrapes `/metrics` at 30s. |
| `initContainers` / `extraContainers` | `[]` | None. |
| `persistentVolumeClaims` / `persistentVolumes` | `[]` | None. |

## Verify locally

```bash
helm dependency build charts/solaredge-exporter
helm lint charts/solaredge-exporter
helm template solaredge-exporter charts/solaredge-exporter | kubeconform -strict -ignore-missing-schemas
bash hack/diff-charts.sh
```
