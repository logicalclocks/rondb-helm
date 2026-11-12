#!/bin/bash

# Copyright (c) 2024-2026 Hopsworks AB. All rights reserved.

# Tests for the wait-datanodes-dependency init container
# (files/scripts/wait_ndbmtds.sh). Needs only helm and bash — no cluster.
#
# Part 1 — rendering: MySQLds get the time limit from
#   timeoutsMinutes.waitAllDatanodes (2 min when the setting is absent); the
#   restore Job and setup-mysqld Job wait for every data node without a time
#   limit.
# Part 2 — behavior: extracts the rendered script and runs it against a
#   fake ndb_mgm for a cluster of 2 node groups x 2 active replicas
#   (node ids 1 2 | 4 5; 3 and 6 are inactive slots).

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

render() { # <output-file> <template> [helm args...]
  local out="$1" template="$2"; shift 2
  helm template t "$CHART" -s "$template" \
    --values "$CHART/values/minikube/small.yaml" \
    --set clusterSize.numNodeGroups=2 \
    "$@" > "$out" 2> "$out.err" \
    || { echo "helm template $template failed:"; tail -5 "$out.err"; exit 1; }
}

render "$WORK_DIR/mysqld.yaml" templates/mysqlds/mysqld.yaml
# null deletes the setting, as "helm upgrade --reuse-values" does for a
# release installed with a chart that predates it.
render "$WORK_DIR/mysqld_absent.yaml" templates/mysqlds/mysqld.yaml \
  --set timeoutsMinutes.waitAllDatanodes=null
render "$WORK_DIR/mysqld_zero.yaml" templates/mysqlds/mysqld.yaml \
  --set timeoutsMinutes.waitAllDatanodes=0
render "$WORK_DIR/setup_job.yaml" templates/mysqlds/setup_job.yaml
render "$WORK_DIR/restore.yaml" templates/backups/restore.yaml \
  --set-string restoreFromBackup.backupId=1 \
  --set restoreFromBackup.s3.bucketName=bucket

# wait_limit <rendered-file>: the WAIT_ALL_DATANODES_SECONDS value of the
# wait-datanodes-dependency container.
wait_limit() {
  awk '
    /^      - name: wait-datanodes-dependency/ {inwait=1; next}
    inwait && /^      - name:/ {exit}
    inwait && /- name: WAIT_ALL_DATANODES_SECONDS/ {getline; sub(/^ *value: */, ""); print; exit}
  ' "$1"
}

# extract_script <rendered-file>: the bash block scalar of the
# wait-datanodes-dependency command, dedented. The container sits in the
# initContainers list at 6-space indentation, its script under '- |' at 10.
extract_script() {
  awk '
    /^      - name: wait-datanodes-dependency/ {inwait=1; next}
    inwait && /^        - \|/ {inscript=1; next}
    inscript && (/^          / || /^ *$/) {print substr($0, 11); next}
    inscript {exit}
  ' "$1"
}

echo "Part 1 - rendering"

assert "mysqld waits at most timeoutsMinutes.waitAllDatanodes (2 min) for every data node" \
  '[ "$(wait_limit "$WORK_DIR/mysqld.yaml")" = "\"120\"" ]'
assert "timeoutsMinutes.waitAllDatanodes absent (helm upgrade --reuse-values from an older chart): 2 min" \
  '[ "$(wait_limit "$WORK_DIR/mysqld_absent.yaml")" = "\"120\"" ]'
assert "timeoutsMinutes.waitAllDatanodes 0 is kept, not replaced by the 2 min default" \
  '[ "$(wait_limit "$WORK_DIR/mysqld_zero.yaml")" = "\"0\"" ]'
assert "setup-mysqld Job waits for every data node without a time limit" \
  '[ "$(wait_limit "$WORK_DIR/setup_job.yaml")" = "\"\"" ]'
assert "restore Job waits for every data node without a time limit" \
  '[ "$(wait_limit "$WORK_DIR/restore.yaml")" = "\"\"" ]'

extract_script "$WORK_DIR/mysqld.yaml" > "$WORK_DIR/wait.sh"
assert "wait script extracted" '[ -s "$WORK_DIR/wait.sh" ]'
assert "node groups rendered from numNodeGroups and activeDataReplicas" \
  'grep -qx "NODE_GROUPS=(\"1 2\" \"4 5\")" "$WORK_DIR/wait.sh"'

echo "Part 2 - behavior against a fake ndb_mgm"

# Run the script with the fakes first in PATH, and a short sleep so that a
# test takes seconds.
sed -i.orig "s#/srv/hops/mysql/bin/##g" "$WORK_DIR/wait.sh"
mkdir -p "$WORK_DIR/bin"
REAL_SLEEP=$(command -v sleep)
printf '#!/bin/bash\nexec %s 0.05\n' "$REAL_SLEEP" > "$WORK_DIR/bin/sleep"
printf '#!/bin/bash\nexit 0\n' > "$WORK_DIR/bin/nslookup"
cat > "$WORK_DIR/bin/ndb_mgm" <<'FAKE'
#!/bin/bash
case "$*" in
  *'-e show'*)
    echo "Connected to Management Server at: dummy:1186"
    exit 0 ;;
esac
if [ "$FAKE_STATUS" = unreachable ]; then
  echo "Unable to connect with connect string: nodeid=0,dummy:1186" >&2
  exit 1
fi
echo "Connected to Management Server at: dummy:1186"
echo "$FAKE_STATUS" | tr ';' '\n'
FAKE
chmod +x "$WORK_DIR/bin/sleep" "$WORK_DIR/bin/nslookup" "$WORK_DIR/bin/ndb_mgm"

# status <state of node 2> <state of node 4> <state of node 5>: "all status"
# output with node 1 started and the inactive slots 3 and 6 not connected.
status() {
  echo "Node 1: started (RonDB-26.02.14);Node 2: $1;Node 3: not connected;Node 4: $2;Node 5: $3;Node 6: not connected"
}
STARTED="started (RonDB-26.02.14)"

# run_wait <WAIT_ALL_DATANODES_SECONDS> <fake status>: runs the script for
# up to 3 seconds; prints "exited <code>" or "waiting". Output in out.log.
run_wait() {
  env PATH="$WORK_DIR/bin:$PATH" MGMD_HOSTNAME=dummy \
      WAIT_ALL_DATANODES_SECONDS="$1" FAKE_STATUS="$2" \
      bash "$WORK_DIR/wait.sh" > "$WORK_DIR/out.log" 2>&1 &
  local pid=$! i rc=0
  for ((i = 0; i < 30; i++)); do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" || rc=$?
      echo "exited $rc"; return
    fi
    sleep 0.1
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  echo waiting
}

ALL_UP=$(status "$STARTED" "$STARTED" "$STARTED")
NODE2_DOWN=$(status "not connected" "$STARTED" "$STARTED")

assert "all active data nodes started: done, even without a time limit" \
  '[ "$(run_wait "" "$ALL_UP")" = "exited 0" ] && grep -q "Successfully waited" "$WORK_DIR/out.log"'
assert "a data node down, cluster operational, limit 0: continues with a warning" \
  '[ "$(run_wait 0 "$NODE2_DOWN")" = "exited 0" ] && grep -q "WARNING: ndbmtd(s) 2 not started" "$WORK_DIR/out.log"'
assert "a data node down, cluster operational, limit 1s: continues once the limit passes" \
  '[ "$(run_wait 1 "$NODE2_DOWN")" = "exited 0" ] && grep -q "WARNING: ndbmtd(s) 2 not started" "$WORK_DIR/out.log"'
assert "a data node down, no time limit: keeps waiting" \
  '[ "$(run_wait "" "$NODE2_DOWN")" = "waiting" ]'
assert "\"not started\" is not taken for started" \
  '[ "$(run_wait "" "$(status "not started (RonDB-26.02.14)" "$STARTED" "$STARTED")")" = "waiting" ]'
assert "a data node only starting is not taken for started" \
  '[ "$(run_wait "" "$(status "starting (Last completed phase 4) (RonDB-26.02.14)" "$STARTED" "$STARTED")")" = "waiting" ]'
assert "a node group without a started data node: keeps waiting even with limit 0" \
  '[ "$(run_wait 0 "$(status "$STARTED" "not connected" "starting (Last completed phase 4) (RonDB-26.02.14)")")" = "waiting" ]'
assert "MGMd unreachable: keeps waiting even with limit 0" \
  '[ "$(run_wait 0 unreachable)" = "waiting" ]'

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
