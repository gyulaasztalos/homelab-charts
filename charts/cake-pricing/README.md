# cake-pricing

Internal cake-pricing / quoting web app (`asztalosgyula/cake-pricing`), behind
Authentik. Rendered through the [`common`](../common) library chart — **the CORE
workload only**.

## Scope: chart vs. post-install

| In the chart (core) | In `apps/cake-pricing/post-install/` (raw manifests) |
|---|---|
| app Deployment | CNPG `Database` (in `databases` ns) |
| Service, IngressRoute | `cake-pricing-headers` Middleware (in `traefik` ns) |
| postgres/intake/calendar ExternalSecrets | migrate `Job` (PreSync hook) |
| ServiceMonitor | price-sync `CronJob` |
| | smtp ExternalSecret (used only by the CronJob) |
| | PrometheusRule |

## Notable details

- **Custom Service selector.** The Service selects on `app.kubernetes.io/name` +
  `app.kubernetes.io/component` (not the chart default `app: <name>`). The
  migrate/price-sync Job pods also carry `app: cake-pricing`, so keying on the web
  `component` keeps them out of the Service endpoints — otherwise the
  ServiceMonitor would scrape a Job pod's :8000 and report the target down.
  Set via `services[].selector`.
- **Two IngressRoute routes.** `/calendar/` (priority 20) skips Authentik — calendar
  apps can't do browser forward-auth, and the path embeds an unguessable
  `CALENDAR_TOKEN` the app verifies — keeping only the custom headers middleware.
  The catch-all (priority 10) is `authentik` + `cake-pricing-headers`. Uses
  `common` >= 0.4.0 (`pathPrefix` + per-route `middlewares`).
- **`cake-pricing-headers` Middleware** is a per-app copy of `default-headers` with
  `referrerPolicy: same-origin` (so the forms' `return_to` works). It lives in the
  `traefik` namespace, so it's a post-install raw manifest.

## post-install lint fixes

The migrate Job gained resource requests/limits (unset-cpu/memory); the price-sync
CronJob carries a `job-ttl-seconds-after-finished` waiver (the ttl is intentional).

## Generic vs deployment values

The chart's [`values.yaml`](values.yaml) uses `example.com` placeholders; the real
hostname lives in `apps/cake-pricing/values.yaml`. Migration verified: the Service
(custom selector) and IngressRoute (both routes) are byte-identical to the original;
remaining deltas are the standard label/image-quote cosmetics + the intentional
lint fixes.

## Verify locally

```bash
helm dependency build charts/cake-pricing
helm lint charts/cake-pricing
helm template cake-pricing charts/cake-pricing | kubeconform -strict -ignore-missing-schemas -skip IngressRoute
```
