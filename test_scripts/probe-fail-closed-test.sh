#!/bin/bash

# Copyright (c) 2024-2026 Hopsworks AB. All rights reserved.

# Tests for the fail-closed data node startup/readiness probes.
# Needs only helm and bash — no cluster.
#
# Part 1 — rendering: startup and readiness carry the direct ndb_mgm check;
#   the fail-open healthcheck.sh remains only in the liveness probe (whose
#   MGMd-away guard is deliberate: never kill a data node because the MGMd
#   is unreachable).
# Part 2 — behavior: extracts the rendered probe scripts and runs them
#   against a fake ndb_mgm, checking all three outcomes: an unreachable
#   MGMd fails, a non-"started" answer fails, an explicit "started" for
#   this node id passes.

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

RENDERED="$WORK_DIR/ndbd.yaml"
helm template t "$CHART" -s templates/ndbd.yaml \
  --values "$CHART/values/minikube/small.yaml" \
  > "$RENDERED" 2> "$RENDERED.err" \
  || { echo "helm template failed:"; tail -5 "$RENDERED.err"; exit 1; }

echo "Part 1 - rendering"

# extract_probe <probe-name> <output-file>: the bash block scalar of the
# probe's exec command, dedented. Rendered layout is stable: the script
# body sits under '- |' at 14-space indentation.
extract_probe() {
  awk -v probe="$1" '
    $0 ~ "^        "probe":" {inprobe=1; next}
    inprobe && /^            - \|/ {inscript=1; next}
    inscript && /^              / {print substr($0, 15); next}
    inscript {exit}
  ' "$RENDERED"
}

extract_probe startupProbe  > "$WORK_DIR/startup.sh"
extract_probe readinessProbe > "$WORK_DIR/readiness.sh"
extract_probe livenessProbe > "$WORK_DIR/liveness.sh"

assert "startup probe script extracted" '[ -s "$WORK_DIR/startup.sh" ]'
assert "readiness probe script extracted" '[ -s "$WORK_DIR/readiness.sh" ]'
assert "startup asks ndb_mgm directly" 'grep -q "ndb_mgm --ndb-connectstring" "$WORK_DIR/startup.sh"'
assert "readiness asks ndb_mgm directly" 'grep -q "ndb_mgm --ndb-connectstring" "$WORK_DIR/readiness.sh"'
assert "startup no longer calls the fail-open healthcheck.sh" '! grep -q "healthcheck.sh \$MGM" "$WORK_DIR/startup.sh"'
assert "readiness no longer calls the fail-open healthcheck.sh" '! grep -q "healthcheck.sh \$MGM" "$WORK_DIR/readiness.sh"'
assert "liveness keeps healthcheck.sh behind its MGMd-away guard" 'grep -q "healthcheck.sh \$MGM" "$WORK_DIR/liveness.sh"'
assert "liveness keeps the MGMd-away early exit" 'grep -q "exit 0" "$WORK_DIR/liveness.sh"'

echo "Part 2 - behavior against a fake ndb_mgm"

# The probe script computes NODE_ID from POD_NAME/NODE_GROUP:
# node-group-0-1 -> POD_ID 1, offset 0, NODE_ID 2.
mkdir -p "$WORK_DIR/bin"
cat > "$WORK_DIR/bin/ndb_mgm" <<'FAKE'
#!/bin/bash
case "$FAKE_MGM_MODE" in
  unreachable)
    echo "Unable to connect with connect string: nodeid=0,dummy:1186" >&2
    exit 1 ;;
  starting)
    echo "Connected to Management Server at: dummy:1186"
    echo "Node 2: starting (Last completed phase 4) (RonDB-25.10.17)" ;;
  started)
    echo "Connected to Management Server at: dummy:1186"
    echo "Node 2: started (RonDB-25.10.17)" ;;
esac
FAKE
chmod +x "$WORK_DIR/bin/ndb_mgm"

run_probe() { # <script> <mode>; returns the probe exit code
  env PATH="$WORK_DIR/bin:$PATH" \
      FAKE_MGM_MODE="$2" \
      POD_NAME=node-group-0-1 NODE_GROUP=0 MGM_CONNECTION_STRING=dummy:1186 \
      bash "$1" >/dev/null 2>&1
}

for probe in startup readiness; do
  assert "$probe fails when the MGMd is unreachable" "! run_probe $WORK_DIR/$probe.sh unreachable"
  assert "$probe fails while the node is only starting" "! run_probe $WORK_DIR/$probe.sh starting"
  assert "$probe passes on an explicit started answer" "run_probe $WORK_DIR/$probe.sh started"
done

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
