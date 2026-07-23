# apprise

[Apprise API](https://github.com/caronc/apprise-api) (LinuxServer.io build) — the
homelab's notification fan-out hub. Services POST to it and it dispatches to
Telegram / email / Discord / Pushover by tag. Ships a `mailrise` sidecar so
appliances that can only send **email** reach the same fan-out. Rendered through
the [`common`](../common) library chart.

Requires **`common` >= 0.4.0** for `extraContainers`, `ingressRoute` `pathPrefix`,
and the corrected `middlewares: []` semantics.

## Controller

**Deployment.** Everything it holds lives in two emptyDirs; config comes from a
Secret and a ConfigMap. No owned PVC, no node-local hardware.

## Two containers

| Container | Role |
|---|---|
| `apprise` | The API. HTTP on :8000, `/status` health, `/metrics` for Prometheus. |
| `mailrise` | SMTP server on :8025. Accepts a mail, looks the sender up in `mailrise.conf`, and re-posts it into apprise with the matching tag. |

The sidecar is reached from outside the cluster through an **`IngressRouteTCP`**
that is *not* in this chart — see below.

Note the asymmetric security contexts, both preserved from the original: the
LinuxServer.io main image drops privileges itself via `PUID`/`PGID` env vars, so
the pod only pins `fsGroup` and the main container is not forced non-root (hence
the `run-as-non-root` kube-linter waiver). `mailrise` is an ordinary image and
does get the full treatment — non-root uid 999, read-only rootfs, all capabilities
dropped.

`mailrise` is pinned to `:latest` upstream, which is why the Deployment carries a
`latest-tag` waiver. Renovate cannot track a floating tag, so this one image is
deliberately outside Renovate's control.

## The auth-critical route table

Three routes on one host, ranked by priority — and **two of them must have no
authentication**:

| Route | Priority | Middlewares |
|---|---|---|
| `Host(…) && PathPrefix(/notify)` | 25 | **none** |
| `Host(…) && PathPrefix(/apprise)` | 20 | **none** |
| `Host(…)` | 10 | authentik + default-headers |

`/notify` and `/apprise` are the **machine-facing API**. Every notification
producer in the cluster — ddns-updater, flexget, grafana, alertmanager, restic,
watchtower, unattended-upgrades, transmission — POSTs there with no browser
session. Putting authentik forward-auth in front of them would 302 each producer
to a login page and silently break notifications cluster-wide. The catch-all
route is the human-facing UI and *does* get the default middlewares.

This app is the reason `common` 0.4.0 exists:

- **`pathPrefix`** — the match was previously hardcoded to `Host(…)` alone, so
  the three routes could not be distinguished.
- **`middlewares: []` now really means none.** Helm's `default` treats an empty
  list as empty, so `[] | default (authentik, default-headers)` returned the
  defaults — the documented "set `[]` to drop auth" silently did the opposite.
  `hasKey` distinguishes an absent key from an explicitly empty one.
  `hack/test-toggles.sh` asserts both directions, and was verified to fail
  against the old template.

Higher priority wins in Traefik, so the two prefix routes must outrank the
catch-all.

## Scope boundary

`apps/apprise/post-install/` (a kustomize dir in the ArgoCD repo, synced as a
separate Application source) owns:

| Object | Why it's out of the chart |
|---|---|
| `IngressRouteTCP` (`mailrise`) | Traefik TCP router on the `mailsecure` entryPoint. `IngressRouteTCP` is deliberately **not** modelled in `common`: mailrise is its only consumer in the homelab, apprise functions without it, and a template for one caller would be dead weight in every other chart. |
| `PrometheusRule` (`apprise-rules`) | Auxiliary observability asset — the standing scope-boundary rule. |

## Generic chart vs. deployment values

This chart's [`values.yaml`](values.yaml) holds generic example config: a single
Telegram URL in the ExternalSecret template and `apprise.example.com`. The
deployment config lives in `apps/apprise/values.yaml` with the real fan-out table
(Telegram, iCloud SMTP, Discord, Pushover) and all nine 1Password references.

## Migration notes

Verified identical against the pre-migration manifests: the **IngressRoute spec**
(including the route table above), the **Service spec**, the **ServiceMonitor
spec**, and the **entire mailrise sidecar**. Remaining deltas:

- ServiceMonitor renamed `apprise-exporter` → `apprise`, matching nut-exporter and
  unbound. Expect a brief metrics gap at cutover.
- The Service, IngressRoute, ExternalSecret and ConfigMap gain the standard
  five-label block — the hand-written manifests carried none. Cosmetic; none of
  them is selected by label.
- `mailrise.conf` changes from a `|-` to a `|` block scalar, so the ConfigMap
  value gains one trailing newline. The file content is otherwise byte-identical.
  Harmless for a YAML config, and not worth a chomp-control knob in `common`.
- The pod template gains `checksum/config`. The original `mailrise-config` was a
  plain manifest, not a `configMapGenerator`, so it had **no** hash and edits did
  **not** roll the pod. Now they do — a deliberate improvement, not a regression.

## Values

| Key | Default | Description |
|-----|---------|-------------|
| `name` | `apprise` | App name — drives resource names, labels, namespace. |
| `image.repository` | `lscr.io/linuxserver/apprise-api` | Main container image. |
| `image.tag` | `v1.2.0-ls193` | Image tag — single source of truth; Renovate-managed. |
| `controller.type` | `deployment` | Stateless ⇒ Deployment. |
| `controller.annotations` | 3 kube-linter waivers | RO-rootfs, run-as-non-root, latest-tag. |
| `serviceAccount.create` | `false` | Runs under the namespace `default` SA. |
| `podSecurityContext` | `fsGroup: 1000` only | LinuxServer.io images drop privileges via PUID/PGID. |
| `securityContext` | `allowPrivilegeEscalation: false` | Main container. |
| `podAntiAffinity` | `true` | At most one replica per node. |
| `ports` | `http` 8000 | Main container port. |
| `env` | PUID/PGID/TZ/stateful-mode/attach-size | Plain env vars, no envFrom. |
| `configMaps` | `mailrise-config` | SMTP-sender → apprise-tag routing table. |
| `externalSecrets` | `apprise-config` | 1Password refs → `apprise.yml` (the notification URLs). |
| `resources` | 96–256Mi / 100–200m | Main container. |
| `readinessProbe` / `livenessProbe` | httpGet `/status` :8000 | Health checks. |
| `volumes` / `volumeMounts` | 2 emptyDirs + secret + configMap | `attachments`, `config`. |
| `extraContainers` | `mailrise` sidecar | SMTP :8025 → apprise. |
| `services` | `apprise` ClusterIP :8000, :8025 | Service list. |
| `ingressRoute` | 3 routes (see above) | Two unauthenticated API prefixes + guarded UI. |
| `serviceMonitor.enabled` | `true` | Scrapes `/metrics` on the http port. |
| `persistentVolumeClaims` / `persistentVolumes` | `[]` | None. |

## Verify locally

```bash
helm dependency build charts/apprise
helm lint charts/apprise
helm template apprise charts/apprise | kubeconform -strict -ignore-missing-schemas -skip IngressRoute
bash hack/test-toggles.sh     # asserts the middlewares/pathPrefix semantics
bash hack/diff-charts.sh      # regression vs the last proven render
```
