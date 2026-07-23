#!/usr/bin/env bash
# =============================================================================
# diff-charts.sh [ref] [chart ...]
#
# REGRESSION GATE for changes to charts that are ALREADY LIVE.
#
# Once an app has been migrated and verified in production, that chart's render
# IS the proven baseline — the old install/ manifests are irrelevant from then on
# (that is what hack/diff-migration.sh is for, and it is a ONE-TIME gate, run
# once per app at migration time).
#
# So the question for every later change is not "does this still match the old
# kustomize?" but:
#
#     does this change what gets deployed, for any app I did not mean to touch?
#
# This script answers that. It renders every chart at <ref> (default HEAD — the
# last proven state) and again from the working tree, then diffs them per chart.
#
# The blast radius that matters is charts/common: a wrapper-chart edit can only
# break its own app, but a library change silently re-renders EVERY proven app at
# once. Run this after any charts/common edit and confirm that only the charts you
# intended to change show a diff.
#
# Two renders are compared for each chart:
#   1. GENERIC  — the chart's own values.yaml. What CI validates.
#   2. DEPLOYED — the same chart layered with the tailored GitOps values from
#                 <ArgoCD>/apps/<chart>/values.yaml. This is the artifact that is
#                 actually running in the cluster, so it is the one that proves
#                 "nothing moved". Skipped for charts with no GitOps values yet.
#
# Both sides of the DEPLOYED comparison use the CURRENT tailored values, so this
# isolates the effect of the homelab-charts change alone. A change to the GitOps
# values.yaml is a separate, deliberate act and shows up in that repo's own diff.
#
# LOCAL ONLY, like diff-migration.sh. Exits 0 even when charts differ — a diff
# here is usually intended; the point is to SEE it. Pass --fail-on-change to make
# it a hard gate (for wiring into CI later).
#
# Requires: helm, git.
# =============================================================================
set -euo pipefail

fail_on_change=0
args=()
for a in "$@"; do
  case "$a" in
    --fail-on-change) fail_on_change=1 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) args+=("$a") ;;
  esac
done
set -- ${args[@]+"${args[@]}"}

ref="${1:-HEAD}"
shift || true
only_charts=("$@")

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
argocd="${ARGOCD_REPO:-$repo_root/../ArgoCD}"

command -v helm >/dev/null || { echo "ERROR: helm is required" >&2; exit 3; }
git -C "$repo_root" rev-parse --verify "$ref" >/dev/null 2>&1 \
  || { echo "ERROR: not a valid git ref: $ref" >&2; exit 2; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/base"

# Baseline: the whole charts/ tree as of <ref>, so file://../common resolves.
git -C "$repo_root" archive "$ref" charts | tar -x -C "$work/base"

# Render <chart-dir> into <out>, optionally with a tailored values file.
render() {
  local dir="$1" name="$2" out="$3" values="${4:-}"
  local vargs=()
  [ -n "$values" ] && vargs=(-f "$values")
  helm dependency build "$dir" >/dev/null 2>&1 || true
  helm template "$name" "$dir" ${vargs[@]+"${vargs[@]}"} > "$out" 2>"$out.err" || {
    echo "RENDER FAILED"; sed 's/^/      /' "$out.err" >&2; return 1; }
  return 0
}

# Chart list: union of both sides, minus the library chart (it renders nothing on
# its own — its changes surface through the wrappers, which is the whole point).
list_charts() {
  { ls -1 "$repo_root/charts" 2>/dev/null; ls -1 "$work/base/charts" 2>/dev/null; } \
    | sort -u | grep -v '^common$'
}
charts="$(list_charts)"
if [ ${#only_charts[@]} -gt 0 ]; then
  charts="$(printf '%s\n' "${only_charts[@]}")"
fi

echo "baseline ref : $ref  ($(git -C "$repo_root" log -1 --format='%h %s' "$ref"))"
echo "working tree : $repo_root"
echo "gitops repo  : $argocd"
echo

# Call out library changes up front — that is the high blast-radius case.
if ! git -C "$repo_root" diff --quiet "$ref" -- charts/common 2>/dev/null; then
  echo "!! charts/common CHANGED since $ref — every chart below is re-rendered by it."
  git -C "$repo_root" diff --stat "$ref" -- charts/common | sed 's/^/   /'
  echo
fi

summary=""
changed_any=0

for name in $charts; do
  cur_dir="$repo_root/charts/$name"
  base_dir="$work/base/charts/$name"
  values="$argocd/apps/$name/values.yaml"

  if [ ! -d "$base_dir" ]; then
    summary="$summary\n  NEW        $name (does not exist at $ref — nothing to compare)"
    continue
  fi
  if [ ! -d "$cur_dir" ]; then
    summary="$summary\n  REMOVED    $name (present at $ref, gone from the working tree)"
    changed_any=1
    continue
  fi

  for mode in generic deployed; do
    vfile=""
    if [ "$mode" = deployed ]; then
      [ -f "$values" ] || continue
      vfile="$values"
    fi
    b="$work/$name.$mode.base"; c="$work/$name.$mode.cur"
    render "$base_dir" "$name" "$b" "$vfile" || { summary="$summary\n  ERROR      $name ($mode, baseline)"; changed_any=1; continue; }
    render "$cur_dir"  "$name" "$c" "$vfile" || { summary="$summary\n  ERROR      $name ($mode, current)";  changed_any=1; continue; }

    if diff -q "$b" "$c" >/dev/null; then
      summary="$summary\n  identical  $name ($mode)"
    else
      changed_any=1
      summary="$summary\n  CHANGED    $name ($mode)"
      echo "======================================================================"
      echo "### CHANGED: $name  [$mode render]"
      [ -n "$vfile" ] && echo "###          values: $vfile"
      echo "======================================================================"
      diff -u --label "$ref/$name" --label "worktree/$name" "$b" "$c" || true
      echo
    fi
  done
done

echo "==================== SUMMARY ===================="
printf '%b\n' "${summary# }"
echo
if [ "$changed_any" -eq 0 ]; then
  echo "No render changes: every chart produces byte-identical output vs $ref."
else
  echo "Some charts render differently vs $ref."
  echo "Confirm EVERY chart listed as CHANGED is one you meant to change — an app"
  echo "you did not touch appearing here means a charts/common edit leaked into it."
fi

[ "$fail_on_change" -eq 1 ] && [ "$changed_any" -ne 0 ] && exit 1
exit 0
