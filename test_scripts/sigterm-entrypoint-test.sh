#!/bin/bash

# Copyright (c) 2024-2026 Hopsworks AB. All rights reserved.



# RONDB-1132: SIGTERM must reach the daemon in every container that runs one
# under a bash PID 1 (ndbmtd, ndb_mgmd, mysqld, rdrs2, run_applier.sh) and
# the ndbmtd pod's sidecar. bash as PID 1 ignores an untrapped SIGTERM and
# defers a trapped one while a foreground command runs, so the former
# `daemon | tee` pipelines made every planned pod stop a SIGKILL at the end
# of the grace period. Init containers and Jobs are out of scope.
#
# Part 1 - render: every entrypoint is valid bash; the per-component grace
#   period renders as documented (object, legacy integer, null, typo).
# Part 2 - docker (skipped without docker or a rondb image, unless
#   SIGTERM_TEST_REQUIRE_DOCKER=1): each RENDERED entrypoint runs as PID 1 in
#   the RonDB image with stub binaries, receives SIGTERM like from the
#   kubelet, and must stop promptly with the daemon's exit code and its final
#   log line on stdout AND in the tee'd log file.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR=$(mktemp -d)
CT=sigterm-test-ct
trap 'rm -rf "$WORK_DIR"; docker rm -f $CT >/dev/null 2>&1 || true' EXIT

PASS=0; FAIL=0
assert() { # <description> <command>
  if eval "$2"; then PASS=$((PASS + 1)); echo "  ok: $1"
  else FAIL=$((FAIL + 1)); echo "  FAIL: $1"; echo "    check: $2"; fi
}

# macOS has no `timeout`; minimal substitute for `timeout N cmd...`
if ! command -v timeout >/dev/null 2>&1; then
  timeout() {
    local t=$1; shift
    "$@" & local p=$!
    ( sleep "$t"; kill "$p" 2>/dev/null ) >/dev/null 2>&1 & local watchdog=$!
    local rc=0; wait "$p" || rc=$?
    kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null || true
    return "$rc"
  }
fi

# Render from a copy without venv/.git: helm loads every file in the chart
# directory, and a local venv makes each render take minutes.
CHART="$WORK_DIR/chart"
rsync -a --exclude venv --exclude .git --exclude .claude "$REPO_ROOT/" "$CHART/"

echo "Part 1 - rendered entrypoints"
helm template t "$CHART" --set backups.enabled=true \
  --set backups.s3.bucketName=sigterm-test-dummy \
  --set meta.ddlMySQLd.enabled=true \
  --set globalReplication.primary.enabled=true \
  --set globalReplication.secondary.enabled=true \
  --set 'globalReplication.secondary.replicateFrom.binlogServerHosts={dummy-binlog-0}' \
  -s templates/ndbd.yaml -s templates/rdrs.yaml \
  -s templates/mgmd.yaml -s templates/mysqlds/mysqld.yaml \
  -s templates/mysqlds/ddl_mysqld.yaml \
  -s templates/mysqlds/binlog_servers.yaml \
  -s templates/mysqlds/replica_appliers.yaml \
  -s templates/mysqlds/config_map.yaml \
  > "$WORK_DIR/rendered.yaml" 2>"$WORK_DIR/render.err" \
  || { echo "helm template failed:"; tail -5 "$WORK_DIR/render.err"; exit 1; }

# extract <sts-name> <container-name> <out-file>: the container's bash -c
# script, exactly as shipped.
extract() {
  python3 - "$WORK_DIR/rendered.yaml" "$1" "$2" "$WORK_DIR/$3" <<'PYEOF'
import sys, yaml
rendered, sts, container, out = sys.argv[1:5]
for doc in yaml.safe_load_all(open(rendered)):
    if not doc or doc.get("kind") != "StatefulSet": continue
    if doc["metadata"]["name"] != sts: continue
    for c in doc["spec"]["template"]["spec"]["containers"]:
        if c["name"] == container:
            cmd = c["command"]
            assert cmd[0] == "/bin/bash" and cmd[1] == "-c", cmd[:2]
            open(out, "w").write(cmd[2])
            sys.exit(0)
sys.exit(f"container {sts}/{container} not found")
PYEOF
}
extract node-group-0 ndbmtd          ndbmtd_entry.sh
extract node-group-0 rclone-listener sidecar_entry.sh
extract rdrs         rdrs            rdrs_entry.sh
extract mgmds        mgmd            mgmd_entry.sh
extract mysqlds      mysqld          mysqld_entry.sh
extract ddl-mysqld   mysqld          ddl_entry.sh
extract mysqld-binlog-servers binlog-server binlog_entry.sh
extract mysqld-replica-appliers replica-applier-controller applier_entry.sh
extract mysqld-replica-appliers mysqld applier_mysqld_entry.sh
# run_applier.sh as the controller runs it (from the ConfigMap)
python3 - "$WORK_DIR/rendered.yaml" "$WORK_DIR/run_applier_rendered.sh" <<'PYEOF'
import sys, yaml
rendered, out = sys.argv[1:3]
for doc in yaml.safe_load_all(open(rendered)):
    if doc and doc.get("kind") == "ConfigMap" and "run_applier.sh" in (doc.get("data") or {}):
        open(out, "w").write(doc["data"]["run_applier.sh"]); sys.exit(0)
sys.exit("run_applier.sh not found in any ConfigMap")
PYEOF

for f in ndbmtd sidecar rdrs mgmd mysqld ddl binlog applier applier_mysqld; do
  assert "${f}_entry.sh is valid bash" "bash -n '$WORK_DIR/${f}_entry.sh'"
done
assert "run_applier.sh is valid bash" "bash -n '$WORK_DIR/run_applier_rendered.sh'"
assert "binlog server execs mysqld (PID 1 receives SIGTERM directly)" \
  "grep -q '^ *exec mysqld ' '$WORK_DIR/binlog_entry.sh'"
assert "replica applier mysqld execs mysqld" \
  "grep -q '^ *exec mysqld ' '$WORK_DIR/applier_mysqld_entry.sh'"
assert "run_applier.sh sets no trap (the default disposition must stop it instantly)" \
  "! grep -q '^ *trap ' '$WORK_DIR/run_applier_rendered.sh'"

# grace <rendered-file> <sts-name>: the pod's terminationGracePeriodSeconds
grace() {
  python3 - "$1" "$2" <<'PYEOF'
import sys, yaml
rendered, sts = sys.argv[1:3]
for doc in yaml.safe_load_all(open(rendered)):
    if doc and doc.get("kind") == "StatefulSet" and doc["metadata"]["name"] == sts:
        print(doc["spec"]["template"]["spec"].get("terminationGracePeriodSeconds")); break
PYEOF
}
render_grace() { # <out-file> [helm args...]: data node, rdrs and mgmd StatefulSets
  local out="$1"; shift
  helm template t "$CHART" -s templates/ndbd.yaml -s templates/rdrs.yaml \
    -s templates/mgmd.yaml "$@" > "$out" 2>"$out.err"
}
render_grace "$WORK_DIR/g_default.yaml"
assert "object grace form: data nodes default to 300" \
  '[ "$(grace "$WORK_DIR/g_default.yaml" node-group-0)" = 300 ]'
assert "object grace form: other components default to 30" \
  '[ "$(grace "$WORK_DIR/g_default.yaml" rdrs)" = 30 ] && [ "$(grace "$WORK_DIR/g_default.yaml" mgmds)" = 30 ]'
render_grace "$WORK_DIR/g_int.yaml" --set terminationGracePeriodSeconds=45
assert "legacy integer grace overrides the data nodes only" \
  '[ "$(grace "$WORK_DIR/g_int.yaml" node-group-0)" = 45 ] && [ "$(grace "$WORK_DIR/g_int.yaml" rdrs)" = 30 ]'
assert "legacy integer grace below the minimum is rejected" \
  '! render_grace "$WORK_DIR/g_low.yaml" --set terminationGracePeriodSeconds=5'
# Helm drops null keys BEFORE schema validation, so a null can never be
# bounds-checked: the helper must fall back to the default, never render 0.
render_grace "$WORK_DIR/g_null.yaml" --set terminationGracePeriodSeconds=null
assert "null grace falls back to the defaults, never 0" \
  '[ "$(grace "$WORK_DIR/g_null.yaml" node-group-0)" = 300 ] && [ "$(grace "$WORK_DIR/g_null.yaml" rdrs)" = 30 ]'
assert "null component grace is rejected by the schema" \
  '! render_grace "$WORK_DIR/g_knull.yaml" --set terminationGracePeriodSeconds.rdrs=null'
assert "typo in a grace key is rejected by the schema" \
  '! render_grace "$WORK_DIR/g_typo.yaml" --set terminationGracePeriodSeconds.ndbmtd=60'
assert "the data node entrypoint reads the data nodes' grace" \
  'grep -q "^GRACE_S=300$" "$WORK_DIR/ndbmtd_entry.sh"'

echo "Part 2 - docker: SIGTERM delivery"
IMAGE=""
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  IMAGE="hopsworks/rondb:$(python3 -c \
    "import yaml; print(yaml.safe_load(open('$CHART/values.yaml'))['images']['rondb']['tag'])")"
  docker image inspect "$IMAGE" >/dev/null 2>&1 \
    || IMAGE=$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
               | grep '^hopsworks/rondb:' | head -1 || true)
fi
if [ -z "${IMAGE:-}" ] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  if [ "${SIGTERM_TEST_REQUIRE_DOCKER:-0}" = "1" ]; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: SIGTERM_TEST_REQUIRE_DOCKER=1 but docker or a hopsworks/rondb image is not available"
    echo; echo "passed: $PASS failed: $FAIL"; exit 1
  fi
  echo "  SKIP: docker or a hopsworks/rondb image is not available"
  echo; echo "passed: $PASS failed: $FAIL"; [ "$FAIL" = "0" ]; exit
fi
echo "  using image $IMAGE"

# Stub binaries, placed FIRST in PATH inside the container. Stop-time
# behaviour of the ndb_mgm stub is selected by marker files in /work:
#   mgm_down       - deactivate FAILS every time (MGMd unreachable)
#   mgm_hang       - deactivate HANGS (only the entrypoint's timeout cuts it)
#   mgm_slow       - deactivate succeeds but RETURNS 4s later, so the daemon
#                    exits while the handler still runs
#   $REFUSALS_FILE - the next N deactivates are REFUSED with the outputs
#                    `ndb_mgm -e` really prints for error 2002, then succeed
STUBS="$WORK_DIR/stubs"; mkdir -p "$STUBS"
cat > "$STUBS/ndb_mgm" <<'EOS'
#!/bin/bash
echo "stub ndb_mgm: $*" >> /work/mgm_calls.log
case "$*" in *deactivate*)
  [ -f /work/mgm_hang ] && sleep 600
  [ -f /work/mgm_down ] && exit 1
  if [ -f /work/mgm_slow ]; then touch /work/deactivated; sleep 4; exit 0; fi
  RF="/work/${REFUSALS_FILE:-refusals_left}"
  if [ -s "$RF" ] && [ "$(cat "$RF")" -gt 0 ]; then
    n=$(cat "$RF"); echo $((n-1)) > "$RF"
    echo "Connected to Management Server at: mgmd-test:1186"
    echo "*  2002: Stop failed"
    if [ $((n % 2)) = 0 ]; then
      echo "*        Node shutdown would cause system crash: Permanent error: Application error"
    else
      echo "*        Operation not allowed while nodes are starting or stopping."
    fi
    exit 255
  fi
  touch /work/deactivated ;;
esac
exit 0
EOS
# ndbmtd stub: like the real angel it IGNORES SIGTERM and stops through the
# cluster protocol (the marker the deactivate stub creates). Its child
# handles SIGTERM like the real ndbd (clean stop) - the direct-stop fallback
# relies on that. The child is forked before TERM is ignored: a bash cannot
# trap a signal it inherited as ignored.
cat > "$STUBS/ndbmtd" <<'EOS'
#!/bin/bash
bash -c 'sleep 600 >/dev/null 2>&1 & SLEEP=$!
         trap "touch /work/child_stopped; kill \"\$SLEEP\" 2>/dev/null; exit 0" TERM
         wait "$SLEEP"' &
CHILD=$!
trap '' TERM
echo "daemon: started"
for i in $(seq 1 600); do
  if [ -f /work/deactivated ]; then
    kill -TERM "$CHILD" 2>/dev/null; wait "$CHILD" 2>/dev/null || true
    echo "daemon: managed stop complete (final line)"
    exit "$(cat /work/daemon_rc 2>/dev/null || echo 0)"
  fi
  if ! kill -0 "$CHILD" 2>/dev/null; then
    echo "daemon: child stopped directly (final line)"; exit 0
  fi
  sleep 0.1
done
echo "daemon: was never stopped"; exit 9
EOS
for d in ndb_mgmd mysqld rdrs2; do
cat > "$STUBS/$d" <<'EOS'
#!/bin/bash
trap 'echo "daemon: got SIGTERM, clean shutdown (final line)"; exit 0' TERM
echo "daemon: started"
while true; do sleep 0.1; done
EOS
done
cat > "$STUBS/nslookup" <<'EOS'
#!/bin/bash
[ -f /work/dns_down ] && exit 1
echo "Address: $(hostname -i | awk '{print $1}')"
EOS
# applier: mysqladmin answers the controller's ping loop; mysql BLOCKS (a
# SIGTERM arriving while run_applier.sh sits in a hanging mysql call)
printf '#!/bin/bash\nexit 0\n' > "$STUBS/mysqladmin"
printf '#!/bin/bash\nsleep 300\nexit 1\n' > "$STUBS/mysql"
printf '#!/bin/bash\nfunction getBinlogPosition() { mysql -h "$1" -e "SHOW BINLOG EVENTS"; }\n' \
  > "$STUBS/get_binlog_position.sh"
cp "$WORK_DIR/run_applier_rendered.sh" "$STUBS/run_applier.sh"
chmod +x "$STUBS"/*

NDBMTD_ENV=(-e POD_NAME=node-group-0-0 -e NODE_GROUP=0 -e MGMD_HOST=mgmd-test
  -e MGM_CONNECTION_STRING=mgmd-test:1186 -e FILE_SYSTEM_PATH=/srv/hops/mysql-cluster/ndb_data)

# start_ct <entry-file> <ready-regex> [docker args...]: run the rendered
# entrypoint as PID 1 (command: [/bin/bash, -c, <script>], as under
# Kubernetes) and wait until its log shows <ready-regex>. The in-container
# rm of the stop marker matters on macOS: Docker Desktop's VirtioFS can
# serve a host-deleted file to a new container from a stale cache.
start_ct() {
  local entry="$1" ready="$2"; shift 2
  docker rm -f $CT >/dev/null 2>&1 || true
  rm -f "$WORK_DIR/deactivated" "$WORK_DIR/mgm_calls.log" "$WORK_DIR/child_stopped"
  docker run -d --name $CT -v "$WORK_DIR":/work -v "$STUBS":/stubs \
    -e PATH="/stubs:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/srv/hops/mysql/bin" \
    "$@" --entrypoint /bin/bash "$IMAGE" -c \
    'rm -f /work/deactivated
     mkdir -p /srv/hops/mysql-cluster/log "${BINLOG_DIR:-/tmp}"
     touch /srv/hops/mysql-cluster/my-raw.cnf
     exec /bin/bash /work/'"$entry" >/dev/null
  local i
  for i in $(seq 1 120); do
    docker logs $CT 2>&1 | grep -q "$ready" && return 0
    [ "$(docker inspect -f '{{.State.Status}}' $CT)" = "running" ] || break
    sleep 0.5
  done
  FAIL=$((FAIL + 1)); echo "  FAIL: $entry never logged '$ready'; last lines:"
  docker logs $CT 2>&1 | tail -8 | sed 's/^/    /'
  docker rm -f $CT >/dev/null 2>&1 || true
  return 1
}
# stop_ct <name>: SIGTERM PID 1 as the kubelet does; sets CODE and ELAPSED,
# saves stdout to $name.stdout and the log dir to fs_$name.
stop_ct() {
  local t0 t1
  t0=$(date +%s)
  docker kill -s TERM $CT >/dev/null
  CODE=$(timeout 30 docker wait $CT || echo TIMEOUT)
  t1=$(date +%s); ELAPSED=$((t1 - t0))
  docker logs $CT > "$WORK_DIR/$1.stdout" 2>&1 || true
  rm -rf "$WORK_DIR/fs_$1"
  docker cp -L "$CT:/srv/hops/mysql-cluster/log" "$WORK_DIR/fs_$1" >/dev/null 2>&1 || true
  docker rm -f $CT >/dev/null 2>&1 || true
}
# clean_stop <name>: the contract of a managed stop
clean_stop() {
  assert "$1: exits with the daemon's code 0 (got $CODE)" "[ '$CODE' = '0' ]"
  assert "$1: stops promptly (${ELAPSED}s, grace never reached)" "[ $ELAPSED -lt 15 ]"
  assert "$1: daemon's final line on container stdout" "grep -q 'final line' '$WORK_DIR/$1.stdout'"
  assert "$1: daemon's final line in the tee'd log file" "grep -rq 'final line' '$WORK_DIR/fs_$1' 2>/dev/null"
}

# ndbmtd: the handler deactivates the node (managed stop) and the container
# ends with ndbmtd's own exit code.
if start_ct ndbmtd_entry.sh "daemon: started" "${NDBMTD_ENV[@]}"; then
  stop_ct ndbmtd; clean_stop ndbmtd
  assert "ndbmtd: the handler ran the deactivate" "grep -q deactivate '$WORK_DIR/mgm_calls.log'"
fi

# ndbmtd, MGMd unreachable (whole cluster being deleted): the deactivate
# retries are bounded (4s here, 60s in production) and the handler then
# stops ndbmtd directly through its child, well inside the grace period.
touch "$WORK_DIR/mgm_down"
if start_ct ndbmtd_entry.sh "daemon: started" "${NDBMTD_ENV[@]}" -e DEACTIVATE_RETRY_LIMIT_S=4; then
  stop_ct ndbmtd-mgm-down
  assert "ndbmtd-mgm-down: stops within the retry bound (${ELAPSED}s, got $CODE)" \
    "[ '$CODE' = '0' ] && [ $ELAPSED -lt 15 ]"
  assert "ndbmtd-mgm-down: fell back to a direct stop" \
    "grep -q 'stopping ndbmtd directly' '$WORK_DIR/ndbmtd-mgm-down.stdout'"
  assert "ndbmtd-mgm-down: the ndbd child received the direct stop" "[ -f '$WORK_DIR/child_stopped' ]"
fi
rm -f "$WORK_DIR/mgm_down"

# ndbmtd, deactivate HANGING inside the MGMd: --connect-retries cannot bound
# that, only the per-call timeout (the full budget, 4s here) can.
touch "$WORK_DIR/mgm_down" "$WORK_DIR/mgm_hang"
if start_ct ndbmtd_entry.sh "daemon: started" "${NDBMTD_ENV[@]}" -e DEACTIVATE_FULL_LIMIT_S=4; then
  stop_ct ndbmtd-mgm-hang
  assert "ndbmtd-mgm-hang: a hanging deactivate is cut by the budget (${ELAPSED}s, got $CODE)" \
    "[ '$CODE' = '0' ] && [ $ELAPSED -lt 15 ]"
  assert "ndbmtd-mgm-hang: the ndbd child received the direct stop" "[ -f '$WORK_DIR/child_stopped' ]"
fi
rm -f "$WORK_DIR/mgm_down" "$WORK_DIR/mgm_hang"

# ndbmtd, MGMd REFUSING (last live replica of its node group): two refusals
# with the real error-2002 outputs, success on the third call at ~4s - PAST
# the 3s retry cap. Only the escalation to the full budget (20s here) keeps
# retrying that long; without it the handler downs the cluster with a
# direct stop.
echo 2 > "$WORK_DIR/refusals_r1"
if start_ct ndbmtd_entry.sh "daemon: started" "${NDBMTD_ENV[@]}" -e REFUSALS_FILE=refusals_r1 \
     -e DEACTIVATE_RETRY_LIMIT_S=3 -e DEACTIVATE_FULL_LIMIT_S=20; then
  stop_ct ndbmtd-refused; clean_stop ndbmtd-refused
  assert "ndbmtd-refused: kept retrying past the cap until the deactivate succeeded" \
    "[ -f '$WORK_DIR/deactivated' ] && ! grep -q 'stopping ndbmtd directly' '$WORK_DIR/ndbmtd-refused.stdout'"
  assert "ndbmtd-refused: both refusals were exercised" "[ \"\$(cat '$WORK_DIR/refusals_r1')\" = 0 ]"
fi
rm -f "$WORK_DIR/refusals_r1"

# ndbmtd whose deactivate legitimately takes LONGER than the retry cap (the
# call blocks for the node's whole shutdown, 4s here against a 2s cap): it
# must be allowed to finish - cut short, the node stops but is never
# deactivated in the configuration.
touch "$WORK_DIR/mgm_slow"
if start_ct ndbmtd_entry.sh "daemon: started" "${NDBMTD_ENV[@]}" -e DEACTIVATE_RETRY_LIMIT_S=2; then
  stop_ct ndbmtd-slow-stop; clean_stop ndbmtd-slow-stop
  assert "ndbmtd-slow-stop: the slow deactivate completed (no direct stop)" \
    "grep -q 'Deactivated node id 1 via MGM client$' '$WORK_DIR/ndbmtd-slow-stop.stdout' \
     && ! grep -q 'stopping ndbmtd directly' '$WORK_DIR/ndbmtd-slow-stop.stdout'"
  assert "ndbmtd-slow-stop: exactly one deactivate call" \
    "[ \"\$(grep -c deactivate '$WORK_DIR/mgm_calls.log')\" = 1 ]"
fi
rm -f "$WORK_DIR/mgm_slow"

# ndbmtd exiting NON-ZERO while the handler still runs (the handler's own
# deactivate is what stops it, so this is every ordinary managed stop made
# deterministic): the container must report 7, not the interrupted wait's
# 143.
touch "$WORK_DIR/mgm_slow"; echo 7 > "$WORK_DIR/daemon_rc"
if start_ct ndbmtd_entry.sh "daemon: started" "${NDBMTD_ENV[@]}"; then
  stop_ct ndbmtd-wait-race
  assert "ndbmtd-wait-race: reports the daemon's exit code, not the trap's 143 (got $CODE)" "[ '$CODE' = '7' ]"
  assert "ndbmtd-wait-race: stops promptly (${ELAPSED}s)" "[ $ELAPSED -lt 15 ]"
  assert "ndbmtd-wait-race: daemon's final line in the tee'd log file" \
    "grep -rq 'final line' '$WORK_DIR/fs_ndbmtd-wait-race' 2>/dev/null"
fi
rm -f "$WORK_DIR/mgm_slow" "$WORK_DIR/daemon_rc"

if start_ct mgmd_entry.sh "daemon: started" -e RONDB_DATA_DIR=/srv/hops/mysql-cluster \
     -e LOG_DIR=/srv/hops/mysql-cluster/log; then
  stop_ct mgmd; clean_stop mgmd
fi
if start_ct mysqld_entry.sh "daemon: started" -e RONDB_DATA_DIR=/srv/hops/mysql-cluster \
     -e POD_NAME=mysqlds-0 -e MYSQL_CLUSTER_PASSWORD=dummy; then
  stop_ct mysqld; clean_stop mysqld
fi
if start_ct ddl_entry.sh "daemon: started" -e RONDB_DATA_DIR=/srv/hops/mysql-cluster \
     -e POD_NAME=ddl-mysqld-0 -e MYSQL_CLUSTER_PASSWORD=dummy; then
  stop_ct ddl-mysqld; clean_stop ddl-mysqld
fi
if start_ct rdrs_entry.sh "daemon: started" -e POD_NAME=rdrs-0; then
  stop_ct rdrs; clean_stop rdrs
fi

# rdrs with DNS never resolving: a SIGTERM during startup must exit the pod
# promptly instead of retrying until the grace period expires.
touch "$WORK_DIR/dns_down"
if start_ct rdrs_entry.sh "not resolvable yet" -e POD_NAME=rdrs-0; then
  stop_ct rdrs-dns-down
  assert "rdrs-dns-down: SIGTERM during startup exits promptly (${ELAPSED}s, got $CODE)" \
    "[ '$CODE' = '0' ] && [ $ELAPSED -lt 15 ]"
  assert "rdrs-dns-down: no daemon was started" "! grep -q 'daemon: started' '$WORK_DIR/rdrs-dns-down.stdout'"
fi
rm -f "$WORK_DIR/dns_down"

# binlog server: mysqld is exec'd as PID 1 and gets the SIGTERM itself (no
# tee, so no log-file assertion). The entrypoint lists the binlog dir first.
BINLOG_DIR=$(grep -E '^\s*ls -l ' "$WORK_DIR/binlog_entry.sh" | head -1 | awk '{print $3}')
if start_ct binlog_entry.sh "daemon: started" -e RONDB_DATA_DIR=/srv/hops/mysql-cluster \
     -e POD_NAME=binlog-0 -e MYSQL_CLUSTER_PASSWORD=dummy -e BINLOG_DIR="$BINLOG_DIR"; then
  stop_ct binlog
  assert "binlog: exits 0 on SIGTERM delivered straight to mysqld (got $CODE)" "[ '$CODE' = '0' ]"
  assert "binlog: stops promptly (${ELAPSED}s)" "[ $ELAPSED -lt 15 ]"
  assert "binlog: daemon's final line on container stdout" "grep -q 'final line' '$WORK_DIR/binlog.stdout'"
fi

# applier controller: SIGTERM must stop run_applier.sh even while it is
# blocked in a foreground mysql call (stubbed to hang 300s).
if start_ct applier_entry.sh "replica applier attempt" -e RONDB_DATA_DIR=/srv/hops/mysql-cluster \
     -e POD_NAME=applier-0 -e MYSQL_CLUSTER_PASSWORD=dummy; then
  sleep 1   # let it enter the blocking mysql call
  stop_ct applier
  assert "applier: run_applier.sh was killed by the forwarded SIGTERM (got $CODE, ${ELAPSED}s)" \
    "[ '$CODE' = '143' ] && [ $ELAPSED -lt 15 ]"
fi

# sidecar: no daemon; it must simply exit 0 promptly on SIGTERM.
docker rm -f $CT >/dev/null 2>&1 || true
docker run -d --name $CT --entrypoint /bin/bash "$IMAGE" -c "$(cat "$WORK_DIR/sidecar_entry.sh")" >/dev/null
sleep 1
stop_ct sidecar
assert "sidecar: exits 0 on SIGTERM (got $CODE)" "[ '$CODE' = '0' ]"
assert "sidecar: stops promptly (${ELAPSED}s)" "[ $ELAPSED -lt 10 ]"

echo
echo "passed: $PASS failed: $FAIL"
[ "$FAIL" = "0" ]
