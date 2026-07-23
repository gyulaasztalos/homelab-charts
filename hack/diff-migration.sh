#!/usr/bin/env bash
# diff-migration.sh <app> [path-to-ArgoCD-repo]
#
# ONE-TIME migration gate, run once per app while both representations still
# exist. Once the app is cut over and verified in production, that chart's render
# becomes the proven baseline and install/ is irrelevant — from then on, changes
# are checked with hack/diff-charts.sh (previous proven render vs new render),
# NOT against these old manifests.
#
# MANDATORY local migration test (NOT run in CI). For one app, render:
#   - the ORIGINAL kustomize manifests in <ArgoCD>/apps/<app>/install
#   - the NEW state: the helm chart in charts/<app>, PLUS the pre-install/ and
#     post-install/ kustomize dirs, because an app's objects are split across all
#     the sources its ArgoCD Application syncs. Comparing against the chart alone
#     reports everything that moved to pre/post-install as a bogus
#     "ONLY IN ORIGINAL" (this is what happened during the homepage migration).
# normalize both (split per resource, sort keys, strip noise) and diff them.
#
# The only differences you should see are the INTENTIONAL migration deltas
# (e.g. Deployment -> StatefulSet, static PVC -> volumeClaimTemplate). Review the
# diff by eye, confirm every hunk is expected, THEN it is safe to delete the old
# install/ dir. Nothing here is committed as a golden snapshot on purpose: a frozen
# copy of the old manifests would rot as the chart evolves.
#
# ORDERING: run this BEFORE moving anything out of install/. If files have already
# been relocated, install/ no longer builds — set ORIG_FROM_GIT=1 to reconstruct
# the pre-migration tree from git instead:
#     ORIG_FROM_GIT=1 hack/diff-migration.sh homepage
#
# ORIG_REF selects which commit to reconstruct from (default HEAD). Note that the
# cutover commit itself DELETES install/, so once a migration is committed you
# need the commit before it — this is how a past migration is re-verified:
#     ORIG_FROM_GIT=1 ORIG_REF=<cutover-sha>^ hack/diff-migration.sh ddns-updater
#
# Requires: helm, kubectl (for `kubectl kustomize`), yq v4 (mikefarah), git.
set -euo pipefail

app="${1:?usage: diff-migration.sh <app> [argocd-repo-path]}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
argocd="${2:-${ARGOCD_REPO:-$repo_root/../ArgoCD}}"

install_dir="$argocd/apps/$app/install"
chart_dir="$repo_root/charts/$app"
orig_from_git="${ORIG_FROM_GIT:-0}"
orig_ref="${ORIG_REF:-HEAD}"

# The chart's own values.yaml is now GENERIC (example.com + defaults); the real
# domain-specific config lives in the ArgoCD repo. Render the chart WITH that
# tailored values file so the comparison against install/ is apples-to-apples.
# (Falls back to chart defaults if the tailored file doesn't exist yet.)
values_file="$argocd/apps/$app/values.yaml"
helm_values_args=()
[ -f "$values_file" ] && helm_values_args=(-f "$values_file")

if [ "$orig_from_git" != "1" ] && [ ! -d "$install_dir" ]; then
  echo "ERROR: original manifests not found: $install_dir" >&2
  echo "       If install/ was already dismantled, re-run with ORIG_FROM_GIT=1 to" >&2
  echo "       reconstruct the pre-migration tree from git HEAD." >&2
  exit 2
fi
[ -d "$chart_dir" ]   || { echo "ERROR: chart not found: $chart_dir" >&2; exit 2; }
command -v yq >/dev/null || { echo "ERROR: yq v4 (mikefarah) is required" >&2; exit 3; }
yq --version | grep -q 'v4' || { echo "ERROR: need yq v4, found: $(yq --version)" >&2; exit 3; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/orig" "$work/helm"

# Normalize a rendered multi-doc stream (stdin) and split into one file per
# <kind>_<name> under $1. Drops noise fields and sorts keys so only real value
# differences survive.
# `... comments=""` strips Helm's `# Source: <chart>/templates/...` header, which
# kustomize never emits and which would otherwise show up as a diff hunk on EVERY
# single resource, drowning the real deltas.
normalize_split() {
  local dest="$1"
  yq ea '
    del(.metadata.creationTimestamp) |
    del(.status) |
    del(.metadata.annotations."kubectl.kubernetes.io/last-applied-configuration") |
    sort_keys(..) |
    ... comments=""
  ' - \
  | yq ea -s "\"$dest/\" + (.kind // \"x\") + \"_\" + (.metadata.name // \"x\")" -
}

# --- ORIGINAL -----------------------------------------------------------------
# Either the install/ dir as it stands, or (ORIG_FROM_GIT=1) the pre-migration
# tree extracted from git HEAD, for when files have already been relocated.
if [ "$orig_from_git" = "1" ]; then
  echo ">> rendering ORIGINAL from git $orig_ref: apps/$app/install"
  mkdir -p "$work/git"
  git -C "$argocd" archive "$orig_ref" "apps/$app/install" 2>/dev/null | tar -x -C "$work/git" \
    || { echo "ERROR: apps/$app/install not found at $orig_ref in $argocd" >&2
         echo "       The cutover commit deletes install/ — try ORIG_REF=<sha>^" >&2; exit 2; }
  kubectl kustomize "$work/git/apps/$app/install" > "$work/orig.yaml"
else
  echo ">> rendering ORIGINAL kustomize: $install_dir"
  kubectl kustomize "$install_dir" > "$work/orig.yaml"
fi
normalize_split "$work/orig" < "$work/orig.yaml"

# --- NEW ----------------------------------------------------------------------
# The chart, PLUS every extra kustomize source the app's Application syncs.
# NOTE: `helm template` output does not end in a document separator, so a bare
# `>>` append would fuse the last Helm document into the first kustomize one.
# The explicit `---` below is load-bearing.
echo ">> rendering HELM chart: $chart_dir ${helm_values_args:+(with $values_file)}"
helm dependency build "$chart_dir" >/dev/null 2>&1 || true
helm template "$app" "$chart_dir" "${helm_values_args[@]}" > "$work/new.yaml"

for extra in pre-install post-install; do
  extra_dir="$argocd/apps/$app/$extra"
  [ -d "$extra_dir" ] || continue
  echo ">> + kustomize source: $extra_dir"
  printf '\n---\n' >> "$work/new.yaml"
  kubectl kustomize "$extra_dir" >> "$work/new.yaml"
done
normalize_split "$work/helm" < "$work/new.yaml"

echo
echo "==================== RESOURCE INVENTORY ===================="
echo "ORIGINAL:"; ( cd "$work/orig" 2>/dev/null && ls -1 ) | sed 's/\.yml$//' | sort
echo "HELM:";     ( cd "$work/helm" 2>/dev/null && ls -1 ) | sed 's/\.yml$//' | sort
echo
echo "==================== PER-RESOURCE DIFF ===================="
echo "(left = original kustomize, right = chart + pre/post-install; only"
echo " INTENTIONAL deltas should appear — review every hunk before deleting install/)"
echo
rc=0
all="$( { ls -1 "$work/orig" 2>/dev/null; ls -1 "$work/helm" 2>/dev/null; } | sort -u )"

# Pre-pass: kustomize's configMapGenerator appends a content hash to the object
# name; the chart (and a disableNameSuffixHash generator) uses the static name.
# Match each hash-suffixed original to its static twin so the pair is reported
# ONCE, as a rename, instead of twice as a bogus missing/extra object.
paired=""
for f in $all; do
  [ -f "$work/orig/$f" ] || continue
  base="$(echo "${f%.yml}" | sed -E 's/-[bcdfghjkmnptvwxz2456789]{10}$//')"
  [ "$base" = "${f%.yml}" ] && continue
  [ -f "$work/helm/$base.yml" ] && paired="$paired $base.yml"
done
is_paired() { case " $paired " in *" $1 "*) return 0;; *) return 1;; esac; }

for f in $all; do
  o="$work/orig/$f"; h="$work/helm/$f"
  if [ ! -f "$o" ]; then
    is_paired "$f" && continue          # other half of a hash-suffix rename
    echo "### ONLY IN NEW: ${f%.yml}"; rc=1; continue
  fi
  if [ ! -f "$h" ]; then
    base="$(echo "${f%.yml}" | sed -E 's/-[bcdfghjkmnptvwxz2456789]{10}$//')"
    if [ "$base" != "${f%.yml}" ] && [ -f "$work/helm/$base.yml" ]; then
      # Compare with the name stripped: a hash rename is expected, anything else
      # is a real delta the reviewer must confirm.
      a="$work/.a"; b="$work/.b"
      yq ea 'del(.metadata.name)' "$o" > "$a"
      yq ea 'del(.metadata.name)' "$work/helm/$base.yml" > "$b"
      if diff -q "$a" "$b" >/dev/null 2>&1; then
        echo "### HASH-SUFFIX RENAME, otherwise identical (expected): ${f%.yml} -> $base"
      else
        echo "### HASH-SUFFIX RENAME + other deltas: ${f%.yml} -> $base"
        diff -u --label "orig/${f%.yml}" --label "new/$base" "$a" "$b" || true
        echo
        rc=1
      fi
      continue
    fi
    echo "### ONLY IN ORIGINAL: ${f%.yml}"; rc=1; continue
  fi
  if ! diff -u "$o" "$h" >/dev/null; then
    echo "### DIFF: ${f%.yml}"
    diff -u --label "orig/${f%.yml}" --label "new/${f%.yml}" "$o" "$h" || true
    echo
    rc=1
  fi
done
# Any hash-suffixed original whose static twin also existed is handled above; a
# static-named ConfigMap present ONLY in the new render is the other half of that
# pair, so don't double-report it.
[ "$rc" -eq 0 ] && echo "No differences (identical render)."
echo

# When the controller kind changed (Deployment<->StatefulSet<->DaemonSet), the
# per-resource diff above shows them only as "ONLY IN ...". Diff the POD SPECs
# directly so the meaningful container/volume/security comparison isn't skipped.
echo "==================== POD SPEC DIFF (controllers) ===================="
orig_pod="$work/orig_pod.yaml"; helm_pod="$work/helm_pod.yaml"
podspec='select(.kind=="Deployment" or .kind=="StatefulSet" or .kind=="DaemonSet") | .spec.template.spec | sort_keys(..)'
yq ea "$podspec" "$work/orig.yaml" > "$orig_pod" || true
yq ea "$podspec" "$work/new.yaml"  > "$helm_pod" || true
if diff -u --label orig-pod "$orig_pod" --label helm-pod "$helm_pod" >/dev/null; then
  echo "Pod specs IDENTICAL."
else
  echo "(expected deltas: image quoting; a volume that moved to a volumeClaimTemplate)"
  diff -u --label orig-pod "$orig_pod" --label helm-pod "$helm_pod" || true
fi
echo "==========================================================="
echo "Reminder: a non-empty diff is EXPECTED for migrated controllers."
echo "Confirm each hunk is an intended delta, then it is safe to remove install/."
