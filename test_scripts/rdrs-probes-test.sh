#!/bin/bash

# Copyright (c) 2024-2026 Hopsworks AB. All rights reserved.

# Tests for the values-driven RDRS probe timings (rdrs.probes).
# Needs only helm and bash — no cluster.
#
# Part 1 — defaults: each probe renders the timings from values.yaml.
# Part 2 — overrides: a single field override lands in the StatefulSet and
#   leaves the probe's other fields at their defaults; end-to-end TLS keeps
#   HTTPS on all three probes.
# Part 3 — schema: unknown fields, misspelled probe names, nulled fields and
#   out-of-range values fail the render instead of being ignored.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

PASS=0; FAIL=0
assert() { # <description> <command>
  if eval "$2"; then PASS=$((PASS + 1)); echo "  ok: $1"
  else FAIL=$((FAIL + 1)); echo "  FAIL: $1"; echo "    check: $2"; fi
}

# Render from a copy without venv/.git: helm loads every file in the chart
# directory, and a local venv makes each render take minutes.
CHART="$WORK_DIR/chart"
rsync -a --exclude venv --exclude .git --exclude .claude "$REPO_ROOT/" "$CHART/"

render() { # <output-file> [helm args...]
  local out="$1"; shift
  helm template t "$CHART" -s templates/rdrs.yaml \
    --values "$CHART/values/minikube/small.yaml" "$@" \
    > "$out" 2> "$out.err"
}

# probe_field <rendered-file> <probe-name> <field>: the field's value inside
# the probe block of the rdrs container.
probe_field() {
  awk -v probe="$2" -v field="$3" '
    $0 ~ "^        "probe":" {inprobe=1; next}
    inprobe && /^        [a-zA-Z]/ {exit}
    inprobe && $1 == field":" {print $2; exit}
  ' "$1"
}

DEFAULT="$WORK_DIR/default.yaml"
render "$DEFAULT" || { echo "helm template failed:"; tail -5 "$DEFAULT.err"; exit 1; }

echo "Part 1 - defaults"

expect() { # <rendered-file> <probe> <initialDelay> <period> <timeout> <failureThreshold>
  local file="$1" probe="$2" delay="$3" period="$4" timeout="$5" threshold="$6"
  assert "$probe initialDelaySeconds=$delay" '[ "$(probe_field "$file" "$probe" initialDelaySeconds)" = "$delay" ]'
  assert "$probe periodSeconds=$period" '[ "$(probe_field "$file" "$probe" periodSeconds)" = "$period" ]'
  assert "$probe timeoutSeconds=$timeout" '[ "$(probe_field "$file" "$probe" timeoutSeconds)" = "$timeout" ]'
  assert "$probe failureThreshold=$threshold" '[ "$(probe_field "$file" "$probe" failureThreshold)" = "$threshold" ]'
}

expect "$DEFAULT" startupProbe 5 5 2 11
expect "$DEFAULT" readinessProbe 5 5 3 3
expect "$DEFAULT" livenessProbe 5 10 5 12

echo "Part 2 - overrides"

OVERRIDE="$WORK_DIR/override.yaml"
render "$OVERRIDE" --set rdrs.probes.liveness.failureThreshold=30 \
  || { echo "helm template failed:"; tail -5 "$OVERRIDE.err"; exit 1; }
expect "$OVERRIDE" livenessProbe 5 10 5 30
expect "$OVERRIDE" readinessProbe 5 5 3 3

TLS="$WORK_DIR/tls.yaml"
render "$TLS" --values "$CHART/values/end_to_end_tls.yaml" \
  || { echo "helm template failed:"; tail -5 "$TLS.err"; exit 1; }
for probe in startupProbe readinessProbe livenessProbe; do
  assert "$probe uses HTTPS with end-to-end TLS" '[ "$(probe_field "$TLS" "$probe" scheme)" = "HTTPS" ]'
  assert "$probe uses HTTP by default" '[ "$(probe_field "$DEFAULT" "$probe" scheme)" = "HTTP" ]'
done

echo "Part 3 - schema"

REJECTED="$WORK_DIR/rejected.yaml"
rejects() { # <description> <helm --set argument>
  local set_arg="$2"
  assert "rejects $1" '! render "$REJECTED" --set "$set_arg"'
}

rejects "an unknown field" rdrs.probes.liveness.successThreshold=1
rejects "a misspelled probe name" rdrs.probes.livness.failureThreshold=30
rejects "a nulled field" rdrs.probes.liveness.periodSeconds=null
rejects "failureThreshold 0" rdrs.probes.liveness.failureThreshold=0
rejects "a string value" rdrs.probes.readiness.timeoutSeconds=3s

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
