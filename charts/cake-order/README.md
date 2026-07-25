# cake-order

Public cake-ordering web app (`asztalosgyula/cake-order`, anitatortai.hu). Rendered
through the [`common`](../common) library chart.

Requires **`common` >= 0.6.0** (`jobs`, `cronJobs`, `database`).

## Dependencies

- **PostgreSQL (required).** The chart provisions the app's database on the shared
  **CNPG** cluster — a `Database` (`cake-order-db`) on cluster `postgres` in the
  `databases` namespace — via the `database:` values block. The managed role
  `cake-order` and its password (`cake-order-postgres-password` 1Password item) are
  provisioned on the cluster. Set `database: {}` + repoint `DB_HOST` to use your own.
- **External Secrets Operator + 1Password Connect** back the three ExternalSecrets
  (postgres / app / tunnel).

## Public access & ingress (optional)

Public traffic reaches cake-order **only** through the `cloudflared` tunnel
(outbound-only; no inbound ports, no exposed home IP). The internal LAN route is a
Traefik `IngressRoute` with `default-headers` (no Authentik — abuse control is in
the app). Both are optional at the chart level: `ingressRoute.enabled: false` drops
the LAN route; `cloudflared.enabled: false` drops the tunnel.

## Scope: chart vs. post-install

As of `common` 0.6.0 the chart renders **every mandatory resource**; only the
PrometheusRule stays in `apps/cake-order/post-install/`.

| In the chart | how |
|---|---|
| app Deployment (+ gallery-prep initContainer), Service, IngressRoute | core |
| NFS gallery PV + PVC | core |
| postgres / app / tunnel ExternalSecrets | `externalSecrets:` |
| ServiceMonitor | core |
| migrate `Job` (PreSync) · purge `CronJob` | `common` `jobs:` / `cronJobs:` |
| CNPG `Database` (`databases` ns) | `common` `database:` |
| `cloudflared` tunnel `Deployment` | **per-chart template** `templates/cloudflared.yaml` |
| two `NetworkPolicy` objects | **per-chart template** `templates/networkpolicy.yaml` |
| PrometheusRule | `post-install/` |

### Why cloudflared and the NetworkPolicies are per-chart templates

These are the **escape hatch** (`common`'s bright line). `cloudflared` is a *second*
workload with its own identity (`cake-order-cloudflared`, its own selector,
`replicas: 0` until go-live) — `common` models one controller, so a generic contract
doesn't fit, and at N=1 it isn't worth one. The two default-deny `NetworkPolicy`
objects are a bespoke security "DMZ" (a security-review go/no-go), also N=1. Both
live in `charts/cake-order/templates/` and lean on `common`'s name/label helpers.
Its image lives in **values** (`cloudflared.image`, Renovate-annotated) — a
hardcoded tag in a template would escape the customManager.

## Notable details

- **Gallery initContainer.** `prepare-gallery` (ImageMagick) copies the NAS photos
  into a pod-local emptyDir at startup, renames them to their EXIF capture date and
  builds thumbnails. It needs a writable `/tmp`, so it alone runs
  `readOnlyRootFilesystem: false` — hence the `no-read-only-root-fs` waiver; the main
  container keeps a read-only rootfs.
- **No spurious TargetDown.** The migrate/purge Job pods carry
  `app.kubernetes.io/name` but not `app`, so they never enter the Service endpoints
  (common 0.6.0). This is the fix for the `TargetDown` alert the old post-install
  manifests produced.

## Migration notes

Cut over from post-install to the chart under `common` 0.6.0. The Database renders
byte-identical (bar the standard label block); the migrate Job / purge CronJob only
the accepted deltas (stripped comments, explicit `imagePullPolicy`, container name,
dropped `app:` pod label). cloudflared + the NetworkPolicies render faithfully from
the per-chart templates.

## Verify locally

```bash
helm dependency build charts/cake-order
helm lint charts/cake-order
helm template cake-order charts/cake-order | kubeconform -strict -ignore-missing-schemas -skip IngressRoute
kube-linter lint ../ArgoCD/apps/cake-order/post-install
```
