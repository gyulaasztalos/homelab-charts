#!/usr/bin/env bash
# diff-migration.sh <app> [path-to-ArgoCD-repo]
#
# MANDATORY local migration test (NOT run in CI). For one app, render:
#   - the ORIGINAL kustomize manifests in <ArgoCD>/apps/<app>/install
#   - the NEW helm chart in charts/<app>
# normalize both (split per resource, sort keys, strip noise) and diff them.
#
# The only differences you should see are the INTENTIONAL migration deltas
# (e.g. Deployment -> StatefulSet, static PVC -> volumeClaimTemplate). Review the
# diff by eye, confirm every hunk is expected, THEN it is safe to delete the old
# install/ dir. Nothing here is committed as a golden snapshot on purpose: a frozen
# copy of the old manifests would rot as the chart evolves.
#
# Requires: helm, kubectl (for `kubectl kustomize`), yq v4 (mikefarah).
set -euo pipefail

app="${1:?usage: diff-migration.sh <app> [argocd-repo-path]}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
argocd="${2:-${ARGOCD_REPO:-$repo_root/../ArgoCD}}"

install_dir="$argocd/apps/$app/install"
chart_dir="$repo_root/charts/$app"

# The chart's own values.yaml is now GENERIC (example.com + defaults); the real
# domain-specific config lives in the ArgoCD repo. Render the chart WITH that
# tailored values file so the comparison against install/ is apples-to-apples.
# (Falls back to chart defaults if the tailored file doesn't exist yet.)
values_file="$argocd/apps/$app/values.yaml"
helm_values_args=()
[ -f "$values_file" ] && helm_values_args=(-f "$values_file")

[ -d "$install_dir" ] || { echo "ERROR: original manifests not found: $install_dir" >&2; exit 2; }
[ -d "$chart_dir" ]   || { echo "ERROR: chart not found: $chart_dir" >&2; exit 2; }
command -v yq >/dev/null || { echo "ERROR: yq v4 (mikefarah) is required" >&2; exit 3; }
yq --version | grep -q 'v4' || { echo "ERROR: need yq v4, found: $(yq --version)" >&2; exit 3; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/orig" "$work/helm"

# Normalize a rendered multi-doc stream (stdin) and split into one file per
# <kind>_<name> under $1. Drops noise fields and sorts keys so only real value
# differences survive.
normalize_split() {
  local dest="$1"
  yq ea '
    del(.metadata.creationTimestamp) |
    del(.status) |
    del(.metadata.annotations."kubectl.kubernetes.io/last-applied-configuration") |
    sort_keys(..)
  ' - \
  | yq ea -s "\"$dest/\" + (.kind // \"x\") + \"_\" + (.metadata.name // \"x\")" -
}

echo ">> rendering ORIGINAL kustomize: $install_dir"
kubectl kustomize "$install_dir" | normalize_split "$work/orig"

echo ">> rendering HELM chart: $chart_dir ${helm_values_args:+(with $values_file)}"
helm dependency build "$chart_dir" >/dev/null 2>&1 || true
helm template "$app" "$chart_dir" "${helm_values_args[@]}" | normalize_split "$work/helm"

echo
echo "==================== RESOURCE INVENTORY ===================="
echo "ORIGINAL:"; ( cd "$work/orig" 2>/dev/null && ls -1 ) | sed 's/\.yml$//' | sort
echo "HELM:";     ( cd "$work/helm" 2>/dev/null && ls -1 ) | sed 's/\.yml$//' | sort
echo
echo "==================== PER-RESOURCE DIFF ===================="
echo "(left = original kustomize, right = helm chart; only INTENTIONAL migration"
echo " deltas should appear — review every hunk before deleting install/)"
echo
rc=0
all="$( { ls -1 "$work/orig" 2>/dev/null; ls -1 "$work/helm" 2>/dev/null; } | sort -u )"
for f in $all; do
  o="$work/orig/$f"; h="$work/helm/$f"
  if [ ! -f "$o" ]; then echo "### ONLY IN HELM: ${f%.yml}"; rc=1; continue; fi
  if [ ! -f "$h" ]; then
    # Grafana dashboards and PrometheusRules are intentionally NOT in the chart;
    # they relocate to apps/<app>/post-install (see PLAN.md). Flag as expected.
    if grep -q 'grafana_dashboard' "$o" 2>/dev/null; then
      echo "### RELOCATE TO post-install (grafana dashboard, expected): ${f%.yml}"; continue
    fi
    if head -1 "$o" | grep -q 'PrometheusRule' 2>/dev/null || grep -q '^kind: PrometheusRule' "$o" 2>/dev/null; then
      echo "### RELOCATE TO post-install (PrometheusRule, expected): ${f%.yml}"; continue
    fi
    echo "### ONLY IN ORIGINAL: ${f%.yml}"; rc=1; continue
  fi
  if ! diff -u "$o" "$h" >/dev/null; then
    echo "### DIFF: ${f%.yml}"
    diff -u --label "orig/${f%.yml}" --label "helm/${f%.yml}" "$o" "$h" || true
    echo
    rc=1
  fi
done
[ "$rc" -eq 0 ] && echo "No differences (identical render)."
echo

# When the controller kind changed (Deployment<->StatefulSet<->DaemonSet), the
# per-resource diff above shows them only as "ONLY IN ...". Diff the POD SPECs
# directly so the meaningful container/volume/security comparison isn't skipped.
echo "==================== POD SPEC DIFF (controllers) ===================="
orig_pod="$work/orig_pod.yaml"; helm_pod="$work/helm_pod.yaml"
kubectl kustomize "$install_dir" \
  | yq ea 'select(.kind=="Deployment" or .kind=="StatefulSet" or .kind=="DaemonSet") | .spec.template.spec | sort_keys(..)' - > "$orig_pod" || true
helm template "$app" "$chart_dir" "${helm_values_args[@]}" \
  | yq ea 'select(.kind=="Deployment" or .kind=="StatefulSet" or .kind=="DaemonSet") | .spec.template.spec | sort_keys(..)' - > "$helm_pod" || true
if diff -u --label orig-pod "$orig_pod" --label helm-pod "$helm_pod" >/dev/null; then
  echo "Pod specs IDENTICAL."
else
  echo "(expected deltas: image quoting; a volume that moved to a volumeClaimTemplate)"
  diff -u --label orig-pod "$orig_pod" --label helm-pod "$helm_pod" || true
fi
echo "==========================================================="
echo "Reminder: a non-empty diff is EXPECTED for migrated controllers."
echo "Confirm each hunk is an intended delta, then it is safe to remove install/."
