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

cd "$(dirname "$0")/.."

CHART="charts/ddns-updater"   # deployment-agnostic; has a service + ingressRoute
fail=0

pass() { printf '  ok   - %s\n' "$1"; }
bad()  { printf '  FAIL - %s\n' "$1"; fail=1; }

# Ensure the vendored `common` library is current for this chart.
helm dependency build "$CHART" >/dev/null

echo "== toggle regression: $CHART =="

# 1) podAntiAffinity: false must drop the affinity block entirely.
if helm template "$CHART" --set podAntiAffinity=false 2>/dev/null \
     | grep -q 'podAntiAffinity:'; then
  bad "podAntiAffinity=false still rendered an affinity block"
else
  pass "podAntiAffinity=false omits the affinity block"
fi
# sanity: the default (unset / true) DOES render it, else the test is vacuous.
if helm template "$CHART" 2>/dev/null | grep -q 'podAntiAffinity:'; then
  pass "podAntiAffinity default renders the affinity block"
else
  bad "podAntiAffinity default did NOT render — test is vacuous"
fi

# 2) services[0].enabled: false must drop that Service.
if helm template "$CHART" --set services[0].enabled=false 2>/dev/null \
     | grep -qE '^kind: Service$'; then
  bad "services[0].enabled=false still rendered a Service"
else
  pass "services[0].enabled=false omits the Service"
fi
if helm template "$CHART" 2>/dev/null | grep -qE '^kind: Service$'; then
  pass "services default renders the Service"
else
  bad "services default did NOT render a Service — test is vacuous"
fi

# 3) ingressRoute.enabled: false must drop the IngressRoute.
if helm template "$CHART" --set ingressRoute.enabled=false 2>/dev/null \
     | grep -qE '^kind: IngressRoute$'; then
  bad "ingressRoute.enabled=false still rendered an IngressRoute"
else
  pass "ingressRoute.enabled=false omits the IngressRoute"
fi
if helm template "$CHART" 2>/dev/null | grep -qE '^kind: IngressRoute$'; then
  pass "ingressRoute default renders the IngressRoute"
else
  bad "ingressRoute default did NOT render an IngressRoute — test is vacuous"
fi

if [ "$fail" -ne 0 ]; then
  echo "TOGGLE REGRESSION TEST FAILED" >&2
  exit 1
fi
echo "all toggle regressions pass"
