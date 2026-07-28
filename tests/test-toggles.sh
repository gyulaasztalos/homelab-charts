#!/usr/bin/env bash
# =============================================================================
# test-toggles.sh — regression test for the Helm "default-true boolean" trap.
#
# `false | default true` evaluates to TRUE in Helm (default() treats the Go
# zero value `false` as empty). Several common-chart toggles are meant to be
# OFF when a chart sets them to `false` — podAntiAffinity, services[].enabled,
# ingressRoute.enabled. This test renders a real chart with each toggle forced
# false and asserts the corresponding block is ABSENT from the output, so a
# regression to `| default true` fails CI instead of shipping an unwanted
# object (this bug was caught by hand during the vcgen-exporter migration).
#
# LOCAL + CI. No cluster required — pure `helm template` + grep.
# =============================================================================
set -euo pipefail

cd "$(dirname "${0}")/.."

CHART="charts/ddns-updater"   # deployment-agnostic; has a service + ingressRoute
FAILED=0

function pass {
    printf '  ok   - %s\n' "${1}"
}

function bad {
    printf '  FAIL - %s\n' "${1}"
    FAILED=1
}

# Ensure the vendored `common` library is current for this chart. Chart.lock is a
# disposable build artifact; a stale one (pinning an older common after a bump)
# makes `dependency build` refuse with "out of sync". Drop it so the build
# resolves the current common — the same lockless path CI uses on a fresh checkout.
rm -f "${CHART}/Chart.lock"
helm dependency build "${CHART}" >/dev/null

echo "== toggle regression: ${CHART} =="

# 1) podAntiAffinity: false must drop the affinity block entirely.
if helm template "${CHART}" --set podAntiAffinity=false 2>/dev/null | grep -q 'podAntiAffinity:'
then
    bad "podAntiAffinity=false still rendered an affinity block"
else
    pass "podAntiAffinity=false omits the affinity block"
fi
# sanity: the default (unset / true) DOES render it, else the test is vacuous.
if helm template "${CHART}" 2>/dev/null | grep -q 'podAntiAffinity:'
then
    pass "podAntiAffinity default renders the affinity block"
else
    bad "podAntiAffinity default did NOT render — test is vacuous"
fi

# 2) services[0].enabled: false must drop that Service.
if helm template "${CHART}" --set services[0].enabled=false 2>/dev/null | grep -qE '^kind: Service$'
then
    bad "services[0].enabled=false still rendered a Service"
else
    pass "services[0].enabled=false omits the Service"
fi
if helm template "${CHART}" 2>/dev/null | grep -qE '^kind: Service$'
then
    pass "services default renders the Service"
else
    bad "services default did NOT render a Service — test is vacuous"
fi

# 3) ingressRoute.enabled: false must drop the IngressRoute.
if helm template "${CHART}" --set ingressRoute.enabled=false 2>/dev/null | grep -qE '^kind: IngressRoute$'
then
    bad "ingressRoute.enabled=false still rendered an IngressRoute"
else
    pass "ingressRoute.enabled=false omits the IngressRoute"
fi
if helm template "${CHART}" 2>/dev/null | grep -qE '^kind: IngressRoute$'
then
    pass "ingressRoute default renders the IngressRoute"
else
    bad "ingressRoute default did NOT render an IngressRoute — test is vacuous"
fi

# 4) ingressRoute.routes[].middlewares: [] must render NO middlewares.
#
# The list-shaped sibling of the same trap: Helm's `default` treats an EMPTY LIST
# as empty, so `$route.middlewares | default (list authentik default-headers)`
# returned the auth pair for `middlewares: []` exactly as it did for an absent
# key. The documented "set [] to drop auth" silently did the opposite. `hasKey`
# is the fix. Caught during the apprise migration, where two machine-facing API
# routes (/notify, /apprise) must NOT be behind authentik forward-auth —
# otherwise every notification producer in the cluster gets 302'd to a login page.
MW_FIXTURE="$(mktemp)"
JOBS_FIXTURE="$(mktemp)"
trap 'rm -f "${MW_FIXTURE}" "${JOBS_FIXTURE}"' EXIT
cat > "${MW_FIXTURE}" <<'YAML'
ingressRoute:
  enabled: true
  routes:
    - host: noauth.example.com
      port: 8000
      pathPrefix: /notify
      middlewares: []
    - host: guarded.example.com
      port: 8000
YAML

MW_RENDER="$(helm template "${CHART}" -f "${MW_FIXTURE}" 2>/dev/null)"

# The [] route must have no middlewares; the sibling route (key absent) must keep
# the default pair — so the assertion cannot pass by dropping middlewares wholesale.
NOAUTH_MW="$(printf '%s' "${MW_RENDER}" | yq ea 'select(.kind=="IngressRoute") | .spec.routes[] | select(.match == "Host(`noauth.example.com`) && PathPrefix(`/notify`)") | (.middlewares // []) | length' -)"
GUARDED_MW="$(printf '%s' "${MW_RENDER}" | yq ea 'select(.kind=="IngressRoute") | .spec.routes[] | select(.match == "Host(`guarded.example.com`)") | (.middlewares // []) | length' -)"

if [ "${NOAUTH_MW}" = "0" ]
then
    pass "middlewares: [] renders NO middlewares"
else
    bad "middlewares: [] still rendered ${NOAUTH_MW} middleware(s) — the default leaked back in"
fi
if [ "${GUARDED_MW}" = "2" ]
then
    pass "omitted middlewares still defaults to authentik + default-headers"
else
    bad "omitted middlewares rendered ${GUARDED_MW} middleware(s), expected 2 — test is vacuous"
fi

# 5) pathPrefix must extend the match rather than replace it.
if printf '%s' "${MW_RENDER}" | grep -qF 'Host(`noauth.example.com`) && PathPrefix(`/notify`)'
then
    pass "pathPrefix extends the match expression"
else
    bad "pathPrefix did not produce Host(...) && PathPrefix(...)"
fi
if printf '%s' "${MW_RENDER}" | grep -qF 'match: Host(`guarded.example.com`)'
then
    pass "a route without pathPrefix matches on host alone"
else
    bad "route without pathPrefix did not match on host alone — test is vacuous"
fi

# 6) jobs: / cronJobs: — batch workloads (common >= 0.6.0).
#    (a) empty/absent renders none (the additivity guarantee).
#    (b) a jobs[0]/cronJobs[0] entry renders a Job and a CronJob.
#    (c) the job pod carries app.kubernetes.io/name but NOT `app`. This is the
#        guard against the TargetDown scrape bug: the app Service selects
#        `app: <name>`, so a running job pod carrying `app` becomes a Service
#        endpoint and Prometheus scrapes it on a metrics port it never serves.
#    (d) a job's image DEFAULTS to the app image — the "lockstep" win (no more
#        hardcoded, manually-synced image tags on migrate/maintenance jobs).
cat > "${JOBS_FIXTURE}" <<'YAML'
jobs:
  - name: ddns-updater-migrate
    command: ["true"]
cronJobs:
  - name: ddns-updater-sweep
    schedule: "0 3 * * *"
    command: ["true"]
YAML
JOBS_RENDER="$(helm template "${CHART}" -f "${JOBS_FIXTURE}" 2>/dev/null)"

# (a) additivity: the default render (empty jobs:/cronJobs:) emits no batch object.
if helm template "${CHART}" 2>/dev/null | grep -qE '^kind: (Job|CronJob)$'
then
    bad "empty jobs:/cronJobs: still emitted a Job/CronJob"
else
    pass "empty jobs:/cronJobs: emit no batch objects (additive)"
fi
# (b) the fixture renders both kinds.
JOB_COUNT="$(printf '%s' "${JOBS_RENDER}" | grep -cE '^kind: Job$' || true)"
CRONJOB_COUNT="$(printf '%s' "${JOBS_RENDER}" | grep -cE '^kind: CronJob$' || true)"
if [ "${JOB_COUNT}" -ge 1 ] && [ "${CRONJOB_COUNT}" -ge 1 ]
then
    pass "jobs:/cronJobs: entries render a Job and a CronJob"
else
    bad "jobs:/cronJobs: entries did not render both a Job and a CronJob — test is vacuous"
fi
# (c) job pod labels: app.kubernetes.io/name present, `app` ABSENT.
JOB_APP="$(printf '%s' "${JOBS_RENDER}" | yq ea 'select(.kind=="Job") | .spec.template.metadata.labels.app // "ABSENT"' -)"
JOB_NAME="$(printf '%s' "${JOBS_RENDER}" | yq ea 'select(.kind=="Job") | .spec.template.metadata.labels["app.kubernetes.io/name"] // "ABSENT"' -)"
if [ "${JOB_APP}" = "ABSENT" ] && [ "${JOB_NAME}" != "ABSENT" ]
then
    pass "job pod carries app.kubernetes.io/name but NOT app (no spurious Service scrape)"
else
    bad "job pod labels wrong: app=${JOB_APP} app.kubernetes.io/name=${JOB_NAME} (app must be ABSENT)"
fi
# (d) job image defaults to the app image.
APP_IMG="$(printf '%s' "${JOBS_RENDER}" | yq ea '.spec.template.spec.containers[]? | select(.name=="ddns-updater") | .image' - | head -1)"
JOB_IMG="$(printf '%s' "${JOBS_RENDER}" | yq ea 'select(.kind=="Job") | .spec.template.spec.containers[0].image' -)"
if [ -n "${APP_IMG}" ] && [ "${JOB_IMG}" = "${APP_IMG}" ]
then
    pass "job image defaults to the app image (${JOB_IMG})"
else
    bad "job image (${JOB_IMG}) does not match app image (${APP_IMG})"
fi

if [ "${FAILED}" -ne 0 ]
then
    echo "TOGGLE REGRESSION TEST FAILED" >&2
    exit 1
fi
echo "all toggle regressions pass"
