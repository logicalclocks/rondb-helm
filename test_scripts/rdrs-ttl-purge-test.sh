#!/bin/bash

# Copyright (c) 2024-2026 Hopsworks AB. All rights reserved.

# Tests for the values-driven RDRS TTL purge settings (rdrs.ttlPurge).
# Needs only helm, bash and python3 (to parse the rendered JSON) — no cluster.
#
# Part 1 — defaults: no TTLPurge section is rendered, so RDRS images that
#   predate the TTLPurge config key (RonDB < 26.02.9) keep starting.
# Part 2 — overrides: each field, alone and together, lands in rest_api.json
#   with the right JSON type, and the file stays valid JSON.
# Part 3 — schema: malformed windows, start == end, wrong types and unknown
#   fields fail the render instead of being ignored.

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

# ttl_purge <rendered-file>: the TTLPurge section of rest_api.json as compact
# JSON, "absent" when not rendered, "invalid" when rest_api.json is not JSON.
ttl_purge() {
  python3 - "$1" <<'EOF'
import json, re, sys
text = open(sys.argv[1]).read()
m = re.search(r"rest_api\.json: \|\n((?:        .*\n|\n)+)", text)
try:
    config = json.loads(m.group(1))
except Exception:
    print("invalid"); sys.exit()
section = config.get("TTLPurge")
print("absent" if section is None else json.dumps(section, separators=(",", ":")))
EOF
}

rendered() { # <description> <expected TTLPurge> [helm args...]
  local desc="$1" expected="$2"; shift 2
  local out="$WORK_DIR/out.yaml"
  if ! render "$out" "$@"; then
    FAIL=$((FAIL + 1)); echo "  FAIL: $desc (render failed)"; tail -3 "$out.err"; return
  fi
  assert "$desc" '[ "$(ttl_purge "$out")" = "$expected" ]'
}

echo "Part 1 - defaults"

rendered "no TTLPurge section by default" absent
rendered "an empty activeWindow renders nothing" absent --set-string rdrs.ttlPurge.activeWindow=

echo "Part 2 - overrides"

rendered "enable=false" '{"Enable":false}' --set rdrs.ttlPurge.enable=false
rendered "enable=true" '{"Enable":true}' --set rdrs.ttlPurge.enable=true
rendered "activeWindow alone" '{"ActiveWindow":"03:00-05:00"}' \
  --set rdrs.ttlPurge.activeWindow=03:00-05:00
rendered "both, window wrapping past midnight" '{"Enable":true,"ActiveWindow":"23:00-02:00"}' \
  --set rdrs.ttlPurge.enable=true --set rdrs.ttlPurge.activeWindow=23:00-02:00

echo "Part 3 - schema"

REJECTED="$WORK_DIR/rejected.yaml"
rejects() { # <description> <helm --set argument>
  local set_arg="$2"
  assert "rejects $1" '! render "$REJECTED" --set "$set_arg"'
}

rejects "a window without leading zeros" rdrs.ttlPurge.activeWindow=3:00-5:00
rejects "hour 24" rdrs.ttlPurge.activeWindow=24:00-01:00
rejects "minute 60" rdrs.ttlPurge.activeWindow=03:60-05:00
rejects "trailing characters" rdrs.ttlPurge.activeWindow=03:00-05:00x
rejects "start == end" rdrs.ttlPurge.activeWindow=03:00-03:00
rejects "a misspelled field" rdrs.ttlPurge.enabled=false
rejects "a non-boolean enable" rdrs.ttlPurge.enable=off

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
