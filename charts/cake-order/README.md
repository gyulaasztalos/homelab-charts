# cake-order

Public cake-ordering web app (`asztalosgyula/cake-order`, anitatortai.hu). Rendered
through the [`common`](../common) library chart — **the CORE workload only**.

## Scope: chart vs. post-install

cake-order is a multi-resource app. The chart renders only the core workload; the
resource types `common` does not model live in `apps/cake-order/post-install/`
(synced as a separate ArgoCD source):

| In the chart (core) | In `post-install/` (raw manifests) |
|---|---|
| app Deployment (+ gallery-prep initContainer) | CNPG `Database` (in `databases` ns) |
| Service, IngressRoute | `cloudflared` tunnel Deployment + its ExternalSecret |
| NFS gallery PV + PVC | migrate `Job` (PreSync hook) |
| postgres + app ExternalSecrets | purge `CronJob` |
| ServiceMonitor | two `NetworkPolicy` objects |
| | PrometheusRule |

Why `cloudflared` is a separate Deployment (not a sidecar): it is the sole
internet-facing component, kept as its own independently-policied, independently
scalable workload (its own NetworkPolicy; the tunnel token is mounted only in its
pod; currently `replicas: 0` until go-live). It reaches the app only via the
Service on :8000. `common` models one controller, so it stays a raw manifest.

## Notable details

- **Gallery initContainer.** `prepare-gallery` (ImageMagick) copies the NAS photos
  into a pod-local emptyDir at startup, renames them to their EXIF capture date and
  builds thumbnails, so the running app never touches NFS. It needs a writable
  `/tmp`, so it (only it) runs `readOnlyRootFilesystem: false` — hence the
  `no-read-only-root-fs` kube-linter waiver on the Deployment. The main container
  keeps a read-only rootfs.
- **Public, no Authentik.** The IngressRoute deliberately carries only
  `default-headers` (no authentik) — abuse control is in the app.
- **NFS gallery.** `ReadOnlyMany` PV/PVC (`cake-order-gallery`) on the NAS.

## post-install lint fixes

Made kube-linter clean as part of the migration (see PLAN.md "CI as a living
suite"): cloudflared gained a declared `containerPort: 2000` (liveness-port); the
migrate Job and purge CronJob gained resource requests/limits; the purge CronJob
carries a `job-ttl-seconds-after-finished` waiver (the ttl is intentional).

## Generic vs deployment values

The chart's [`values.yaml`](values.yaml) uses `example.com` placeholders; the real
hostnames/analytics id live in `apps/cake-order/values.yaml`. Migration verified:
all core content byte-identical to the original (only the standard label/annotation/
image-quote deltas + the intentional lint fixes).

## Verify locally

```bash
helm dependency build charts/cake-order
helm lint charts/cake-order
helm template cake-order charts/cake-order | kubeconform -strict -ignore-missing-schemas -skip IngressRoute
```
