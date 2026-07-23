# vcgen-exporter

Raspberry Pi `vcgencmd` exporter ([2281995/vcgen-exporter](https://hub.docker.com/r/2281995/vcgen-exporter)):
reads on-die temperature / clock / voltage through the privileged `vcgencmd`
interface and exposes them as Prometheus metrics. Rendered through the
[`common`](../common) library chart.

## Controller

**DaemonSet.** This is a node-local hardware exporter — one pod per node reading
that node's own SoC sensors — so per the homelab rule (*node-local hardware ⇒
DaemonSet*) it is not a Deployment. A DaemonSet's `spec.selector` is immutable, so
the chart reproduces the original manifest's selector exactly via
`controller.selectorLabels` (`name` + `instance`); the pod template still carries
the full label set, so the subset selector stays satisfied and an in-place apply
does not fail.

## Privileged

`vcgencmd` requires talking to the host hardware, so the container runs
**privileged, as root** (`runAsUser: 0`, `allowPrivilegeEscalation: true`) — the
read-only rootfs is still kept. The three `ignore-check.kube-linter.io/*`
annotations on the DaemonSet (waiving run-as-non-root / privileged /
privilege-escalation) are preserved from the original manifest.

## Generic chart vs. deployment values

This chart's [`values.yaml`](values.yaml) holds **generic, shareable example
config** plus every default, so it renders on its own. The **deployment config**
lives in the GitOps repo (`apps/vcgen-exporter/values.yaml`) and is layered over
this chart by the ArgoCD Application via `helm.valueFiles`. This app has no
domain-specific config, so the two files are identical.

## Scope boundary

The Grafana dashboard and the `rpi-alerts` PrometheusRule are **not** in this
chart. They live in the ArgoCD repo under `apps/vcgen-exporter/post-install/`
(a kustomize dir) and sync as a separate ArgoCD Application source — see
[PLAN.md](../../PLAN.md) "Scope boundary".

## Values

All values below are set in [`values.yaml`](values.yaml) with their effective
defaults. This table documents them.

| Key | Default | Description |
|-----|---------|-------------|
| `name` | `vcgen-exporter` | App name — drives resource names, labels, namespace. |
| `namespace` | `vcgen-exporter` | Target namespace. |
| `image.repository` | `2281995/vcgen-exporter` | Container image. |
| `image.tag` | `v1.0.1` | Image tag — **single source of truth for app version**; bumped by Renovate. |
| `image.pullPolicy` | `IfNotPresent` | Image pull policy. |
| `controller.type` | `daemonset` | Node-local hardware exporter ⇒ DaemonSet. |
| `controller.revisionHistoryLimit` | `2` | Retained controller revisions. |
| `controller.selectorLabels` | `name` + `instance` | Immutable selector, reproduced from the original manifest. |
| `controller.annotations` | 3× kube-linter waivers | Preserved privileged/root waivers on the DaemonSet. |
| `serviceAccount.create` | `true` | Create the ServiceAccount. |
| `serviceAccount.name` | `vcgen-exporter` | ServiceAccount name. |
| `serviceAccountName` | `vcgen-exporter` | SA the pod runs under. |
| `securityContext` | privileged, `runAsUser: 0`, RO rootfs | Container security context (needs root for `vcgencmd`). |
| `podSecurityContext` | `{}` | None (runs as root by design). |
| `podAntiAffinity` | `false` | Meaningless for a DaemonSet (already one-per-node). |
| `hostNetwork` | `false` | Metrics served on the pod IP. |
| `ports` | metrics 8080 | Container ports. |
| `env` / `envFromConfigMap` / `envFromSecrets` / `configMaps` / `externalSecrets` / `initContainers` | empty | No configuration. |
| `resources` | 50–100Mi / 50–200m | Requests/limits. |
| `readinessProbe` / `livenessProbe` | httpGet `/metrics` :8080 | Health checks. |
| `volumeMounts` / `volumes` | `[]` | None. |
| `services` | `vcgen-exporter-metrics` ClusterIP :8080 | Service list (`-metrics` suffix + `name`+`instance` selector preserved from the original). |
| `ingressRoute` | `{}` | None — metrics scraped in-cluster by Prometheus. |
| `serviceMonitor.enabled` | `true` | Scraped; adds a `nodename` label (from the pod's node) for per-node temps. |
| `persistentVolumeClaims` / `persistentVolumes` | `[]` | None. |
| `extraLabels` | `{}` | Extra labels merged into the standard label block. |

## Verify locally

```bash
helm dependency build charts/vcgen-exporter
helm lint charts/vcgen-exporter
# renders on defaults alone:
helm template vcgen-exporter charts/vcgen-exporter | kubeconform -strict -ignore-missing-schemas -skip IngressRoute
# migration equivalence against install/ (renders with the tailored GitOps values
# auto-picked up from ../ArgoCD/apps/vcgen-exporter/values.yaml):
bash hack/diff-migration.sh vcgen-exporter
```
