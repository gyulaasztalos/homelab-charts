#!/usr/bin/env bash
# diff-migration.sh <app> [path-to-ArgoCD-repo]
#
# ONE-TIME migration gate, run once per app while both representations still
# exist. Once the app is cut over and verified in production, that chart's render
# becomes the proven baseline and install/ is irrelevant — from then on, changes
# are checked with tests/diff-charts.sh (previous proven render vs new render),
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
#     ORIG_FROM_GIT=1 tests/diff-migration.sh homepage
#
# ORIG_REF selects which commit to reconstruct from (default HEAD). Note that the
# cutover commit itself DELETES install/, so once a migration is committed you
# need the commit before it — this is how a past migration is re-verified:
#     ORIG_FROM_GIT=1 ORIG_REF=<cutover-sha>^ tests/diff-migration.sh ddns-updater
#
# Requires: helm, kubectl (for `kubectl kustomize`), yq v4 (mikefarah), git.
set -euo pipefail

APP="${1:?usage: diff-migration.sh <app> [argocd-repo-path]}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARGOCD="${2:-${ARGOCD_REPO:-${REPO_ROOT}/../ArgoCD}}"

INSTALL_DIR="${ARGOCD}/apps/${APP}/install"
CHART_DIR="${REPO_ROOT}/charts/${APP}"
ORIG_FROM_GIT="${ORIG_FROM_GIT:-0}"
ORIG_REF="${ORIG_REF:-HEAD}"

# The chart's own values.yaml is now GENERIC (example.com + defaults); the real
# domain-specific config lives in the ArgoCD repo. Render the chart WITH that
# tailored values file so the comparison against install/ is apples-to-apples.
# (Falls back to chart defaults if the tailored file doesn't exist yet.)
VALUES_FILE="${ARGOCD}/apps/${APP}/values.yaml"
HELM_VALUES_ARGS=()
if [ -f "${VALUES_FILE}" ]
then
    HELM_VALUES_ARGS=(-f "${VALUES_FILE}")
fi

if [ "${ORIG_FROM_GIT}" != "1" ] && [ ! -d "${INSTALL_DIR}" ]
then
    echo "ERROR: original manifests not found: ${INSTALL_DIR}" >&2
    echo "       If install/ was already dismantled, re-run with ORIG_FROM_GIT=1 to" >&2
    echo "       reconstruct the pre-migration tree from git HEAD." >&2
    exit 2
fi
if [ ! -d "${CHART_DIR}" ]
then
    echo "ERROR: chart not found: ${CHART_DIR}" >&2
    exit 2
fi
if ! command -v yq >/dev/null
then
    echo "ERROR: yq v4 (mikefarah) is required" >&2
    exit 3
fi
if ! yq --version | grep -q 'v4'
then
    echo "ERROR: need yq v4, found: $(yq --version)" >&2
    exit 3
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/orig" "${WORK}/helm"

# Normalize a rendered multi-doc stream (stdin) and split into one file per
# <kind>_<name> under $1. Drops noise fields and sorts keys so only real value
# differences survive.
# `... comments=""` strips Helm's `# Source: <chart>/templates/...` header, which
# kustomize never emits and which would otherwise show up as a diff hunk on EVERY
# single resource, drowning the real deltas.
function normalize_split {
    local DEST="${1}"
    yq ea '
        del(.metadata.creationTimestamp) |
        del(.status) |
        del(.metadata.annotations."kubectl.kubernetes.io/last-applied-configuration") |
        sort_keys(..) |
        ... comments=""
    ' - \
    | yq ea -s "\"${DEST}/\" + (.kind // \"x\") + \"_\" + (.metadata.name // \"x\")" -
}

# --- ORIGINAL -----------------------------------------------------------------
# Either the install/ dir as it stands, or (ORIG_FROM_GIT=1) the pre-migration
# tree extracted from git HEAD, for when files have already been relocated.
if [ "${ORIG_FROM_GIT}" = "1" ]
then
    echo ">> rendering ORIGINAL from git ${ORIG_REF}: apps/${APP}/install"
    mkdir -p "${WORK}/git"
    if ! git -C "${ARGOCD}" archive "${ORIG_REF}" "apps/${APP}/install" 2>/dev/null | tar -x -C "${WORK}/git"
    then
        echo "ERROR: apps/${APP}/install not found at ${ORIG_REF} in ${ARGOCD}" >&2
        echo "       The cutover commit deletes install/ — try ORIG_REF=<sha>^" >&2
        exit 2
    fi
    kubectl kustomize "${WORK}/git/apps/${APP}/install" > "${WORK}/orig.yaml"
else
    echo ">> rendering ORIGINAL kustomize: ${INSTALL_DIR}"
    kubectl kustomize "${INSTALL_DIR}" > "${WORK}/orig.yaml"
fi
normalize_split "${WORK}/orig" < "${WORK}/orig.yaml"

# --- NEW ----------------------------------------------------------------------
# The chart, PLUS every extra kustomize source the app's Application syncs.
# NOTE: `helm template` output does not end in a document separator, so a bare
# `>>` append would fuse the last Helm document into the first kustomize one.
# The explicit `---` below is load-bearing.
echo ">> rendering HELM chart: ${CHART_DIR} ${HELM_VALUES_ARGS:+(with ${VALUES_FILE})}"
helm dependency build "${CHART_DIR}" >/dev/null 2>&1 || true
helm template "${APP}" "${CHART_DIR}" "${HELM_VALUES_ARGS[@]}" > "${WORK}/new.yaml"

for EXTRA in pre-install post-install
do
    EXTRA_DIR="${ARGOCD}/apps/${APP}/${EXTRA}"
    if [ ! -d "${EXTRA_DIR}" ]
    then
        continue
    fi
    echo ">> + kustomize source: ${EXTRA_DIR}"
    printf '\n---\n' >> "${WORK}/new.yaml"
    kubectl kustomize "${EXTRA_DIR}" >> "${WORK}/new.yaml"
done
normalize_split "${WORK}/helm" < "${WORK}/new.yaml"

echo
echo "==================== RESOURCE INVENTORY ===================="
echo "ORIGINAL:"; ( cd "${WORK}/orig" 2>/dev/null && ls -1 ) | sed 's/\.yml$//' | sort
echo "HELM:";     ( cd "${WORK}/helm" 2>/dev/null && ls -1 ) | sed 's/\.yml$//' | sort
echo
echo "==================== PER-RESOURCE DIFF ===================="
echo "(left = original kustomize, right = chart + pre/post-install; only"
echo " INTENTIONAL deltas should appear — review every hunk before deleting install/)"
echo
RC=0
ALL="$( { ls -1 "${WORK}/orig" 2>/dev/null; ls -1 "${WORK}/helm" 2>/dev/null; } | sort -u )"

# Pre-pass: kustomize's configMapGenerator appends a content hash to the object
# name; the chart (and a disableNameSuffixHash generator) uses the static name.
# Match each hash-suffixed original to its static twin so the pair is reported
# ONCE, as a rename, instead of twice as a bogus missing/extra object.
PAIRED=""
for F in ${ALL}
do
    if [ ! -f "${WORK}/orig/${F}" ]
    then
        continue
    fi
    BASE="$(echo "${F%.yml}" | sed -E 's/-[bcdfghjkmnptvwxz2456789]{10}$//')"
    if [ "${BASE}" = "${F%.yml}" ]
    then
        continue
    fi
    if [ -f "${WORK}/helm/${BASE}.yml" ]
    then
        PAIRED="${PAIRED} ${BASE}.yml"
    fi
done

function is_paired {
    case " ${PAIRED} " in
        *" ${1} "*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

for F in ${ALL}
do
    ORIG_FILE="${WORK}/orig/${F}"
    HELM_FILE="${WORK}/helm/${F}"
    if [ ! -f "${ORIG_FILE}" ]
    then
        if is_paired "${F}"          # other half of a hash-suffix rename
        then
            continue
        fi
        echo "### ONLY IN NEW: ${F%.yml}"
        RC=1
        continue
    fi
    if [ ! -f "${HELM_FILE}" ]
    then
        BASE="$(echo "${F%.yml}" | sed -E 's/-[bcdfghjkmnptvwxz2456789]{10}$//')"
        if [ "${BASE}" != "${F%.yml}" ] && [ -f "${WORK}/helm/${BASE}.yml" ]
        then
            # Compare with the name stripped: a hash rename is expected, anything
            # else is a real delta the reviewer must confirm.
            A_FILE="${WORK}/.a"
            B_FILE="${WORK}/.b"
            yq ea 'del(.metadata.name)' "${ORIG_FILE}" > "${A_FILE}"
            yq ea 'del(.metadata.name)' "${WORK}/helm/${BASE}.yml" > "${B_FILE}"
            if diff -q "${A_FILE}" "${B_FILE}" >/dev/null 2>&1
            then
                echo "### HASH-SUFFIX RENAME, otherwise identical (expected): ${F%.yml} -> ${BASE}"
            else
                echo "### HASH-SUFFIX RENAME + other deltas: ${F%.yml} -> ${BASE}"
                diff -u --label "orig/${F%.yml}" --label "new/${BASE}" "${A_FILE}" "${B_FILE}" || true
                echo
                RC=1
            fi
            continue
        fi
        echo "### ONLY IN ORIGINAL: ${F%.yml}"
        RC=1
        continue
    fi
    if ! diff -u "${ORIG_FILE}" "${HELM_FILE}" >/dev/null
    then
        echo "### DIFF: ${F%.yml}"
        diff -u --label "orig/${F%.yml}" --label "new/${F%.yml}" "${ORIG_FILE}" "${HELM_FILE}" || true
        echo
        RC=1
    fi
done
# Any hash-suffixed original whose static twin also existed is handled above; a
# static-named ConfigMap present ONLY in the new render is the other half of that
# pair, so don't double-report it.
if [ "${RC}" -eq 0 ]
then
    echo "No differences (identical render)."
fi
echo

# When the controller kind changed (Deployment<->StatefulSet<->DaemonSet), the
# per-resource diff above shows them only as "ONLY IN ...". Diff the POD SPECs
# directly so the meaningful container/volume/security comparison isn't skipped.
echo "==================== POD SPEC DIFF (controllers) ===================="
ORIG_POD="${WORK}/orig_pod.yaml"
HELM_POD="${WORK}/helm_pod.yaml"
PODSPEC='select(.kind=="Deployment" or .kind=="StatefulSet" or .kind=="DaemonSet") | .spec.template.spec | sort_keys(..)'
yq ea "${PODSPEC}" "${WORK}/orig.yaml" > "${ORIG_POD}" || true
yq ea "${PODSPEC}" "${WORK}/new.yaml"  > "${HELM_POD}" || true
if diff -u --label orig-pod "${ORIG_POD}" --label helm-pod "${HELM_POD}" >/dev/null
then
    echo "Pod specs IDENTICAL."
else
    echo "(expected deltas: image quoting; a volume that moved to a volumeClaimTemplate)"
    diff -u --label orig-pod "${ORIG_POD}" --label helm-pod "${HELM_POD}" || true
fi
echo "==========================================================="
echo "Reminder: a non-empty diff is EXPECTED for migrated controllers."
echo "Confirm each hunk is an intended delta, then it is safe to remove install/."
