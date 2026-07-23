# homepage

[gethomepage](https://gethomepage.dev) dashboard — the homelab's service landing
page, with Kubernetes, Longhorn, Traefik and per-service widgets. Rendered through
the [`common`](../common) library chart.

Requires **`common` >= 0.2.0** for `serviceAccount.tokenSecret`.

## Controller

**Deployment.** All configuration arrives from ConfigMaps and a Secret; the only
writable paths are two emptyDirs. Nothing is owned on disk and no node-local
hardware is touched, so per the homelab bright-line rule it is a plain Deployment.

The container runs fully non-root on a read-only root filesystem, which is why
`/app/config` and `/app/config/logs` are emptyDirs — homepage writes into
`/app/config` at startup, and the individual config files are then layered on top
of that emptyDir via `subPath` mounts.

## ServiceAccount and its long-lived token

homepage's `kubernetes` widget runs in `mode: cluster` and calls the API server
directly, so it needs a durable API token. Since Kubernetes 1.24 a ServiceAccount
no longer gets an auto-generated token Secret, so the chart emits one explicitly:

```yaml
serviceAccount:
  create: true
  secrets: [{ name: homepage }]   # the SA's own back-reference
  tokenSecret:
    create: true                  # kubernetes.io/service-account-token
```

The Secret is rendered **empty** — it carries only the
`kubernetes.io/service-account.name` annotation, and kube-controller-manager fills
in the token in-cluster. The `common` template has no `data`/`stringData` field at
all, so it cannot carry secret material into the repo.

The `ClusterRole` and `ClusterRoleBinding` that grant this SA its read access are
**not** in the chart — see below.

## Scope boundary

This app is split across two ArgoCD sources. The chart owns the core workload;
`apps/homepage/pre-install/` (a kustomize dir in the ArgoCD repo) owns:

| Object | Why it's out of the chart |
|---|---|
| `ClusterRole` + `ClusterRoleBinding` | Cluster-scoped RBAC — the existing scope-boundary rule sends extra RBAC to `pre-install/`. |
| `homepage-images` ConfigMap | The artwork is **binary** (`.jpg`/`.png`). Carrying it in `values.yaml` would mean base64 blobs via `.Files.Get`, with the assets living in the chart repo. |

### Two consequences worth knowing

1. **`disableNameSuffixHash: true` is mandatory** in the pre-install
   `kustomization.yaml`. The Deployment that mounts `homepage-images` is rendered
   by Helm in a *different* ArgoCD source, so kustomize can no longer rewrite the
   volume reference to a hashed name the way it did when the whole app was one
   kustomize dir. The name must stay literally `homepage-images`.

2. **Changing artwork does not roll the pod.** The hash churn used to do that.
   After replacing an image, restart by hand:
   `kubectl rollout restart deploy/homepage -n homepage`.
   The chart-owned ConfigMaps are unaffected — `homepage-env` and `homepage-config`
   are both covered by the chart's `checksum/config` annotation, so editing any
   dashboard config still rolls the pod automatically.

## Generic chart vs. deployment values

This chart's [`values.yaml`](values.yaml) holds **generic, shareable example
config** plus every default, so it renders and runs on its own with stock artwork
pointing at `example.com`. The **deployment config** lives in the GitOps repo
(`apps/homepage/values.yaml`) and is layered over this chart by the ArgoCD
Application via `helm.valueFiles`.

The generic chart deliberately **omits the `homepage-images` volume and its two
mounts** — a fork that copied them would get a pod stuck on a missing ConfigMap.
The tailored GitOps values add them back.

> `volumeMounts` and `volumes` are **lists**: Helm replaces them wholesale rather
> than merging, so the tailored values file repeats every entry.

`HOMEPAGE_ALLOWED_HOSTS` must stay in sync with `ingressRoute.routes[].host` —
homepage rejects requests whose `Host` header is not listed.

## Migration notes

- The three ConfigMaps were kustomize-generated with hash suffixes
  (`homepage-config-8bmm759bm2` etc.). All three are now statically named; their
  **data is byte-identical**, verified including the binary artwork.
- The ExternalSecret and IngressRoute gain the standard five-label block, which
  the hand-written manifests omitted. Neither is selected by label, so this is
  cosmetic.
- `pre-install/images/nut.png` is carried over but is **not referenced** by the
  `configMapGenerator` — it was already unused before the migration.

## Values

All values below are set in [`values.yaml`](values.yaml) with their effective
defaults. This table documents them.

| Key | Default | Description |
|-----|---------|-------------|
| `name` | `homepage` | App name — drives resource names, labels, namespace. |
| `namespace` | `homepage` | Target namespace. |
| `image.repository` | `ghcr.io/gethomepage/homepage` | Container image. |
| `image.tag` | `v1.13.2` | Image tag — **single source of truth for app version**; bumped by Renovate. |
| `image.pullPolicy` | `IfNotPresent` | Image pull policy. |
| `controller.type` | `deployment` | Stateless dashboard ⇒ Deployment. |
| `controller.replicas` | `1` | One replica. |
| `controller.progressDeadlineSeconds` | `600` | Rollout progress deadline. |
| `controller.revisionHistoryLimit` | `2` | Retained controller revisions. |
| `controller.strategy` | RollingUpdate, surge/unavailable 1 | Update strategy. |
| `serviceAccount.create` | `true` | Create the ServiceAccount. |
| `serviceAccount.secrets` | `[{name: homepage}]` | SA `secrets:` back-reference. |
| `serviceAccount.tokenSecret.create` | `true` | Long-lived SA token Secret (needs `common` >= 0.2.0). |
| `serviceAccountName` | `homepage` | SA the pod runs under. |
| `podSecurityContext` | RuntimeDefault seccomp, uid/gid 1000, non-root | Homelab standard pod security. |
| `securityContext` | RO rootfs, no privilege escalation | Container security context. |
| `podAntiAffinity` | `true` | At most one replica per node. |
| `ports` | `http` 3000 | Container ports. |
| `envFromConfigMap` | `homepage-env` | PUID/PGID/TZ/allowed-hosts. |
| `configMaps` | `homepage-env`, `homepage-config` | Env + the four dashboard config files. Both covered by `checksum/config`. |
| `externalSecrets` | `homepage-secret` | 1Password Connect ref → the ESO-rendered `services.yaml` (embeds widget tokens). |
| `resources` | 128–256Mi / 100m–1000m | Requests/limits. |
| `readinessProbe` / `livenessProbe` | httpGet `/` :3000 | Health checks. |
| `volumes` / `volumeMounts` | 2 emptyDirs + config + secret | See the note about lists above. |
| `initContainers` | `[]` | None. |
| `services` | `homepage` ClusterIP :3000 | Service list. |
| `ingressRoute` | `homepage.example.com` :3000 | Traefik route, authentik + default-headers middlewares. |
| `serviceMonitor.enabled` | `false` | homepage exposes no metrics endpoint. |
| `persistentVolumeClaims` / `persistentVolumes` | `[]` | None. |
| `extraLabels` | `{}` | Extra labels merged into the standard label block. |

## Verify locally

```bash
helm dependency build charts/homepage
helm lint charts/homepage
# renders on defaults alone:
helm template homepage charts/homepage | kubeconform -strict -ignore-missing-schemas -skip IngressRoute
```

> `hack/diff-migration.sh homepage` does **not** work for this app: it compares
> `install/` against the chart alone, and homepage's objects are split across the
> chart *and* `pre-install/`. The migration was verified by rendering both sources
> together against the pre-migration tree from git — see the migration notes above.
