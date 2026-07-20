#!/bin/bash

# Copyright (c) 2024-2026 Hopsworks AB. All rights reserved.

# Tests for the sequenced data node rollout (ndbmtdSequencedRollout).
# Needs only helm and bash — no cluster.
#
# Part 1 — rendering: the partition freeze and the rollout CronJob render
#   together when the feature applies, and not at all when it doesn't
#   (flag off, single node group, in-place restore).
# Part 2 — behavior: extracts the rollout script from the rendered CronJob
#   and runs it against a fake kubectl that serves StatefulSet state from
#   files, checking every state it can act on: unfreeze order, re-freeze,
#   stall reporting, holding while a group is unhealthy, taking over
#   manually unfrozen groups, and missing StatefulSets.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

PASS=0; FAIL=0
assert() { # <description> <command>
  if eval "$2"; then PASS=$((PASS + 1)); echo "  ok: $1"
  else FAIL=$((FAIL + 1)); echo "  FAIL: $1"; echo "    check: $2"; fi
}
count() { grep -c "$1" "$2" || true; }

# Render from a copy without venv/.git: helm loads every file in the chart
# directory, and a local venv makes each render take minutes.
CHART="$WORK_DIR/chart"
rsync -a --exclude venv --exclude .git --exclude .claude "$REPO_ROOT/" "$CHART/"

render() { # <output-file> [helm --set flags...]
  local out=$1; shift
  helm template t "$CHART" --values "$CHART/values/minikube/small.yaml" "$@" \
    > "$out" 2> "$out.err" || { echo "helm template failed:"; tail -5 "$out.err"; exit 1; }
}

echo "=== rendering: flag off (default) -> no freeze, no CronJob ==="
render "$WORK_DIR/off.yaml"
assert "no partition rendered" '[[ $(count "partition:" $WORK_DIR/off.yaml) == 0 ]]'
assert "no rollout CronJob" '[[ $(count "ndbmtd-sequenced-rollout" $WORK_DIR/off.yaml) == 0 ]]'

echo "=== rendering: flag on, 2 node groups -> freeze + CronJob ==="
render "$WORK_DIR/on.yaml" --set clusterSize.numNodeGroups=2 --set ndbmtdSequencedRollout.enabled=true
assert "partition on both groups" '[[ $(count "partition: 2" $WORK_DIR/on.yaml) == 2 ]]'
assert "one CronJob" '[[ $(count "kind: CronJob" $WORK_DIR/on.yaml) == 1 ]]'
assert "RBAC names both groups" '[[ $(count "node-group-1$" $WORK_DIR/on.yaml) -ge 1 ]]'

echo "=== rendering: flag on, 1 node group -> feature off (nothing to sequence) ==="
render "$WORK_DIR/one.yaml" --set ndbmtdSequencedRollout.enabled=true
assert "no partition with a single group" '[[ $(count "partition:" $WORK_DIR/one.yaml) == 0 ]]'
assert "no CronJob with a single group" '[[ $(count "ndbmtd-sequenced-rollout" $WORK_DIR/one.yaml) == 0 ]]'

echo "=== rendering: flag on, in-place restore -> feature off ==="
render "$WORK_DIR/inplace.yaml" --set clusterSize.numNodeGroups=2 \
  --set ndbmtdSequencedRollout.enabled=true --set mode=upgrade \
  --set restoreFromBackup.inPlace=true --set restoreFromBackup.forceDataClear=true \
  --set-string restoreFromBackup.backupId=42 --set restoreFromBackup.s3.bucketName=test-bucket
assert "no partition during in-place restore" '[[ $(count "partition:" $WORK_DIR/inplace.yaml) == 0 ]]'
assert "no CronJob during in-place restore" '[[ $(count "ndbmtd-sequenced-rollout" $WORK_DIR/inplace.yaml) == 0 ]]'
assert "in-place restore hook still renders" '[[ $(count "rondb-inplace-restore-shutdown" $WORK_DIR/inplace.yaml) -ge 1 ]]'

echo "=== extracting the rollout script from the rendered CronJob ==="
# Render only the rollout template, then take the block scalar after "- |"
# in the container command: read the indentation off its first line and
# strip it from the rest.
helm template t "$CHART" --values "$CHART/values/minikube/small.yaml" \
  --set clusterSize.numNodeGroups=2 --set ndbmtdSequencedRollout.enabled=true \
  --show-only templates/ndbmtd_sequenced_rollout.yaml \
  > "$WORK_DIR/cronjob.yaml" 2>/dev/null
SCRIPT="$WORK_DIR/reconcile.sh"
awk '
  /^ +- \|$/ { grab=1; next }
  grab && indent == "" { match($0, /^ +/); indent = RLENGTH }
  grab {
    if (length($0) == 0) { print ""; next }
    if (match($0, /^ +/) && RLENGTH >= indent) { print substr($0, indent + 1); next }
    exit
  }
' "$WORK_DIR/cronjob.yaml" > "$SCRIPT"
assert "script extracted" '[[ $(wc -l < "$SCRIPT") -gt 50 ]]'
assert "script passes bash -n" 'bash -n "$SCRIPT"'

echo "=== behavior: fake kubectl serving StatefulSet state from files ==="
STATE_DIR=""
mkdir -p "$WORK_DIR/bin"
cat > "$WORK_DIR/bin/kubectl" <<'FAKE'
#!/bin/bash
# Fake kubectl: StatefulSet state lives in $KUBECTL_STATE_DIR/<name>.env with
# REPLICAS, PARTITION, CURRENT, UPDATE, READY, UNFROZE_AT. Partition patches
# and annotations update the files; patches are also appended to a log file
# next to the state directory.
set -u
STATE_DIR="${KUBECTL_STATE_DIR:?}"
LOG_DIR="$(dirname "$STATE_DIR")"

update_state() { # <file> <key> <value>
  grep -v "^$2=" "$1" > "$1.tmp" || true
  echo "$2=$3" >> "$1.tmp"
  mv "$1.tmp" "$1"
}

cmd=${1:-}; shift || true
case "$cmd" in
  get)
    kind=${1:-}; shift
    if [[ "$kind" == statefulset* || "$kind" == sts ]]; then
      name=$1; shift
      f="$STATE_DIR/$name.env"
      [[ -f "$f" ]] || { echo "statefulsets.apps \"$name\" not found" >&2; exit 1; }
      # shellcheck disable=SC1090
      source "$f"
      jp=""
      while (($#)); do case "$1" in -o) jp=$2; shift 2 ;; *) shift ;; esac; done
      case "$jp" in
        *updateStrategy*) printf '%s|%s|%s|%s|%s' "${REPLICAS:-}" "${PARTITION:-}" "${CURRENT:-}" "${UPDATE:-}" "${READY:-}" ;;
        *unfroze-at*) printf '%s' "${UNFROZE_AT:-}" ;;
        '') echo "$name" ;;
        *) echo "fake kubectl: unhandled jsonpath: $jp" >&2; exit 9 ;;
      esac
    elif [[ "$kind" == pod* ]]; then
      echo "NAME READY STATUS (fake pod listing)"
    else
      echo "fake kubectl: unhandled get $kind" >&2; exit 9
    fi
    ;;
  patch)
    name=$2; shift 2
    json=""
    while (($#)); do case "$1" in -p) json=$2; shift 2 ;; *) shift ;; esac; done
    part=$(sed -E 's/.*"partition":([0-9]+).*/\1/' <<<"$json")
    echo "PATCH $name partition=$part" >> "$LOG_DIR/patches.log"
    update_state "$STATE_DIR/$name.env" PARTITION "$part"
    ;;
  annotate)
    name=$2; shift 2
    f="$STATE_DIR/$name.env"
    for a in "$@"; do
      case "$a" in
        *unfroze-at=*) update_state "$f" UNFROZE_AT "${a#*=}" ;;
        *unfroze-at-)  update_state "$f" UNFROZE_AT "" ;;
      esac
    done
    ;;
  *) echo "fake kubectl: unhandled command: $cmd" >&2; exit 9 ;;
esac
FAKE
chmod +x "$WORK_DIR/bin/kubectl"
export PATH="$WORK_DIR/bin:$PATH"

sts() { # <name> <replicas> <partition> <current> <update> <ready> [unfroze_at]
  cat > "$KUBECTL_STATE_DIR/$1.env" <<EOF
REPLICAS=$2
PARTITION=$3
CURRENT=$4
UPDATE=$5
READY=$6
UNFROZE_AT=${7:-}
EOF
}

scenario() { # <name>
  SCEN_DIR="$WORK_DIR/scen/$1"
  mkdir -p "$SCEN_DIR/state"
  export KUBECTL_STATE_DIR="$SCEN_DIR/state"
  : > "$SCEN_DIR/patches.log"
}

run() { # [num_groups] [stall_timeout_minutes]
  NAMESPACE=test NUM_NODE_GROUPS=${1:-3} STALL_TIMEOUT_MINUTES=${2:-270} \
    bash "$SCRIPT" > "$SCEN_DIR/run.log" 2>&1
  echo $? > "$SCEN_DIR/exit"
}

get() { (source "$KUBECTL_STATE_DIR/$1.env"; eval echo "\$$2"); }

echo "--- all frozen, one update pending: unfreeze the lowest group only ---"
scenario pending
sts node-group-0 2 2 revA revB 2
sts node-group-1 2 2 revA revB 2
sts node-group-2 2 2 revA revB 2
run
assert "exit 0" '[[ $(cat $SCEN_DIR/exit) == 0 ]]'
assert "group 0 unfrozen" '[[ $(get node-group-0 PARTITION) == 0 ]]'
assert "group 1 stays frozen" '[[ $(get node-group-1 PARTITION) == 2 ]]'
assert "group 2 stays frozen" '[[ $(get node-group-2 PARTITION) == 2 ]]'
assert "start time recorded" '[[ -n $(get node-group-0 UNFROZE_AT) ]]'
assert "only one partition patch" '[[ $(count "^PATCH" $SCEN_DIR/patches.log) == 1 ]]'

echo "--- a group is still updating: do nothing ---"
scenario rolling
sts node-group-0 2 0 revA revB 1 "$(date +%s)"
sts node-group-1 2 2 revA revB 2
sts node-group-2 2 2 revA revB 2
run
assert "no partition patches" '[[ $(count "^PATCH" $SCEN_DIR/patches.log) == 0 ]]'

echo "--- a group finished: re-freeze it and move on to the next in one run ---"
scenario advance
sts node-group-0 2 0 revB revB 2 "$(date +%s)"
sts node-group-1 2 2 revA revB 2
sts node-group-2 2 2 revA revB 2
run
assert "group 0 re-frozen" '[[ $(get node-group-0 PARTITION) == 2 ]]'
assert "group 0 start time cleared" '[[ -z $(get node-group-0 UNFROZE_AT) ]]'
assert "group 1 unfrozen" '[[ $(get node-group-1 PARTITION) == 0 ]]'
assert "group 2 stays frozen" '[[ $(get node-group-2 PARTITION) == 2 ]]'

echo "--- a group is stuck past the stall timeout: log the stall, hold the rollout ---"
scenario stall
sts node-group-0 2 0 revA revB 1 100
sts node-group-1 2 2 revA revB 2
sts node-group-2 2 2 revA revB 2
run
assert "stall logged" '[[ $(count "STALL: node-group-0" $SCEN_DIR/run.log) == 1 ]]'
assert "stuck group stays unfrozen" '[[ $(get node-group-0 PARTITION) == 0 ]]'
assert "group 1 not unfrozen" '[[ $(get node-group-1 PARTITION) == 2 ]]'
run
assert "stall re-logged on every run" '[[ $(count "STALL: node-group-0" $SCEN_DIR/run.log) == 1 ]]'

echo "--- another group is unhealthy: hold the pending update until it heals ---"
scenario unhealthy
sts node-group-0 2 2 revA revB 2
sts node-group-1 2 2 revB revB 1
sts node-group-2 2 2 revB revB 2
run
assert "group 0 not unfrozen while group 1 is unhealthy" '[[ $(get node-group-0 PARTITION) == 2 ]]'
assert "hold is logged" '[[ $(count "held: another group is unhealthy" $SCEN_DIR/run.log) == 1 ]]'
sts node-group-1 2 2 revB revB 2
run
assert "group 0 unfrozen once group 1 healed" '[[ $(get node-group-0 PARTITION) == 0 ]]'

echo "--- a group was unfrozen by hand: take it over, don't unfreeze more ---"
scenario manual
sts node-group-0 2 2 revA revB 2
sts node-group-1 2 0 revA revB 1
sts node-group-2 2 2 revA revB 2
run
assert "start time stamped on the manual group" '[[ -n $(get node-group-1 UNFROZE_AT) ]]'
assert "group 0 not unfrozen" '[[ $(get node-group-0 PARTITION) == 2 ]]'
assert "no partition patches" '[[ $(count "^PATCH" $SCEN_DIR/patches.log) == 0 ]]'

echo "--- a StatefulSet is missing: skip it and keep going ---"
scenario missing
sts node-group-0 2 2 revB revB 2
sts node-group-1 2 2 revA revB 2
run
assert "exit 0" '[[ $(cat $SCEN_DIR/exit) == 0 ]]'
assert "group 1 still handled" '[[ $(get node-group-1 PARTITION) == 0 ]]'
assert "missing group logged" '[[ $(count "node-group-2 not found; skipping" $SCEN_DIR/run.log) == 1 ]]'

echo "--- everything up to date: no changes at all ---"
scenario idle
sts node-group-0 2 2 revB revB 2
sts node-group-1 2 2 revB revB 2
sts node-group-2 2 2 revB revB 2
run
assert "no patches" '[[ ! -s $SCEN_DIR/patches.log ]]'
assert "nothing-to-do logged" '[[ $(count "nothing to do" $SCEN_DIR/run.log) == 1 ]]'

echo "--- a broken start-time annotation: recover instead of crashing ---"
scenario badannotation
sts node-group-0 2 0 revA revB 1 "not-a-number"
sts node-group-1 2 2 revA revB 2
run 2
assert "exit 0 (no crash)" '[[ $(cat $SCEN_DIR/exit) == 0 ]]'
assert "start time replaced with a number" '[[ $(get node-group-0 UNFROZE_AT) =~ ^[0-9]+$ ]]'

echo
echo "RESULT: $PASS passed, $FAIL failed"
[[ $FAIL == 0 ]]
