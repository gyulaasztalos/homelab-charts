# actual-budget

[Actual Budget](https://actualbudget.org) (`actualbudget/actual-server`, official
image) — local-first envelope budgeting, the YNAB replacement. Rendered through the
[`common`](../common) library chart.

Requires **`common` >= 0.6.0**.

## Storage — SQLite only, no CNPG

Actual has no external-database support. The budget engine runs in the browser;
the server is a sync/file store: `account.sqlite` (users, sessions) under
`/data/server-files` and one file per budget under `/data/user-files`. So there is
no `database:` block, and the Longhorn volume is the only state — backed up by the
Longhorn → NAS tier, not Barman.

## Controller — StatefulSet

Owns a writable RWO Longhorn volume, so per the bright-line rule it is a
**StatefulSet** with a `volumeClaimTemplate` (`actual-budget-data` →
`actual-budget-data-actual-budget-0`, RWO longhorn 1Gi) mounted at `/data`.
SQLite is single-writer: keep `replicas: 1`.

The image creates an `actual` user (uid/gid 1001) and owns `/data` with it but
does **not** switch to it (`USER` is never set), so the pod pins
`runAsUser`/`runAsGroup`/`fsGroup: 1001` itself. Root filesystem is read-only;
`/tmp` is an `emptyDir`.

The image sets `NODE_OPTIONS=--max_old_space_size=8192`, far above the pod's
memory limit — V8 would not collect before the cgroup OOM-kills it. `env`
overrides it with a heap cap below the limit.

## Login — native OIDC, enforced

Actual signs users in itself against Authentik (`ACTUAL_LOGIN_METHOD=openid`,
`ACTUAL_OPENID_ENFORCE=true`), so the IngressRoute carries **no** authentik
forward-auth middleware. The client secret comes from the `actual-budget-oidc`
ExternalSecret; client id, discovery URL and public hostname are plain env.
Redirect URI registered at the provider: `https://<host>/openid/callback`.

- The **first** user to log in becomes the server owner (admin), permanently —
  log in as the intended owner first.
- `ACTUAL_USER_CREATION_MODE` is left at its default (`manual`): further users
  must be added in Actual's User Directory with a username matching the
  provider's, then granted access per budget.

## Headers middleware — no CSP

`default-headers` sets a Content-Security-Policy without `blob:`, which breaks
Actual's blob web workers (its budget engine). Actual sends its own CSP (plus the
COOP/COEP headers SharedArrayBuffer needs), so the chart renders its own
`actual-budget-headers` Middleware: `default-headers` minus the CSP.

## No ServiceMonitor

`/metrics` exists but returns JSON (`process.memoryUsage()` + uptime), not the
Prometheus exposition format. `/health` backs both probes.

## Values

| Key | Default | Description |
|-----|---------|-------------|
| `name` | `actual-budget` | App name — drives resource names, labels, namespace. |
| `image.repository` | `actualbudget/actual-server` | Official image (amd64/arm64). |
| `image.tag` | `26.11.0` | Renovate-managed; `YY.M.P` scheme, so the yearly bump is a major (PR only). |
| `controller.type` | `statefulset` | Owns a writable RWO volume ⇒ StatefulSet. |
| `volumeClaimTemplates` | `actual-budget-data` RWO longhorn 1Gi | Mounted at `/data`. |
| `serviceAccount.create` | `false` | Runs under the namespace `default` SA. |
| `podSecurityContext` | uid/gid/fsGroup 1001, non-root, seccomp | Image does not drop root itself. |
| `securityContext` | read-only rootfs, no privilege escalation, drop ALL | `/tmp` is an emptyDir. |
| `ports` | `http` 5006 | Container port. |
| `env` | heap cap + OIDC settings | Client secret via `secretKeyRef`. |
| `externalSecrets` | `actual-budget-oidc` | OIDC client secret. |
| `readinessProbe` / `livenessProbe` | httpGet `/health` :5006 | Health checks. |
| `services` | `actual-budget` ClusterIP :5006 | Service list. |
| `ingressRoute` | one route, `actual-budget-headers` only | No forward-auth (in-app OIDC). |
| `serviceMonitor.enabled` | `false` | No Prometheus endpoint. |
| `middlewares` | `actual-budget-headers` (traefik ns) | `default-headers` without the CSP. |

## Verify locally

```bash
helm dependency build charts/actual-budget
helm lint charts/actual-budget
helm template actual-budget charts/actual-budget | kubeconform -strict -ignore-missing-schemas -skip IngressRoute
bash tests/diff-charts.sh
```
