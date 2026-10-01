#!/bin/bash

# Copyright (c) 2024-2026 Hopsworks AB. All rights reserved.



# Tests for the RDRS dedicated probe port (rdrs.probePort). Needs only helm
# and bash - no cluster.
#
# Part 1 - enabled (default; releases pair the chart with a probe-capable
#   image): every probe (startup, liveness, readiness) points at the probe
#   port, the container exposes it, the rendered rest_api.json carries
#   ProbeEnable/ProbePort, and - deliberately - no Service, Ingress or
#   TargetGroupBinding exposes it (the port serves ping/health WITHOUT
#   authentication and must stay pod-local).
# Part 2 - disabled: the escape hatch for pinned RDRS images that predate
#   REST.ProbePort. No probe configuration keys may be emitted (the old
#   strict config parser rejects unknown keys at startup) and every probe
#   reverts to the main port. Also: nulling probePort or either of its keys
#   must fail schema validation, not render port 0.
# Part 3 - TLS: the probe port mirrors the main listener's TLS, so the
#   probes' scheme must be HTTPS exactly when endToEndTls is enabled.
# Part 4 - rdrs.maxKeepaliveRequests: disabled by default, meaning the key
#   must not be emitted at all (old strict config parsers reject unknown
#   keys); when set, it lands in rest_api.json.

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

render() { # <output-file> [extra helm args...]
  local out="$1"; shift
  helm template t "$CHART" -s templates/rdrs.yaml "$@" \
    > "$out" 2> "$out.err" \
    || { echo "helm template failed:"; tail -5 "$out.err"; exit 1; }
}

# probe_port <probe-name> <rendered-file>: the port of the probe's httpGet.
probe_port() {
  awk -v probe="$1:" '
    $0 ~ probe {inprobe=1; next}
    inprobe && /port:/ {print $2; exit}
  ' "$2"
}

echo "Part 1 - probe port enabled (default)"
DEFAULT="$WORK_DIR/default.yaml"
render "$DEFAULT"

assert "startup probe on the probe port" \
  '[ "$(probe_port startupProbe "$DEFAULT")" = "4407" ]'
assert "liveness probe on the probe port" \
  '[ "$(probe_port livenessProbe "$DEFAULT")" = "4407" ]'
assert "readiness probe on the probe port" \
  '[ "$(probe_port readinessProbe "$DEFAULT")" = "4407" ]'
assert "all probes keep the ping/health paths" \
  '[ "$(grep -c "path: \"0.1.0/ping\"\|path: \"0.1.0/health\"" "$DEFAULT")" = "3" ]'
assert "container exposes the probe port" \
  'grep -A1 "name: probe" "$DEFAULT" | grep -q "containerPort: 4407"'
assert "rest_api.json enables the probe listener" \
  'grep -q "\"ProbeEnable\": true" "$DEFAULT"'
assert "rest_api.json carries the probe port" \
  'grep -q "\"ProbePort\": 4407" "$DEFAULT"'
# The Services in rdrs.yaml must NOT publish the (unauthenticated) probe
# port: kubelet probes hit the pod IP directly and need no Service.
assert "no Service publishes the probe port" \
  '! awk "/kind: Service/,/^---/" "$DEFAULT" | grep -q "4407"'
# rdrs2 REFUSES TO START when the probe port is combined with
# PingRequiresAuth/HealthRequiresAuth (the probe port never authenticates).
# The chart must therefore never emit those keys while the probe port is on.
assert "no ping/health auth flags emitted with the probe port" \
  '! grep -qE "PingRequires|HealthRequires" <(awk "/rest_api.json: \|/,/^---/" "$DEFAULT")'
# Render the ingress ALONE to a file, failing loudly: piping the render
# straight into a NEGATED grep would report success when the render itself
# fails (no output -> no match). Cannot use render(): it always includes
# templates/rdrs.yaml, which legitimately contains the probe port.
INGRESS="$WORK_DIR/ingress.yaml"
helm template t "$CHART" -s templates/rdrs_ingress.yaml \
  --set meta.rdrs.ingress.enabled=true > "$INGRESS" 2> "$INGRESS.err" \
  || { echo "helm template failed:"; tail -5 "$INGRESS.err"; exit 1; }
assert "an ingress document was rendered" \
  'grep -q "kind: Ingress" "$INGRESS"'
assert "ingress does not reference the probe port" \
  '! grep -q 4407 "$INGRESS"'

echo "Part 2 - probe port disabled (old-image escape hatch)"
DISABLED="$WORK_DIR/disabled.yaml"
render "$DISABLED" --set rdrs.probePort.enabled=false

assert "startup probe back on the main port" \
  '[ "$(probe_port startupProbe "$DISABLED")" = "4406" ]'
assert "liveness probe back on the main port" \
  '[ "$(probe_port livenessProbe "$DISABLED")" = "4406" ]'
assert "readiness probe back on the main port" \
  '[ "$(probe_port readinessProbe "$DISABLED")" = "4406" ]'
# Scope to the ConfigMap block-scalar only: the bare filename also appears in
# the StatefulSet (--config path, subPath), which would re-arm the range and
# pull in the *Probe keys of the pod spec.
assert "no probe config keys emitted at all" \
  '! grep -q "Probe" <(awk "/rest_api.json: \|/,/^---/" "$DISABLED")'
assert "no probe containerPort" \
  '! grep -q "containerPort: 4407" "$DISABLED"'

# `null` is the usual Helm idiom for dropping an override, and Helm deletes
# null keys BEFORE schema validation, so the minimum/maximum bounds never see
# them: without the required-keys guard, probePort.port=null rendered the
# probes, the containerPort and REST.ProbePort all as port 0, and
# probePort=null died with a nil-pointer template error instead of a schema
# message naming the key.
assert "null probePort.port is rejected by the schema" \
  '! helm template t "$CHART" --set rdrs.probePort.port=null \
     -s templates/rdrs.yaml >/dev/null 2>&1'
assert "null probePort.enabled is rejected by the schema" \
  '! helm template t "$CHART" --set rdrs.probePort.enabled=null \
     -s templates/rdrs.yaml >/dev/null 2>&1'
assert "null probePort (whole key) is rejected by the schema" \
  '! helm template t "$CHART" --set rdrs.probePort=null \
     -s templates/rdrs.yaml >/dev/null 2>&1'

echo "Part 3 - TLS mirroring"
TLS="$WORK_DIR/tls.yaml"
render "$TLS" --values "$CHART/values/end_to_end_tls.yaml"

assert "all three probes use HTTPS with endToEndTls" \
  '[ "$(awk "/startupProbe|livenessProbe|readinessProbe/,/timeoutSeconds/" "$TLS" | grep -c "scheme: HTTPS")" = "3" ]'
assert "probes stay on the probe port under TLS" \
  '[ "$(probe_port livenessProbe "$TLS")" = "4407" ]'

echo "Part 4 - maxKeepaliveRequests"
KAR="$WORK_DIR/kar.yaml"
render "$KAR" --set rdrs.maxKeepaliveRequests=1000

assert "key not emitted when disabled (default)" \
  '! grep -q "MaxKeepaliveRequests" <(awk "/rest_api.json: \|/,/^---/" "$DISABLED")'
assert "key emitted with the configured value" \
  'grep -q "\"MaxKeepaliveRequests\": 1000" <(awk "/rest_api.json: \|/,/^---/" "$KAR")'
# RDRS parses the key as a 32-bit unsigned: anything larger passes rendering
# but makes RDRS fail startup with an out-of-range config error, so the
# schema must reject it at validation time instead.
assert "a value above uint32 is rejected by the schema" \
  '! helm template t "$CHART" --set rdrs.maxKeepaliveRequests=4294967296 \
     -s templates/rdrs.yaml >/dev/null 2>&1'
assert "the uint32 maximum itself still validates" \
  'helm template t "$CHART" --set rdrs.maxKeepaliveRequests=4294967295 \
     -s templates/rdrs.yaml >/dev/null 2>&1'

echo "Part 5 - uploadPath"
# Default: RDRS buffers oversized request bodies under a writable dir; an
# unwritable one silently EMPTIES bodies over 64KiB (prod, 2026-09-24).
assert "UploadPath emitted by default" \
  'grep -q "\"UploadPath\": \"/tmp/rdrs-uploads\"" <(awk "/rest_api.json: \|/,/^---/" "$DEFAULT")'
UPL_OFF="$WORK_DIR/upl_off.yaml"
render "$UPL_OFF" --set rdrs.uploadPath=""
assert "key not emitted when empty (old-image escape hatch)" \
  '! grep -q "UploadPath" <(awk "/rest_api.json: \|/,/^---/" "$UPL_OFF")'

echo "Part 5b - rest_api.json hash annotation"
# rest_api.json is mounted via subPath (never live-updates): the pod
# template must carry a hash of the rendered file so a values change
# touching only the REST config actually rolls the rdrs pods.
hash_of() { grep "restApiHash:" "$1" | head -1 | awk '{print $2}'; }
assert "rdrs pod template carries restApiHash" \
  '[ -n "$(hash_of "$DEFAULT")" ]'
assert "a REST-only values change rolls the rdrs pods (hash differs)" \
  '[ "$(hash_of "$DEFAULT")" != "$(hash_of "$KAR")" ]'

echo "Part 6 - in-cluster probe-ports helm test hook"
HOOK="$WORK_DIR/hook.yaml"
helm template t "$CHART" -s templates/tests/rdrs_probe_ports.yaml \
  > "$HOOK" 2> "$HOOK.err" \
  || { echo "helm template failed:"; tail -5 "$HOOK.err"; exit 1; }
assert "hook rendered by default" 'grep -q "kind: Pod" "$HOOK"'
# The hook must run on the TOOLBOX image: rondb images are stripped (26.02
# ships neither openssl nor curl), so the TLS probe path would silently
# report 000 for every attempt (CI run 36852477750).
assert "hook runs on the toolbox image, not the rondb image" \
  'grep -A1 "name: rdrs-probe-ports-test" "$HOOK" | grep "image:" | grep -q "hwutils"'
assert "hook fails loudly when a required client is missing" \
  'grep -q "required tool(s) missing" "$HOOK"'
# The escape hatch must be typo-proof: rdrs.probePort rejects unknown keys,
# so `--set rdrs.probePort.enable=false` (missing the trailing d) fails the
# schema instead of silently leaving the probe port on - which would
# crash-loop a pinned old image that rejects the probe config keys.
assert "unknown probePort keys are rejected by the schema" \
  '! helm template t "$CHART" -s templates/rdrs.yaml \
     --set rdrs.probePort.enable=false >/dev/null 2>&1'
# The test image can come from a private registry, exactly like the RDRS
# StatefulSet's - without the pull secrets the hook dies in
# ImagePullBackOff instead of testing anything.
assert "hook honours imagePullSecrets" \
  'helm template t "$CHART" -s templates/tests/rdrs_probe_ports.yaml \
     --set "imagePullSecrets[0].name=regcred" | grep -q "name: regcred"'
# minNumRdrs: 0 means zero RDRS pods may legitimately exist; a
# connectivity test that requires nothing passes vacuously, so the hook
# must not render at all.
assert "hook skipped when minNumRdrs=0" \
  '! helm template t "$CHART" -s templates/tests/rdrs_probe_ports.yaml \
     --set clusterSize.minNumRdrs=0 2>/dev/null | grep -q "kind: Pod"'

echo
echo "passed: $PASS failed: $FAIL"
[ "$FAIL" = "0" ]
