#!/bin/bash

# Copyright (c) 2024-2026 Hopsworks AB. All rights reserved.

# Tests for the values-driven rdrs2 configuration (rdrs.rest, rdrs.rondb,
# rdrs.internal, rdrs.security.apiKey.preloadThreads, rdrs.featureStore,
# rdrs.rateLimit, rdrs.log), including the THP switch
# (rdrs.internal.disableTransparentHugePages).
# Needs only helm, bash and python3 (to parse the rendered JSON) — no cluster.
#
# Part 1 — defaults: no optional key or section is rendered, so RDRS images
#   that predate a key (they reject unknown config keys) keep starting, except
#   Internal.BufferShrinkAfterS, which the chart sets to 900.
# Part 2 — overrides: each key, alone and together with the rest of its
#   section, lands in rest_api.json under its rdrs2 name with its JSON type,
#   the RonDB retry keys in both cluster sections, and the file stays valid
#   JSON.
# Part 3 — schema: unknown fields, wrong types, out-of-range values, a log
#   level outside the chart's list and a maxBuffers rdrs2 would refuse fail
#   the render instead of being ignored.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

PASS=0; FAIL=0
# The check is evaluated with eval; helm arguments that must not be quoted
# into it are passed as positional parameters and read with "$@".
assert() { # <description> <command> [positional parameters for the command...]
  local desc="$1" check="$2"; shift 2
  if eval "$check"; then PASS=$((PASS + 1)); echo "  ok: $desc"
  else FAIL=$((FAIL + 1)); echo "  FAIL: $desc"; echo "    check: $check $*"; fi
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

# section <rendered-file> <key>...: the value at that key path of
# rest_api.json as compact JSON, "absent" when not rendered, "invalid" when
# rest_api.json is not JSON.
section() {
  python3 - "$@" <<'EOF2'
import json, re, sys
text = open(sys.argv[1]).read()
m = re.search(r"rest_api\.json: \|\n((?:        .*\n|\n)+)", text)
try:
    value = json.loads(m.group(1))
except Exception:
    print("invalid"); sys.exit()
for key in sys.argv[2:]:
    value = value.get(key) if isinstance(value, dict) else None
print("absent" if value is None else json.dumps(value, separators=(",", ":")))
EOF2
}

rendered() { # <description> <expected> <key path (space separated)> [helm args...]
  local desc="$1" expected="$2" path="$3"; shift 3
  local out="$WORK_DIR/out.yaml"
  if ! render "$out" "$@"; then
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc (render failed)"; tail -3 "$out.err"; return
  fi
  assert "$desc" '[ "$(section "$out" '"$path"')" = "$expected" ]'
}

echo "Part 1 - defaults"

DEFAULT="$WORK_DIR/default.yaml"
render "$DEFAULT" || { echo "helm template failed:"; tail -5 "$DEFAULT.err"; exit 1; }
assert "rest_api.json is valid JSON" '[ "$(section "$DEFAULT" REST)" != invalid ]'
assert "Internal carries only the chart's BufferShrinkAfterS 900 by default" '[ "$(section "$DEFAULT" Internal)" = '"'"'{"BufferShrinkAfterS":900}'"'"' ]'
rendered "bufferShrinkAfterS=null leaves Internal out" absent "Internal" --set rdrs.internal.bufferShrinkAfterS=null
assert "no RateLimit section by default" '[ "$(section "$DEFAULT" RateLimit)" = absent ]'
assert "no FeatureStore section by default" '[ "$(section "$DEFAULT" FeatureStore)" = absent ]'
assert "no NumThreads by default" '[ "$(section "$DEFAULT" REST NumThreads)" = absent ]'
assert "no RonDB retry keys by default" \
  '[ "$(section "$DEFAULT" RonDB ConnectionRetries)" = absent ] && [ "$(section "$DEFAULT" RonDBMetadataCluster OpRetryJitterInMS)" = absent ]'
assert "no APIKey PreloadThreads by default" '[ "$(section "$DEFAULT" Security APIKey PreloadThreads)" = absent ]'
assert "no Log section by default" '[ "$(section "$DEFAULT" Log)" = absent ]'

echo "Part 2 - overrides: REST"

rendered "numThreads lands under REST" '8' "REST NumThreads" --set rdrs.rest.numThreads=8
rendered "numThreads leaves Internal at its default" '{"BufferShrinkAfterS":900}' "Internal" --set rdrs.rest.numThreads=8
rendered "useCompression=false is a JSON bool" 'false' "REST UseCompression" --set rdrs.rest.useCompression=false
rendered "useSingleTransaction=false" 'false' "REST UseSingleTransaction" --set rdrs.rest.useSingleTransaction=false
rendered "idleConnectionTimeoutS" '30' "REST IdleConnectionTimeoutS" --set rdrs.rest.idleConnectionTimeoutS=30
rendered "all REST keys together, in rdrs2 key order" \
  '{"Enable":true,"ServerIP":"0.0.0.0","NumThreads":8,"UseCompression":false,"UseSingleTransaction":false,"IdleConnectionTimeoutS":30,"UploadPath":"/tmp/rdrs-uploads","ServerPort":4406}' \
  "REST" --set rdrs.rest.numThreads=8 --set rdrs.rest.useCompression=false \
  --set rdrs.rest.useSingleTransaction=false --set rdrs.rest.idleConnectionTimeoutS=30 \
  --set rdrs.probePort.enabled=false

assert "pingRequiresAuth is not a chart value" \
  '! render "$WORK_DIR/auth.yaml" --set rdrs.rest.pingRequiresAuth=true'

echo "Part 2 - overrides: RonDB (both cluster sections)"

for pair in connectionRetries=7:ConnectionRetries connectionRetryDelayInSec=2:ConnectionRetryDelayInSec \
            opRetryOnTransientErrorsCount=4:OpRetryOnTransientErrorsCount \
            opRetryInitialDelayInMS=250:OpRetryInitialDelayInMS opRetryJitterInMS=50:OpRetryJitterInMS; do
  setting="${pair%%:*}"; key="${pair##*:}"; value="${setting##*=}"
  rendered "$setting lands in RonDB" "$value" "RonDB $key" --set "rdrs.rondb.$setting"
  rendered "$setting lands in RonDBMetadataCluster" "$value" "RonDBMetadataCluster $key" --set "rdrs.rondb.$setting"
done
RONDB_ALL=(--set rdrs.rondb.connectionRetries=7 --set rdrs.rondb.connectionRetryDelayInSec=2
           --set rdrs.rondb.opRetryOnTransientErrorsCount=4 --set rdrs.rondb.opRetryInitialDelayInMS=250
           --set rdrs.rondb.opRetryJitterInMS=50)
RONDB_EXPECTED='{"ConnectionRetries":7,"ConnectionRetryDelayInSec":2,"OpRetryOnTransientErrorsCount":4,"OpRetryInitialDelayInMS":250,"OpRetryJitterInMS":50}'
# retry_keys <file> <section>: the section without the chart-managed keys.
retry_keys() {
  section "$1" "$2" | python3 -c '
import json, sys
d = json.load(sys.stdin); d.pop("Mgmds"); d.pop("ConnectionPoolSize")
print(json.dumps(d, separators=(",", ":")))'
}
ALL="$WORK_DIR/rondb.yaml"
render "$ALL" "${RONDB_ALL[@]}" || { echo "helm template failed:"; tail -5 "$ALL.err"; exit 1; }
assert "all retry keys together in RonDB, after the chart-managed keys" \
  '[ "$(retry_keys "$ALL" RonDB)" = "$RONDB_EXPECTED" ]'
assert "all retry keys together in RonDBMetadataCluster" \
  '[ "$(retry_keys "$ALL" RonDBMetadataCluster)" = "$RONDB_EXPECTED" ]'
assert "chart-managed RonDB keys are kept" \
  '[ "$(section "$ALL" RonDB ConnectionPoolSize)" = 1 ] && [ "$(section "$ALL" RonDB Mgmds)" != absent ]'
render "$ALL" "${RONDB_ALL[@]}" --set rdrs.externalMetadataCluster.mgmds[0].ip=10.0.0.1 \
  || { echo "helm template failed:"; tail -5 "$ALL.err"; exit 1; }
assert "all retry keys in an external RonDBMetadataCluster" \
  '[ "$(retry_keys "$ALL" RonDBMetadataCluster)" = "$RONDB_EXPECTED" ]'
assert "the external metadata cluster keeps its Mgmds" \
  'grep -q "\"IP\": \"10.0.0.1\"" "$ALL"'

echo "Part 2 - overrides: Internal"

rendered "maxHttpReqSize" '{"MaxHttpReqSize":2097152,"BufferShrinkAfterS":900}' "Internal" --set rdrs.internal.maxHttpReqSize=2097152
rendered "scanRespBufferSize alone" '{"ScanRespBufferSize":4096,"BufferShrinkAfterS":900}' "Internal" --set rdrs.internal.scanRespBufferSize=4096
rendered "scanTimingEnabled=true is a JSON bool" '{"ScanTimingEnabled":true,"BufferShrinkAfterS":900}' "Internal" --set rdrs.internal.scanTimingEnabled=true
rendered "slowScanThresholdUs alone" '{"SlowScanThresholdUs":5000,"BufferShrinkAfterS":900}' "Internal" --set rdrs.internal.slowScanThresholdUs=5000
rendered "slowScanBufferSize alone" '{"SlowScanBufferSize":100,"BufferShrinkAfterS":900}' "Internal" --set rdrs.internal.slowScanBufferSize=100
rendered "preAllocatedBuffers alone" '{"PreAllocatedBuffers":8,"BufferShrinkAfterS":900}' "Internal" --set rdrs.internal.preAllocatedBuffers=8
rendered "maxBuffers alone" '{"MaxBuffers":256,"BufferShrinkAfterS":900}' "Internal" --set rdrs.internal.maxBuffers=256
rendered "maxBuffers equal to preAllocatedBuffers" '{"PreAllocatedBuffers":4,"MaxBuffers":4,"BufferShrinkAfterS":900}' "Internal" --set rdrs.internal.maxBuffers=4 --set rdrs.internal.preAllocatedBuffers=4
rendered "maxBuffers=0 (derived) is rendered, not dropped" '{"MaxBuffers":0,"BufferShrinkAfterS":900}' "Internal" --set rdrs.internal.maxBuffers=0
rendered "bufferPoolSharePercent alone" '{"BufferPoolSharePercent":40,"BufferShrinkAfterS":900}' "Internal" --set rdrs.internal.bufferPoolSharePercent=40
rendered "bufferShrinkAfterS=0 (disabled) is rendered" '{"BufferShrinkAfterS":0}' "Internal" --set rdrs.internal.bufferShrinkAfterS=0
rendered "maxOperationsPerBatchRequest alone" '{"BufferShrinkAfterS":900,"MaxOperationsPerBatchRequest":100}' "Internal" --set rdrs.internal.maxOperationsPerBatchRequest=100
rendered "maxBlobTextValueBytes alone" '{"MaxBlobTextValueBytes":4194304,"BufferShrinkAfterS":900}' "Internal" --set rdrs.internal.maxBlobTextValueBytes=4194304
rendered "maxBlobTextValueBytes=0 (no limit) is rendered" '{"MaxBlobTextValueBytes":0,"BufferShrinkAfterS":900}' "Internal" --set rdrs.internal.maxBlobTextValueBytes=0
rendered "maxBlobTextValueBytes at the 32-bit maximum is an integer" '{"MaxBlobTextValueBytes":4294967295,"BufferShrinkAfterS":900}' "Internal" --set rdrs.internal.maxBlobTextValueBytes=4294967295
rendered "maxOperationsPerNdbExecute alone" '{"BufferShrinkAfterS":900,"MaxOperationsPerNdbExecute":64}' "Internal" --set rdrs.internal.maxOperationsPerNdbExecute=64
rendered "operationIdMaxSize lands as OperationIDMaxSize" '{"BufferShrinkAfterS":900,"OperationIDMaxSize":512}' "Internal" --set rdrs.internal.operationIdMaxSize=512
rendered "all Internal keys together, in rdrs2 key order" \
  '{"MaxHttpReqSize":2097152,"MaxBlobTextValueBytes":4194304,"ScanRespBufferSize":4096,"ScanTimingEnabled":false,"SlowScanThresholdUs":5000,"SlowScanBufferSize":100,"PreAllocatedBuffers":8,"DisableTransparentHugePages":false,"MaxBuffers":256,"BufferPoolSharePercent":40,"BufferShrinkAfterS":30,"MaxOperationsPerBatchRequest":100,"MaxOperationsPerNdbExecute":64,"OperationIDMaxSize":512}' \
  "Internal" --set rdrs.internal.maxHttpReqSize=2097152 --set rdrs.internal.maxBlobTextValueBytes=4194304 \
  --set rdrs.internal.scanRespBufferSize=4096 \
  --set rdrs.internal.scanTimingEnabled=false --set rdrs.internal.slowScanThresholdUs=5000 \
  --set rdrs.internal.slowScanBufferSize=100 --set rdrs.internal.preAllocatedBuffers=8 \
  --set rdrs.internal.disableTransparentHugePages=false \
  --set rdrs.internal.maxBuffers=256 --set rdrs.internal.bufferPoolSharePercent=40 \
  --set rdrs.internal.bufferShrinkAfterS=30 --set rdrs.internal.maxOperationsPerBatchRequest=100 \
  --set rdrs.internal.maxOperationsPerNdbExecute=64 --set rdrs.internal.operationIdMaxSize=512
rendered "an explicit null renders nothing" absent "Internal" --set rdrs.internal.maxBuffers=null --set rdrs.internal.bufferShrinkAfterS=null
rendered "internal.disableTransparentHugePages=false tells rdrs2 to allow THP" '{"DisableTransparentHugePages":false,"BufferShrinkAfterS":900}' "Internal" --set rdrs.internal.disableTransparentHugePages=false
rendered "internal.disableTransparentHugePages=true renders as set" '{"DisableTransparentHugePages":true,"BufferShrinkAfterS":900}' "Internal" --set rdrs.internal.disableTransparentHugePages=true

echo "Part 2 - overrides: Security, FeatureStore, RateLimit, Log"

rendered "apiKey.preloadThreads lands under Security.APIKey" '5' "Security APIKey PreloadThreads" \
  --set rdrs.security.apiKey.preloadThreads=5
rendered "apiKey.preloadThreads keeps CacheRefreshIntervalMS" '180000' "Security APIKey CacheRefreshIntervalMS" \
  --set rdrs.security.apiKey.preloadThreads=5
rendered "featureStore.metadataCachePreloadThreads" '{"FeatureStoreMetadataCache":{"PreloadThreads":6}}' "FeatureStore" \
  --set rdrs.featureStore.metadataCachePreloadThreads=6
rendered "rateLimit.enable alone" '{"Enable":true}' "RateLimit" --set rdrs.rateLimit.enable=true
rendered "rateLimit.fullApiKey=false alone is rendered" '{"FullAPIKey":false}' "RateLimit" --set rdrs.rateLimit.fullApiKey=false
rendered "both RateLimit keys" '{"Enable":true,"FullAPIKey":true}' "RateLimit" \
  --set rdrs.rateLimit.enable=true --set rdrs.rateLimit.fullApiKey=true
rendered "log.level=debug" '"debug"' "Log Level" --set rdrs.log.level=debug
rendered "log.level=null renders no Log section" absent "Log" --set rdrs.log.level=null
rendered "log.level=warning (accepted alias)" '"warning"' "Log Level" --set rdrs.log.level=warning

echo "Part 3 - schema"

REJECTED="$WORK_DIR/rejected.yaml"
rejects() { # <description> <helm args...>
  local desc="$1"; shift
  assert "rejects $desc" '! render "$REJECTED" "$@"' "$@"
}

rejects "a misspelled rest field" --set rdrs.rest.numThread=8
rejects "a misspelled internal field" --set rdrs.internal.maxBuffer=8
rejects "a misspelled rondb field" --set rdrs.rondb.connectionRetry=1
rejects "a misspelled featureStore field" --set rdrs.featureStore.preloadThreads=3
rejects "a misspelled rateLimit field" --set rdrs.rateLimit.enabled=true
rejects "a misspelled log field" --set rdrs.log.levels=info
rejects "a non-integer count" --set rdrs.internal.maxBuffers=many
rejects "a string for a bool" --set rdrs.rest.useCompression=yes
rejects "a string for disableTransparentHugePages" --set rdrs.internal.disableTransparentHugePages=no
rejects "a bool for an integer" --set rdrs.rest.numThreads=true
rejects "an integer for a bool" --set rdrs.rateLimit.enable=1
rejects "numThreads 1 (rdrs2 needs at least 2)" --set rdrs.rest.numThreads=1
rejects "numThreads 992" --set rdrs.rest.numThreads=992
rejects "a negative idleConnectionTimeoutS" --set rdrs.rest.idleConnectionTimeoutS=-1
rejects "maxHttpReqSize 255" --set rdrs.internal.maxHttpReqSize=255
rejects "maxHttpReqSize above 32 bits" --set rdrs.internal.maxHttpReqSize=4294967296
rejects "maxBlobTextValueBytes above 32 bits" --set rdrs.internal.maxBlobTextValueBytes=4294967296
rejects "a retry count above 32 bits" --set rdrs.rondb.connectionRetries=4294967296
rejects "the old maxReqSize value name" --set rdrs.internal.maxReqSize=2097152
rejects "scanRespBufferSize 1023" --set rdrs.internal.scanRespBufferSize=1023
rejects "a negative count" --set rdrs.internal.preAllocatedBuffers=-1
rejects "bufferPoolSharePercent 0" --set rdrs.internal.bufferPoolSharePercent=0
rejects "bufferPoolSharePercent above 90" --set rdrs.internal.bufferPoolSharePercent=91
rejects "maxBlobTextValueBytes -1" --set rdrs.internal.maxBlobTextValueBytes=-1
rejects "maxOperationsPerNdbExecute 49" --set rdrs.internal.maxOperationsPerNdbExecute=49
rejects "maxOperationsPerNdbExecute 513" --set rdrs.internal.maxOperationsPerNdbExecute=513
rejects "maxOperationsPerBatchRequest 0" --set rdrs.internal.maxOperationsPerBatchRequest=0
rejects "the removed batchMaxSize" --set rdrs.internal.batchMaxSize=128
rejects "the old Go server keys (see the README upgrade note)" --set rdrs.internal.bufferSize=40960 --set rdrs.internal.gomaxprocs=4 --set rdrs.internal.maxAllocatedBuffers=235929
rejects "operationIdMaxSize 4097" --set rdrs.internal.operationIdMaxSize=4097
rejects "maxBuffers 1 (rdrs2 needs at least 2)" --set rdrs.internal.maxBuffers=1 --set rdrs.internal.preAllocatedBuffers=0
rejects "maxBuffers below the default preAllocatedBuffers (128)" --set rdrs.internal.maxBuffers=64
rejects "maxBuffers below preAllocatedBuffers" --set rdrs.internal.maxBuffers=4 --set rdrs.internal.preAllocatedBuffers=8
rejects "a negative connectionRetries" --set rdrs.rondb.connectionRetries=-1
rejects "apiKey.preloadThreads 0" --set rdrs.security.apiKey.preloadThreads=0
rejects "featureStore.metadataCachePreloadThreads 0" --set rdrs.featureStore.metadataCachePreloadThreads=0
rejects "a log level outside the chart's list" --set rdrs.log.level=verbose
rejects "an integer log level" --set rdrs.log.level=5

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
