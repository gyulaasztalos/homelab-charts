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

# 4) ingressRoute.routes[].middlewares: [] must render NO middlewares.
#
# The list-shaped sibling of the same trap: Helm's `default` treats an EMPTY LIST
# as empty, so `$route.middlewares | default (list authentik default-headers)`
# returned the auth pair for `middlewares: []` exactly as it did for an absent
# key. The documented "set [] to drop auth" silently did the opposite. `hasKey`
# is the fix. Caught during the apprise migration, where two machine-facing API
# routes (/notify, /apprise) must NOT be behind authentik forward-auth —
# otherwise every notification producer in the cluster gets 302'd to a login page.
mw_fixture="$(mktemp)"; trap 'rm -f "$mw_fixture"' EXIT
cat > "$mw_fixture" <<'YAML'
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

mw_render="$(helm template "$CHART" -f "$mw_fixture" 2>/dev/null)"

# The [] route must have no middlewares; the sibling route (key absent) must keep
# the default pair — so the assertion cannot pass by dropping middlewares wholesale.
noauth_mw="$(printf '%s' "$mw_render" | yq ea 'select(.kind=="IngressRoute") | .spec.routes[] | select(.match == "Host(`noauth.example.com`) && PathPrefix(`/notify`)") | (.middlewares // []) | length' - 2>/dev/null)"
guarded_mw="$(printf '%s' "$mw_render" | yq ea 'select(.kind=="IngressRoute") | .spec.routes[] | select(.match == "Host(`guarded.example.com`)") | (.middlewares // []) | length' - 2>/dev/null)"

if [ "$noauth_mw" = "0" ]; then
  pass "middlewares: [] renders NO middlewares"
else
  bad "middlewares: [] still rendered $noauth_mw middleware(s) — the default leaked back in"
fi
if [ "$guarded_mw" = "2" ]; then
  pass "omitted middlewares still defaults to authentik + default-headers"
else
  bad "omitted middlewares rendered $guarded_mw middleware(s), expected 2 — test is vacuous"
fi

# 5) pathPrefix must extend the match rather than replace it.
if printf '%s' "$mw_render" | grep -qF 'Host(`noauth.example.com`) && PathPrefix(`/notify`)'; then
  pass "pathPrefix extends the match expression"
else
  bad "pathPrefix did not produce Host(...) && PathPrefix(...)"
fi
if printf '%s' "$mw_render" | grep -qF 'match: Host(`guarded.example.com`)'; then
  pass "a route without pathPrefix matches on host alone"
else
  bad "route without pathPrefix did not match on host alone — test is vacuous"
fi

if [ "$fail" -ne 0 ]; then
  echo "TOGGLE REGRESSION TEST FAILED" >&2
  exit 1
fi
echo "all toggle regressions pass"
