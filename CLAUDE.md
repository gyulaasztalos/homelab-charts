# homelab-charts

Helm charts for the HomeLab k3s cluster, consumed by ArgoCD. Replaces the
hand-written `apps/<app>/install` kustomize manifests in the sibling
[ArgoCD](https://github.com/gyulaasztalos/ArgoCD) repo (checked out at `../ArgoCD`).

**Work spans two repos.** A migration is only complete when both are changed:
the chart here, and the `Application` + tailored `values.yaml` there.
`PLAN.md` (gitignored, local-only) holds the full project plan and sequencing.

## Architecture: library chart + thin wrappers

```
charts/common/            type: library — ALL templating logic, as named templates
charts/<app>/
  Chart.yaml              dependency: common, repository: file://../common
  values.yaml             GENERIC example config (example.com, placeholder refs)
  templates/main.yaml     one line: {{- include "common.all" . }}
```

`common.all` emits, in kustomize order: ExternalSecrets → ConfigMaps → PVCs →
ServiceAccount → controller → Services → IngressRoute → ServiceMonitor. Each
helper emits its own leading `---` and renders nothing when disabled.

A wrapper chart should contain **no templates of its own** — that is the escape
hatch, used only when an app genuinely needs a one-off object.

### Controller selection (bright-line rule, not "stateful vs not")

```
node-local hardware (host devices)?      → daemonset
else writes to a PVC it owns (RWO)?      → statefulset (volumeClaimTemplate)
else                                     → deployment
```

RWO PVC on a Deployment + RollingUpdate causes Longhorn multi-attach flaps.

## Values contract (charts/common)

List-shaped, so one workload can emit several objects:

- `services:` — a **list**; per item `name`/`type`/`clusterIP`/`selector`/`ports`,
  `enabled: false` skips just that one.
- `ingressRoute.routes:` — a **list** inside ONE IngressRoute object, so several
  hosts/backends share a single route object. Omit `ingressRoute` entirely for
  metrics-only apps.
- `configMaps:`, `externalSecrets:`, `persistentVolumes:`,
  `persistentVolumeClaims:`, `volumeClaimTemplates:` — all lists.

Defaults encoded: `podAntiAffinity` on, authentik + default-headers middlewares,
`traefik-external` ingressClass, `longhorn` storageClass, the five-label block
(`app` + four `app.kubernetes.io/*`, all set to the app name).

### The `false | default true` trap

Helm's `default` treats `false` as empty, so `false | default true` is **true**.
Every default-on boolean must be written:

```gotemplate
{{- if ne (.Values.podAntiAffinity | toString) "false" }}
```

`hack/test-toggles.sh` is the regression guard (runs in CI) and asserts both
directions — off when forced false, *and* on by default, so the test can't go
vacuous.

### Immutable selectors on in-place migration

A DaemonSet/StatefulSet `spec.selector` is immutable. When migrating an app that
keeps its controller kind, set `controller.selectorLabels` to reproduce the
original selector exactly (see `charts/vcgen-exporter/values.yaml`), otherwise
the apply fails. The pod template always carries the full label set.

### Config change → pod roll

kustomize's `configMapGenerator` hashed ConfigMap names. Helm uses static names,
so `common.podTemplateMeta` stamps `checksum/config` (sha256 of rendered
ConfigMaps) on the pod template. ExternalSecrets are deliberately excluded — the
manifest is just a reference; the value rotates in 1Password without changing it.

## Scope boundary: what is NOT in the chart

The chart owns the **core workload only**. These move to
`../ArgoCD/apps/<app>/post-install/` (a kustomize dir, synced as an extra
Application source): Grafana dashboard ConfigMaps, PrometheusRules, one-off Jobs,
EndpointSlices, extra RBAC. Keeps dashboard JSON out of values.yaml.

Domain-specific config (real hostnames, secret refs) lives in
`../ArgoCD/apps/<app>/values.yaml` — and that file carries the *complete* value
set including unchanged defaults, so it reads as the full deployment contract.
The chart's own `values.yaml` stays generic and must render validly on its own.

**No secret material in this repo, ever.** Charts render ExternalSecret
*references* to the in-cluster `onepassword-connect` ClusterSecretStore.

## Verification (every chart change — mandatory)

All tooling is installed locally (helm, kubeconform, yq v4, kubectl, kube-linter,
pluto), so the full CI suite can be reproduced before pushing.

```bash
helm dependency build charts/<app>
helm lint charts/<app>
helm template charts/<app> | kubeconform -strict -summary -ignore-missing-schemas \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  -skip IngressRoute
bash hack/test-toggles.sh
helm template charts/<app> > /tmp/r.yaml && kube-linter lint /tmp/r.yaml && pluto detect-files -d /tmp
```

`-skip IngressRoute` is a documented exception: the public CRD catalog schema is
stale and rejects the valid `spec.ingressClassName`.

### Regression gate — the one that matters for `charts/common`

An app that has been cut over **and verified in production** is proven; its chart
render is the baseline from then on, and the old `install/` manifests are dead.
So every later change is checked as *previous proven render → new render*:

```bash
hack/diff-charts.sh              # vs HEAD
hack/diff-charts.sh <ref> [chart...]
```

Renders every chart at `<ref>` and from the working tree, diffing both the
**generic** render (chart's own values) and the **deployed** render (layered with
`<ArgoCD>/apps/<app>/values.yaml`). Run it after **any** `charts/common` edit: a
wrapper change can only break its own app, but a library change re-renders every
proven app at once. Confirm every chart listed as `CHANGED` is one you meant to
touch — anything else is a leak.

### Migration gate (local only, ONCE per app)

Only while both representations exist — before the app is cut over. Superseded by
`diff-charts.sh` the moment the migration is verified in prod.

```bash
hack/diff-migration.sh <app> [path-to-ArgoCD-repo]
```

Renders old kustomize vs. new chart, normalizes and diffs per resource. Only
**intentional** deltas may remain (Deployment→StatefulSet, static PVC→
volumeClaimTemplate, relocated dashboards/rules). Review every hunk, *then* the
old `install/` dir may be deleted. Deliberately not in CI — `install/` is deleted
after cutover, so a committed snapshot would rot into a false gate.

### CI as a living suite

When troubleshooting surfaces a new failure mode, add a regression check to CI (a
values fixture + render assertion that would have caught it) — not just a local
fix. `hack/test-toggles.sh` exists because of exactly that.

## ArgoCD wiring (per app)

Multi-source `Application` in `../ArgoCD/apps/<app>/application.yaml` — see
`apps/vcgen-exporter/application.yaml` as the reference (three sources: config
ref, chart, post-install):

```yaml
sources:
  - repoURL: 'https://github.com/gyulaasztalos/ArgoCD.git'
    targetRevision: main
    ref: config
  - repoURL: 'https://github.com/gyulaasztalos/homelab-charts.git'
    targetRevision: main
    path: charts/<app>
    helm:
      valueFiles:
        - $config/apps/<app>/values.yaml
```

`targetRevision: main` for the chart source is intentional — the two repos are
co-owned and evolve together. `file://../common` resolves because ArgoCD checks
out the whole repo for the chart source.

## Conventions

- No `appVersion` in `Chart.yaml` — `image.tag` in values.yaml is the single
  source of truth, Renovate-managed via a `# renovate: datasource=docker` comment
  directly above the `tag:` line. `datasource=docker` covers every OCI registry
  (ghcr.io, lscr.io, quay.io, Docker Hub) — the host is read from `depName`.
- A **floating `:latest` tag** (an image with no pinned release, e.g. mailrise)
  needs three things together: a `latest-tag` kube-linter waiver, no Renovate
  annotation (Renovate can't track it), and — the one easy to forget —
  `imagePullPolicy: Always`. With `IfNotPresent` the node serves its first cached
  `:latest` forever, so the pull policy is the only thing that makes the tag float.
- `Chart.lock` and vendored `charts/*/charts/` are **untracked build artifacts** —
  `helm dependency build` regenerates them, and it works fine with no lock
  present (verified: identical render). Keeping them out means a stale pin can
  never be committed. A tracked lock pinning `common 0.1.0` would fail every
  chart's render with *"can't get a valid version for dependency common"* the
  moment `common` is bumped — including charts you did not touch, since ArgoCD
  runs `dependency build` too.
- **`.gitignore` cannot take trailing comments** — git treats the whole line as
  the pattern. Three rules were silently dead because of this. Keep every comment
  on its own line.
- **Bumping `charts/common` is a 7-step change, not a 1-file change.** A new knob
  goes into all 6 generic *and* all 6 tailored `values.yaml` (even for apps that
  will never use it — each file claims to list every value the library
  understands), and every wrapper's `common` floor moves to the new version. The
  failure mode is silent: an undeclared knob in values.yaml against an older
  `common` is ignored, not rejected. Also check Renovate coverage for
  verbatim-passthrough lists, and prove additivity with `hack/diff-charts.sh`.
  Full checklist in `PLAN.md` → "`common` versioning".
- One app cut over and confirmed healthy in-cluster before starting the next.
- Chart README is updated as the **final** step of each migration.
