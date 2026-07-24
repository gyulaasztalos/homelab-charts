# transmission

Transmission BitTorrent client (LinuxServer.io, `lscr.io/linuxserver/transmission`)
with the [Flood](https://github.com/johman10/flood-for-transmission) web UI.
Rendered through the [`common`](../common) library chart.

Requires **`common` >= 0.5.0** for the LoadBalancer Service fields.

## Controller — StatefulSet

transmission owns a **writable RWO Longhorn `/config` volume**, so per the homelab
bright-line rule it is a **StatefulSet** with a `volumeClaimTemplate`
(`config-transmission-0`), not a Deployment. The original was a Deployment +
RollingUpdate on that RWO volume — the multi-attach flap this fixes.

The **downloads** live on a separate **static RWX NFS** PV/PVC (`transmission-data`,
`nfs-share` → `unvr-pro:/private`), mounted alongside via `subPath` (`/downloads`,
`/watch`). It is shared storage, not a per-replica owned volume, so it stays a
static PV/PVC — the chart renders both. (This mixed "VCT + static NFS RWX" shape is
the pattern paperless will reuse.)

> **Migration = regenerate, not migrate.** The `config` PVC is renamed
> (`transmission-config` → `config-transmission-0`) and the old one is pruned on
> cutover. The initContainer re-downloads the Flood UI and re-copies `settings.json`
> from the Secret on every start, so only transmission's **active-torrent session
> state** is lost — you re-add active torrents. The **downloaded data on NFS is
> untouched** (same `transmission-data` PVC + `Retain` PV).

## LoadBalancer services (why 0.5.0)

Two MetalLB `LoadBalancer` Services share one IP (`metallb.io/allow-shared-ip`),
split TCP (peer + rpc) / UDP (peer), with `externalTrafficPolicy: Local` to
preserve the peer source IP. `common.service` gained optional `loadBalancerIP` +
`externalTrafficPolicy` in 0.5.0 to render these — standard Service fields, so
they stay in the chart rather than an escape hatch. transmission is reached at the
LB IP (no Traefik IngressRoute).

## LinuxServer.io security pattern

Same as flexget/apprise: PUID/PGID drop privileges in-image, the pod pins only
`fsGroup: 119` (the transmission group), and the two kube-linter waivers
(`no-read-only-root-fs`, `run-as-non-root`) are preserved — the get-flood
initContainer also `apk add`s tools, needing root + a writable rootfs.

## Configuration

`transmission-config` ConfigMap (PUID/PGID/TZ/whitelists) via `envFrom`; the RPC
`USER`/`PASS` from the ExternalSecret. The full `settings.json` is rendered by the
ExternalSecret (ESO templates the credentials into it) and seeded into `/config` by
the initContainer. The notification script (torrent-done → Apprise) is a chart
ConfigMap file mounted 0755. Both ConfigMaps are chart-owned, so `checksum/config`
rolls the pod on change.

## Migration notes

Verified byte-identical against the original: both ConfigMaps' data (incl. the
notification script), the ExternalSecret spec (`settings.json` + refs), **both
LoadBalancer Services**, the NFS PV and the `transmission-data` PVC, and the whole
pod spec (initContainer + main container). Intentional deltas only:
Deployment→StatefulSet, `config` static PVC→volumeClaimTemplate, ConfigMap
hash→static (+`checksum/config`), image quoting, standard label blocks.

## Verify locally

```bash
helm dependency build charts/transmission
helm lint charts/transmission
helm template transmission charts/transmission | kubeconform -strict -ignore-missing-schemas
```
