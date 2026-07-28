#!/usr/bin/env bash
# =============================================================================
# diff-charts.sh [ref] [chart ...]
#
# REGRESSION GATE for changes to charts that are ALREADY LIVE.
#
# Once an app has been migrated and verified in production, that chart's render
# IS the proven baseline — the old install/ manifests are irrelevant from then on
# (that is what tests/diff-migration.sh is for, and it is a ONE-TIME gate, run
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

FAIL_ON_CHANGE=0
ARGS=()
for A in "$@"
do
    case "${A}" in
        --fail-on-change)
            FAIL_ON_CHANGE=1
            ;;
        -h|--help)
            sed -n '2,40p' "${0}"
            exit 0
            ;;
        *)
            ARGS+=("${A}")
            ;;
    esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}

REF="${1:-HEAD}"
shift || true
ONLY_CHARTS=("$@")

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARGOCD="${ARGOCD_REPO:-${REPO_ROOT}/../ArgoCD}"

if ! command -v helm >/dev/null
then
    echo "ERROR: helm is required" >&2
    exit 3
fi
if ! git -C "${REPO_ROOT}" rev-parse --verify "${REF}" >/dev/null 2>&1
then
    echo "ERROR: not a valid git ref: ${REF}" >&2
    exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/base"

# Baseline: the whole charts/ tree as of <ref>, so file://../common resolves.
git -C "${REPO_ROOT}" archive "${REF}" charts | tar -x -C "${WORK}/base"

# Render <chart-dir> into <out>, optionally with a tailored values file.
function render {
    local DIR="${1}" NAME="${2}" OUT="${3}" VALUES="${4:-}"
    local VARGS=()
    if [ -n "${VALUES}" ]
    then
        VARGS=(-f "${VALUES}")
    fi
    # Wipe vendored deps + lock so each side ALWAYS re-vendors `common` fresh from
    # file://../common. Without this, `helm dependency build` reuses a stale
    # charts/common-*.tgz left on disk, so the working-tree side can silently render
    # against an OLD common while the baseline re-vendors the new one — producing a
    # spurious "CHANGED" for charts you never touched (seen after a common bump).
    rm -rf "${DIR}/charts" "${DIR}/Chart.lock"
    helm dependency build "${DIR}" >/dev/null 2>&1 || true
    if ! helm template "${NAME}" "${DIR}" ${VARGS[@]+"${VARGS[@]}"} > "${OUT}" 2>"${OUT}.err"
    then
        echo "RENDER FAILED"
        sed 's/^/      /' "${OUT}.err" >&2
        return 1
    fi
    return 0
}

# Chart list: union of both sides, minus the library chart (it renders nothing on
# its own — its changes surface through the wrappers, which is the whole point).
function list_charts {
    { ls -1 "${REPO_ROOT}/charts" 2>/dev/null; ls -1 "${WORK}/base/charts" 2>/dev/null; } \
        | sort -u | grep -v '^common$'
}
CHARTS="$(list_charts)"
if [ ${#ONLY_CHARTS[@]} -gt 0 ]
then
    CHARTS="$(printf '%s\n' "${ONLY_CHARTS[@]}")"
fi

echo "baseline ref : ${REF}  ($(git -C "${REPO_ROOT}" log -1 --format='%h %s' "${REF}"))"
echo "working tree : ${REPO_ROOT}"
echo "gitops repo  : ${ARGOCD}"
echo

# Call out library changes up front — that is the high blast-radius case.
if ! git -C "${REPO_ROOT}" diff --quiet "${REF}" -- charts/common 2>/dev/null
then
    echo "!! charts/common CHANGED since ${REF} — every chart below is re-rendered by it."
    git -C "${REPO_ROOT}" diff --stat "${REF}" -- charts/common | sed 's/^/   /'
    echo
fi

SUMMARY=""
CHANGED_ANY=0

for NAME in ${CHARTS}
do
    CUR_DIR="${REPO_ROOT}/charts/${NAME}"
    BASE_DIR="${WORK}/base/charts/${NAME}"
    VALUES="${ARGOCD}/apps/${NAME}/values.yaml"

    if [ ! -d "${BASE_DIR}" ]
    then
        SUMMARY="${SUMMARY}\n  NEW        ${NAME} (does not exist at ${REF} — nothing to compare)"
        continue
    fi
    if [ ! -d "${CUR_DIR}" ]
    then
        SUMMARY="${SUMMARY}\n  REMOVED    ${NAME} (present at ${REF}, gone from the working tree)"
        CHANGED_ANY=1
        continue
    fi

    for MODE in generic deployed
    do
        VFILE=""
        if [ "${MODE}" = deployed ]
        then
            if [ ! -f "${VALUES}" ]
            then
                continue
            fi
            VFILE="${VALUES}"
        fi
        BASE_OUT="${WORK}/${NAME}.${MODE}.base"
        CUR_OUT="${WORK}/${NAME}.${MODE}.cur"
        if ! render "${BASE_DIR}" "${NAME}" "${BASE_OUT}" "${VFILE}"
        then
            SUMMARY="${SUMMARY}\n  ERROR      ${NAME} (${MODE}, baseline)"
            CHANGED_ANY=1
            continue
        fi
        if ! render "${CUR_DIR}" "${NAME}" "${CUR_OUT}" "${VFILE}"
        then
            SUMMARY="${SUMMARY}\n  ERROR      ${NAME} (${MODE}, current)"
            CHANGED_ANY=1
            continue
        fi

        if diff -q "${BASE_OUT}" "${CUR_OUT}" >/dev/null
        then
            SUMMARY="${SUMMARY}\n  identical  ${NAME} (${MODE})"
        else
            CHANGED_ANY=1
            SUMMARY="${SUMMARY}\n  CHANGED    ${NAME} (${MODE})"
            echo "======================================================================"
            echo "### CHANGED: ${NAME}  [${MODE} render]"
            if [ -n "${VFILE}" ]
            then
                echo "###          values: ${VFILE}"
            fi
            echo "======================================================================"
            diff -u --label "${REF}/${NAME}" --label "worktree/${NAME}" "${BASE_OUT}" "${CUR_OUT}" || true
            echo
        fi
    done
done

echo "==================== SUMMARY ===================="
printf '%b\n' "${SUMMARY# }"
echo
if [ "${CHANGED_ANY}" -eq 0 ]
then
    echo "No render changes: every chart produces byte-identical output vs ${REF}."
else
    echo "Some charts render differently vs ${REF}."
    echo "Confirm EVERY chart listed as CHANGED is one you meant to change — an app"
    echo "you did not touch appearing here means a charts/common edit leaked into it."
fi

if [ "${FAIL_ON_CHANGE}" -eq 1 ] && [ "${CHANGED_ANY}" -ne 0 ]
then
    exit 1
fi
exit 0
