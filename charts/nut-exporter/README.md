# nut-exporter

Network UPS Tools (NUT) Prometheus exporter
([druggeri/nut_exporter](https://hub.docker.com/r/druggeri/nut_exporter)): polls a
NUT server (`upsd`) over the network and re-exposes the UPS variables — status,
battery charge/runtime, input/output voltage, load — as Prometheus metrics.
Rendered through the [`common`](../common) library chart.

## Controller

**Deployment.** The exporter is a stateless network poller: it owns no PVC and
touches no node-local hardware (the UPS hangs off a *different* host running
`upsd`), so per the homelab bright-line rule it is a plain Deployment with the
standard RollingUpdate. It runs fully non-root on a read-only root filesystem.

## Per-UPS scraping

`nut_exporter` serves one UPS at a time on `/ups_metrics`, selected by a `ups`
query parameter. The ServiceMonitor therefore carries **one endpoint per UPS**,
each with `params.ups` plus a `relabelings` rule that stamps a matching `ups`
label so the units stay distinguishable in Prometheus. Add or remove endpoints to
match the UPS units on your NUT server — the chart passes `serviceMonitor.endpoints`
through verbatim.

## Generic chart vs. deployment values

This chart's [`values.yaml`](values.yaml) holds **generic, shareable example
config** plus every default, so it renders on its own (pointing at
`nut.example.com` with sample UPS names `ups1`/`ups2`). The **deployment config**
lives in the GitOps repo (`apps/nut-exporter/values.yaml`) and is layered over this
chart by the ArgoCD Application via `helm.valueFiles`.

## Scope boundary

The two Grafana dashboards and the UPS `PrometheusRule` alarms are **not** in this
chart. They live in the ArgoCD repo under `apps/nut-exporter/post-install/`
(a kustomize dir) and sync as a separate ArgoCD Application source — see
[PLAN.md](../../PLAN.md) "Scope boundary". They were already there before the
migration, so nothing had to be relocated.

## Migration notes

- The ServiceMonitor was previously named **`nut-exporter-exporter`** and is
  normalized to `nut-exporter` here. ArgoCD prunes the old object and creates the
  new one; Prometheus re-discovers it within a scrape interval, so expect a brief
  gap in UPS metrics at cutover. Its `spec` is otherwise byte-identical.
- The `release: prometheus-operator` label is preserved, but is vestigial —
  `serviceMonitorSelectorNilUsesHelmValues: false` means Prometheus discovers all
  ServiceMonitors regardless of labels.
- kustomize hashed the ConfigMap name (`nut-exporter-config-m69h9k6k5g`); Helm
  uses the static name plus a `checksum/config` pod annotation, so a config change
  still rolls the pods.
- The ExternalSecret and IngressRoute gain the standard five-label block, which
  the hand-written manifests omitted. Neither object is selected by label, so this
  is cosmetic.

## Values

All values below are set in [`values.yaml`](values.yaml) with their effective
defaults. This table documents them.

| Key | Default | Description |
|-----|---------|-------------|
| `name` | `nut-exporter` | App name — drives resource names, labels, namespace. |
| `namespace` | `nut-exporter` | Target namespace. |
| `image.repository` | `druggeri/nut_exporter` | Container image. |
| `image.tag` | `3.3.0` | Image tag — **single source of truth for app version**; bumped by Renovate. |
| `image.pullPolicy` | `IfNotPresent` | Image pull policy. |
| `controller.type` | `deployment` | Stateless network poller ⇒ Deployment. |
| `controller.replicas` | `1` | One replica; the exporter is a pure poller. |
| `controller.progressDeadlineSeconds` | `600` | Rollout progress deadline. |
| `controller.revisionHistoryLimit` | `2` | Retained controller revisions. |
| `controller.strategy` | RollingUpdate, surge/unavailable 1 | Update strategy. |
| `podSecurityContext` | RuntimeDefault seccomp, uid/gid 1000, non-root | Homelab standard pod security. |
| `securityContext` | RO rootfs, no privilege escalation | Container security context. |
| `podAntiAffinity` | `true` | At most one replica per node. |
| `ports` | `http` 9199 | Container ports. |
| `envFromConfigMap` | `nut-exporter-config` | Non-secret env (NUT server address, variables). |
| `envFromSecrets` | `[nut-exporter-secret]` | NUT login credentials from the ExternalSecret. |
| `env` | `[]` | No individual env vars. |
| `configMaps` | `nut-exporter-config` | NUT server host/port + the exported variable list. |
| `externalSecrets` | `nut-exporter-secret` | 1Password Connect ref → `NUT_EXPORTER_USERNAME` / `_PASSWORD`. |
| `resources` | 32–64Mi / 10–100m | Requests/limits. |
| `readinessProbe` / `livenessProbe` | httpGet `/metrics` :9199 | Health checks. |
| `volumeMounts` / `volumes` / `initContainers` | `[]` | None — stateless. |
| `services` | `nut-exporter` ClusterIP :9199 | Service list. |
| `ingressRoute` | `nut-exporter.example.com` :9199 | Traefik route, authentik + default-headers middlewares. |
| `serviceMonitor.enabled` | `true` | Scraped — one endpoint per UPS (see above). |
| `persistentVolumeClaims` / `persistentVolumes` | `[]` | None. |
| `extraLabels` | `{}` | Extra labels merged into the standard label block. |

## Verify locally

```bash
helm dependency build charts/nut-exporter
helm lint charts/nut-exporter
# renders on defaults alone:
helm template nut-exporter charts/nut-exporter | kubeconform -strict -ignore-missing-schemas -skip IngressRoute
# migration equivalence against install/ (renders with the tailored GitOps values
# auto-picked up from ../ArgoCD/apps/nut-exporter/values.yaml):
bash hack/diff-migration.sh nut-exporter
```
