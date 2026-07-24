# influxdb

InfluxDB 2.x OSS (`influxdb`, official image) — long-term store for Home Assistant
sensor data (fridge/freezer temperatures / HACCP), browsed in Grafana. Rendered
through the [`common`](../common) library chart.

Requires **`common` >= 0.4.0** for the IngressRoute `pathPrefix` + `middlewares: []`
pattern.

## Controller — StatefulSet

influxdb owns a **writable RWO Longhorn volume** (its TSM data at
`/var/lib/influxdb2`), so per the homelab bright-line rule it is a **StatefulSet**
with a `volumeClaimTemplate` (`influxdb-data` → `influxdb-data-influxdb-0`, RWO
longhorn 10Gi).

## First-boot auto-setup

`DOCKER_INFLUXDB_INIT_MODE=setup` makes the entrypoint create the org (`homelab`),
the bucket (`homeassistant`, 45-day retention) and the admin user + token on the
**first** boot; on later boots it detects existing data and skips setup. The admin
username/password/token come from the `influxdb-init` ExternalSecret (1Password
item `influxdb`); the org/bucket/retention are plain env literals.

Security context is deliberately minimal, matching the original: the official
image runs as its own uid/gid 1000, so only `seccompProfile` and `fsGroup: 1000`
(to make the Longhorn volume group-writable) are pinned — the container is not
forced non-root and the rootfs is not read-only (influxdb writes).

## Machine-facing API route

The IngressRoute has **two routes on one host** (0.4.0 pattern, like apprise):
`/api` (PathPrefix, **no** middlewares, priority 20) for HA + Grafana writes/reads
that carry tokens and have no browser session, and the catch-all UI route
(priority 10) behind authentik + default-headers.

## ServiceMonitor cardinality control

The endpoint carries `metricRelabelings` that **drop** the high-cardinality
`path` series InfluxDB templates across every UI static asset (a full 12-bucket
histogram per `.js`/`.png`/`.wasm`/… × user_agent). The kept `/api/v2/*` paths are
exactly what the alert rules query. rPi-critical.

## Scope boundary

`apps/influxdb/post-install/` (a kustomize dir, separate ArgoCD source) owns
everything that is not the core workload:

| Object | Notes |
|---|---|
| 2 Grafana dashboards | Generated from JSON (fridge-HACCP + OSS metrics). |
| `grafana-datasource` ExternalSecret | Wires Grafana → influxdb (reuses the admin token). Observability glue, so it lives here, not in the chart with the app's own `influxdb-init` secret. |
| `influxdb-alerts` PrometheusRule | Availability / error-rate / write-heartbeat / resource alarms. |
| HACCP backup-alert Job + template | A **PostSync** Job runs `influx apply` to install an InfluxDB-native Flux **Task** (a second, DB-side HACCP alarm independent of the Home Assistant automation). The Job and its template ConfigMap are in the same kustomization, so the hashed-name reference rewrites correctly. |

> `ServerSideApply=true` and `sync-wave: "-1"` are preserved on the Application —
> the dashboards are large, and influxdb should come up before its consumers.

## Migration notes

Verified byte-identical against the pre-migration manifests: the StatefulSet
container (env, probes, security context), the `influxdb-data` volumeClaimTemplate,
the IngressRoute routes, the ServiceMonitor endpoints (metricRelabelings), both
Grafana dashboards, and both ExternalSecrets. Intentional/benign deltas:

- Deployment stays a StatefulSet (no controller-kind change — it already was one);
  the static labels get the standard block; image string quoted.
- The chart adds `podAntiAffinity` (the original omitted it — harmless for a
  single replica, consistent with the other migrated StatefulSets) and makes the
  ServiceMonitor `namespaceSelector` explicit (was implicitly the same namespace).
- **The HACCP alert template changed on purpose** (see below), so its generated
  ConfigMap hash changes and the Job's volume reference follows it.

## Out-of-scope fix: HACCP alert readability

While migrating, two problems in the InfluxDB-native HACCP alert (the Flux Task in
`post-install/haccp-backup-alert-template.yml`) were fixed:

1. **Friendly names** — the alert body used the raw Zigbee `entity_id`
   (`0x58e6c5fffe0f58b0_temperature_3`). A `dict` maps each probe to its appliance
   name (LG Fridge / Electrolux Fridge / LG Freezer / Electrolux Freezer), with a
   fallback to the raw id for any unmapped probe.
2. **Rounded temperature** — the averaged reading was a long float;
   `round2 = (x) => math.round(x: x * 100.0) / 100.0` trims it to 2 decimals
   (handles negative freezer temps correctly).

The Task is re-applied on every ArgoCD sync by the PostSync Job, so the fix takes
effect on the next sync.

## Values

| Key | Default | Description |
|-----|---------|-------------|
| `name` | `influxdb` | App name — drives resource names, labels, namespace. |
| `image.repository` | `influxdb` | Official InfluxDB 2.x OSS image. |
| `image.tag` | `2.9` | Minor-pinned; Renovate-managed (major = PR only). |
| `controller.type` | `statefulset` | Owns a writable RWO volume ⇒ StatefulSet. |
| `volumeClaimTemplates` | `influxdb-data` RWO longhorn 10Gi | → `influxdb-data-influxdb-0` at `/var/lib/influxdb2`. |
| `serviceAccount.create` | `false` | Runs under the namespace `default` SA. |
| `podSecurityContext` | seccomp + `fsGroup: 1000` only | Image runs as its own uid. |
| `securityContext` | `allowPrivilegeEscalation`/`privileged` false | RW rootfs (influxdb writes). |
| `podAntiAffinity` | `true` | At most one replica per node. |
| `ports` | `http` 8086 | Container port. |
| `env` | INIT_MODE/ORG/BUCKET/RETENTION + admin creds | Auto-setup; creds from `influxdb-init`. |
| `externalSecrets` | `influxdb-init` | 1Password → admin username/password/token. |
| `readinessProbe` / `livenessProbe` | httpGet `/health` :8086 | Health checks. |
| `services` | `influxdb` ClusterIP :8086 | Service list. |
| `ingressRoute` | 2 routes (see above) | `/api` unauthenticated + guarded UI. |
| `serviceMonitor.enabled` | `true` | `/metrics` with cardinality-drop relabelings. |
| `initContainers` / `extraContainers` | `[]` | None. |
| `persistentVolumeClaims` / `persistentVolumes` | `[]` | None (RWO via VCT). |

## Verify locally

```bash
helm dependency build charts/influxdb
helm lint charts/influxdb
helm template influxdb charts/influxdb | kubeconform -strict -ignore-missing-schemas -skip IngressRoute
bash hack/diff-charts.sh
```
