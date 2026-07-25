# cake-pricing

Internal cake-pricing / quoting web app (`asztalosgyula/cake-pricing`), behind
Authentik. Rendered through the [`common`](../common) library chart.

Requires **`common` >= 0.6.0** (`jobs`, `cronJobs`, `database`, `middlewares`).

## Dependencies

- **PostgreSQL (required).** The app cannot run without its database. The chart
  provisions one on the shared **CNPG** cluster — a `Database` (`cake-pricing-db`)
  on cluster `postgres` in the `databases` namespace — via the `database:` values
  block. The managed role `cake-pricing` is provisioned on the cluster
  (`apps/cnpg/.../postgresql-cluster.yaml`) and its password comes from the
  `cake-pricing-postgres-password` 1Password item. To run against a different
  Postgres, set `database: {}` and point `DB_HOST` elsewhere.
- **External Secrets Operator + 1Password Connect** back the four ExternalSecrets
  (postgres / intake / calendar / smtp). Drop them (`externalSecrets: []`) and
  provide the Secrets yourself to run without ESO.

## Ingress (optional)

The chart renders a Traefik `IngressRoute` + the `cake-pricing-headers`
`Middleware` by default, but Traefik is **not** a hard dependency: set
`ingressRoute.enabled: false` and `middlewares: []` to render neither and front
the Service with your own ingress. Likewise `serviceMonitor.enabled: false`
drops the Prometheus `ServiceMonitor`.

## Scope: chart vs. post-install

As of `common` 0.6.0 the chart renders **every mandatory resource**; only the
PrometheusRule (observability) stays in `apps/cake-pricing/post-install/`.

| In the chart | In `apps/cake-pricing/post-install/` |
|---|---|
| app Deployment, Service, IngressRoute | PrometheusRule |
| 4 ExternalSecrets (postgres/intake/calendar/smtp) | |
| ServiceMonitor | |
| migrate `Job` (PreSync hook) — `jobs:` | |
| price-sync `CronJob` — `cronJobs:` | |
| CNPG `Database` (`databases` ns) — `database:` | |
| `cake-pricing-headers` `Middleware` (`traefik` ns) — `middlewares:` | |

## Notable details

- **Batch jobs on the app image.** The migrate `Job` and price-sync `CronJob`
  render via `common`'s `jobs:`/`cronJobs:`, with their image **defaulted from
  `image.tag`** — no separately-maintained tag. Their pods carry
  `app.kubernetes.io/name` but **not** `app`, so they never enter the Service's
  endpoints (no spurious `TargetDown`). The Service *also* uses a custom
  name+component selector as belt-and-suspenders.
- **Two IngressRoute routes.** `/calendar/` (priority 20) skips Authentik —
  calendar apps can't do browser forward-auth, and the path embeds an unguessable
  `CALENDAR_TOKEN` the app verifies — keeping only `cake-pricing-headers`. The
  catch-all (priority 10) is `authentik` + `cake-pricing-headers`.
- **`cake-pricing-headers` Middleware** is a per-app copy of `default-headers` with
  `referrerPolicy: same-origin` (so the forms' `return_to` works). It targets the
  `traefik` namespace but is rendered by the chart (via `middlewares:`) so it syncs
  as one unit with the IngressRoute that references it.

## Migration notes

Cut over from post-install to the chart under `common` 0.6.0. The migrate Job,
price-sync CronJob, CNPG Database and headers Middleware render byte-identical to
the originals apart from the standard label block, stripped comments, an explicit
`imagePullPolicy`, and self-describing (object-name) container names.

## Verify locally

```bash
helm dependency build charts/cake-pricing
helm lint charts/cake-pricing
helm template cake-pricing charts/cake-pricing | kubeconform -strict -ignore-missing-schemas -skip IngressRoute
kube-linter lint ../ArgoCD/apps/cake-pricing/post-install
```
