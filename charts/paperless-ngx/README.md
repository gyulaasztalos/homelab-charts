# paperless-ngx

[paperless-ngx](https://github.com/paperless-ngx/paperless-ngx) document management
server (`ghcr.io/paperless-ngx/paperless-ngx`). Rendered through the
[`common`](../common) library chart.

Requires **`common` >= 0.5.0**.

## Controller — StatefulSet

paperless owns a **writable RWO Longhorn `data` volume** (scanned documents +
search index), so per the homelab bright-line rule it is a **StatefulSet** with a
`volumeClaimTemplate` (`data` → `data-paperless-ngx-0`, 1500Mi), not a Deployment.
The original was a Deployment + RollingUpdate on that RWO volume — the Longhorn
multi-attach flap this fixes. The single volume is split into `media/`
(documents/thumbnails) and `data/` (search index) by `subPath`; the database of
record is CNPG (see post-install), not this volume.

The **consume/export dropbox** lives on a separate **static RWX NFS** PV/PVC
(`paperless-ngx-consume`, `nfs-share-small` → `unvr-pro:/private`), mounted
alongside via `subPath` (`/consume`, `/export`). It is transient shared storage,
not a per-replica owned volume, so it stays a static PV/PVC — the chart renders
both. (Same "VCT + static NFS RWX" shape transmission established.)

> **Migration = Longhorn clone.** The precious `data` PVC is renamed
> (`paperless-ngx-data` → `data-paperless-ngx-0`) via a reversible Longhorn clone
> before cutover — see [MIGRATION-statefulset.md](../../../ArgoCD/apps/paperless-ngx/MIGRATION-statefulset.md).
> The NFS consume/export share is recreated by the chart (no data move); the CNPG
> database is not touched.

## Auth — in-app OIDC, not ingress forward-auth

Unlike most apps here, the IngressRoute carries **no authentik forward-auth
middleware** — only `paperless-ngx-headers`. paperless does its **own** OIDC login
against Authentik (`PAPERLESS_APPS` + the `oauth` ExternalSecret rendering the
`PAPERLESS_SOCIALACCOUNT_PROVIDERS` JSON), so auth is in-app, at priority 10.

## Configuration

`paperless-ngx-config` ConfigMap (USERMAP/timezone/OCR langs/DB host/URLs) via
`envFrom`. Four **ExternalSecrets** (onepassword-connect), all via `envFrom`:
postgres creds, the app `PAPERLESS_SECRET_KEY`, the Redis connection URL, and the
Authentik OIDC provider JSON. The post-consume notification script (document
consumed → Apprise) is a chart ConfigMap file mounted 0755. Both ConfigMaps are
chart-owned, so `checksum/config` rolls the pod on change; the ExternalSecrets are
deliberately excluded from the checksum (references, not values).

## Security pattern

paperless drops privileges via `USERMAP_UID`/`USERMAP_GID` (in the ConfigMap); the
pod pins only `fsGroup: 1000` and is **not** forced `runAsNonRoot`. The two
kube-linter waivers (`no-read-only-root-fs`, `run-as-non-root`) are preserved —
paperless writes work/temp dirs under its root filesystem and remaps to its own
user, so the rootfs cannot be read-only.

## Not in this chart (post-install)

Two objects `common` does not model live in
[`apps/paperless-ngx/post-install/`](../../../ArgoCD/apps/paperless-ngx/post-install)
(a separate ArgoCD source): the **CNPG `Database`** (in the `databases` ns) and the
**`paperless-ngx-headers` Traefik `Middleware`** (in the `traefik` ns).

## Migration notes

Verified byte-identical against the original: both ConfigMaps' data (incl. the
notification script), all four ExternalSecret specs, the NFS PV + `paperless-ngx-consume`
PVC, the Service, the IngressRoute, and the pod spec. Intentional deltas only:
Deployment→StatefulSet, `data` static PVC→volumeClaimTemplate, ConfigMap
hash→static (+`checksum/config`), image quoting, IngressRoute priority 10, standard
label blocks.

## Verify locally

```bash
helm dependency build charts/paperless-ngx
helm lint charts/paperless-ngx
helm template paperless-ngx charts/paperless-ngx | kubeconform -strict -ignore-missing-schemas
kube-linter lint ../ArgoCD/apps/paperless-ngx/post-install
```
