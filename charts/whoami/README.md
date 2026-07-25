# whoami

[traefik/whoami](https://github.com/traefik/whoami) — a tiny HTTP echo service that
prints the request it received. Used to smoke-test ingress, TLS and Authentik
forward-auth. Rendered through the [`common`](../common) library chart.

Requires **`common` >= 0.6.0**.

## Controller

**DaemonSet** — one whoami pod per node (so a request lands on an echo endpoint
whichever node Traefik picks). Stateless: the only writable paths are three
emptyDirs (`/var/cache/whoami`, `/var/run`, `/tmp`) that make the **read-only root
filesystem** workable. No secrets, ConfigMaps, storage or metrics, so the chart
renders the whole app and there is **no post-install source** — the multi-source
Application is just the config ref + the chart.

> This is a DaemonSet by **explicit choice**, not the bright-line rule (whoami has
> no node-local hardware, so that rule alone would make it a Deployment). A
> DaemonSet uses `updateStrategy` (not `strategy`), only `maxUnavailable` applies,
> and `podAntiAffinity` is off — it is already one pod per node.

## Security

Fully hardened, straight from `common`'s defaults plus a values override: non-root
(uid/gid 1000), RuntimeDefault seccomp, read-only rootfs, `allowPrivilegeEscalation:
false`, and **all capabilities dropped except `NET_BIND_SERVICE`** so the app can
still bind `:80` as an unprivileged user.

## Ingress

One route, `whoami.<domain>`, behind **Authentik + default-headers** — the
`common` middleware default, so `ingressRoute.routes[].middlewares` is simply
omitted. Runs in the `default` namespace (`namespace: default`).

## Migration notes

Migrated from the hand-written `apps/whoami/post-install/` kustomize manifests. The
**controller kind was deliberately changed Deployment → DaemonSet** (see above); the
pod spec is otherwise preserved and was verified against the original per field
(image, probes, resources, the full hardened security context + capabilities, the
three emptyDirs), as were the Service (selector/ports) and IngressRoute (host,
authentik + default-headers middlewares, service, tls). Intentional deltas:

- **Deployment → DaemonSet**: `replicas` / `strategy` / `progressDeadlineSeconds`
  give way to `updateStrategy` (`maxUnavailable: 1`), and `podAntiAffinity` is
  dropped (redundant — a DaemonSet is one-per-node);
- explicit defaults the chart makes visible — `restartPolicy: Always`,
  `type: ClusterIP` (Service), `priority: 10` (IngressRoute route);
- the Service gains the standard five-label block (the raw manifest carried none);
- the image string is quoted.

## Verify locally

```bash
helm dependency build charts/whoami
helm lint charts/whoami
helm template whoami charts/whoami | kubeconform -strict -ignore-missing-schemas -skip IngressRoute
```
