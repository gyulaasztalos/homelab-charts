# homelab-charts

Private Helm charts for the HomeLab k3s cluster, consumed by ArgoCD as a chart
source. Replaces the hand-written `apps/<name>/install` kustomize manifests in the
[ArgoCD](https://github.com/gyulaasztalos/ArgoCD) repo with reusable Helm charts.

Built on open-source tooling only. See [`PLAN.md`](PLAN.md) for the full project
plan, rationale (library-chart / Option C), and sequencing.

## Layout

```
charts/
  common/        Helm library chart — all shared templating logic (type: library)
  <app>/         Thin wrapper chart per app: Chart.yaml (deps common) + values.yaml + templates/main.yaml
```

## The library chart

`charts/common` defines named templates for the standard homelab resource set:
controller (`deployment` / `statefulset` / `daemonset`), service, Traefik
IngressRoute, Prometheus ServiceMonitor, PVC, ExternalSecret (1Password Connect),
ConfigMap — plus the standard label block, security context, and pod anti-affinity.

### Controller selection (bright-line rule)

```
node-local hardware?        → daemonset
else owns a writable RWO PVC? → statefulset
else                          → deployment
```

## Secrets

Charts render **ExternalSecret references only**. The actual secrets live in
1Password and are pulled by External Secrets Operator via the in-cluster
`onepassword-connect` ClusterSecretStore. **No 1Password token or secret material
is stored in this repo.**

## Using a chart from ArgoCD

Multi-source `Application`: one source points at this repo
(`path: charts/<app>`, `targetRevision` pinned to a tag/branch), rendered by Helm.
Renovate bumps the pinned revision.

## Local development & verification

Requires the latest stable `helm` and `kubeconform`.

```bash
# build the library dependency into a wrapper chart
helm dependency build charts/<app>

# lint + render
helm lint charts/<app>
helm template charts/<app>

# schema-validate the rendered output (add CRD schemas for Traefik / ServiceMonitor / ExternalSecret)
helm template charts/<app> | kubeconform -strict -summary -ignore-missing-schemas
```

During migration, always **diff the rendered output against the current
`apps/<app>/install` manifests** before cutover — they must be semantically
equivalent.

## CI

GitHub Actions on push/PR to `main`:
- `helm lint` + render + `kubeconform`
- `kube-linter` (manifest best-practices)
- `pluto` (deprecated Kubernetes API detection)

All actions/tools pinned to latest stable.
