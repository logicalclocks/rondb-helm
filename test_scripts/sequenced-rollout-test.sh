#!/bin/bash

# Copyright (c) 2024-2026 Hopsworks AB. All rights reserved.

# Tests for the sequenced data node rollout (ndbmtdSequencedRollout).
# Needs only helm and bash — no cluster.
#
# Part 1 — rendering: the partition freeze and the rollout CronJob render
#   together when the feature applies, and not at all when it doesn't
#   (flag off, single node group).
# Part 2 — behavior: extracts the rollout script from the rendered CronJob
#   and runs it against a fake kubectl that serves StatefulSet and pod state
#   from files, checking every state it can act on: unfreeze order,
#   re-freeze, stall reporting, holding while another group is unhealthy,
#   delivering a pending update to a group that is itself unhealthy (and
#   refusing when that would delete a live pod), taking over manually
#   unfrozen groups, and missing StatefulSets.

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
assert "pod get/delete restricted to data-node pod names" '[[ $(count "node-group-1-1$" $WORK_DIR/on.yaml) -ge 1 ]]'
assert "pod delete verb only in the name-restricted rule" 'grep -q "verbs: \[\"get\", \"delete\"\]" $WORK_DIR/on.yaml'
assert "unrestricted pod rule is list-only" 'grep -q "verbs: \[\"list\"\]" $WORK_DIR/on.yaml && ! grep -q "verbs: \[\"get\", \"list\", \"delete\"\]" $WORK_DIR/on.yaml'
assert "suspend not templated (avoids server-side-apply conflict)" '[[ $(count "^  suspend:" $WORK_DIR/on.yaml) == 0 ]]'
assert "wake hook renders when self-suspend is active" '[[ $(count "rondb-ndbmtd-sequenced-rollout-wake" $WORK_DIR/on.yaml) -ge 1 ]]'
assert "wake hook is a post-upgrade/rollback helm hook" 'grep -q "helm.sh/hook: post-upgrade,post-rollback" $WORK_DIR/on.yaml'
assert "suspend-when-idle on without mode" 'grep -A1 "name: SUSPEND_WHEN_IDLE" $WORK_DIR/on.yaml | grep -q "\"true\""'

echo "=== rendering: flag on with mode set (Argo convention) -> no self-suspend ==="
render "$WORK_DIR/argo.yaml" --set clusterSize.numNodeGroups=2 \
  --set ndbmtdSequencedRollout.enabled=true --set mode=upgrade
assert "suspend-when-idle off when mode is set" 'grep -A1 "name: SUSPEND_WHEN_IDLE" $WORK_DIR/argo.yaml | grep -q "\"false\""'
assert "no wake hook under mode (Argo would map it to PostSync)" '[[ $(count "rondb-ndbmtd-sequenced-rollout-wake" $WORK_DIR/argo.yaml) == 0 ]]'

echo "=== rendering: flag on, 1 node group -> feature off (nothing to sequence) ==="
render "$WORK_DIR/one.yaml" --set ndbmtdSequencedRollout.enabled=true
assert "no partition with a single group" '[[ $(count "partition:" $WORK_DIR/one.yaml) == 0 ]]'
assert "no CronJob with a single group" '[[ $(count "ndbmtd-sequenced-rollout" $WORK_DIR/one.yaml) == 0 ]]'

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
assert "kubectl request-timeout not used (breaks in-cluster auth)" \
  '! grep -Ev "^[[:space:]]*#" "$SCRIPT" | grep -q -- "--request-timeout"'
assert "kubectl wrapper applies timeout and namespace" \
  'grep -q '\''timeout 15s kubectl -n "$NAMESPACE" "$@"'\'' "$SCRIPT"'
assert "no obsolete kubectl-argument array" '! grep -q '\''KC=('\'' "$SCRIPT"'

echo "=== behavior: fake kubectl serving StatefulSet state from files ==="
STATE_DIR=""
mkdir -p "$WORK_DIR/bin"
cat > "$WORK_DIR/bin/timeout" <<'FAKE'
#!/bin/bash
# The production image provides GNU timeout. The test only needs to forward
# the command so it remains portable to development machines without it.
shift
exec "$@"
FAKE
cat > "$WORK_DIR/bin/kubectl" <<'FAKE'
#!/bin/bash
# Fake kubectl: StatefulSet state lives in $KUBECTL_STATE_DIR/<name>.env with
# REPLICAS, PARTITION, CURRENT, UPDATE, READY, UNFROZE_AT. Partition patches
# and annotations update the files; patches are also appended to a log file
# next to the state directory.
set -u
STATE_DIR="${KUBECTL_STATE_DIR:?}"
LOG_DIR="$(dirname "$STATE_DIR")"

if [[ "${KUBECTL_FORCE_ERROR:-false}" == true ]]; then
  echo "Unable to connect to the server: simulated API failure" >&2
  exit 1
fi

# Consume global flags placed before the kubectl subcommand by kube().
while (($#)); do
  case "$1" in
    -n|--namespace) shift 2 ;;
    *) break ;;
  esac
done

update_state() { # <file> <key> <value>
  grep -v "^$2=" "$1" > "$1.tmp" || true
  echo "$2=$3" >> "$1.tmp"
  mv "$1.tmp" "$1"
}

cmd=${1:-}; shift || true
case "$cmd" in
  get)
    kind=${1:-}; shift
    if [[ "$kind" == cronjob* ]]; then
      f="$STATE_DIR/cronjob.env"
      [[ -f "$f" ]] || { echo "cronjobs.batch not found" >&2; exit 1; }
      # shellcheck disable=SC1090
      source "$f"
      printf '%s' "${SUSPEND:-}"
    elif [[ "$kind" == statefulset* || "$kind" == sts ]]; then
      name=$1; shift
      f="$STATE_DIR/$name.env"
      [[ -f "$f" ]] || { echo "statefulsets.apps \"$name\" not found" >&2; exit 1; }
      # shellcheck disable=SC1090
      source "$f"
      scnt="$LOG_DIR/stsgets"
      sn=$(( $(cat "$scnt" 2>/dev/null || echo 0) + 1 )); echo "$sn" > "$scnt"
      upd="${UPDATE:-}"
      if [[ -n "${KUBECTL_STS_UPDATE_FLIP_AFTER:-}" ]] && (( sn >= KUBECTL_STS_UPDATE_FLIP_AFTER )); then
        upd="${KUBECTL_STS_UPDATE_FLIP_TO:?}"
      fi
      jp=""
      while (($#)); do case "$1" in -o) jp=$2; shift 2 ;; *) shift ;; esac; done
      case "$jp" in
        *observedGeneration*) printf '%s|%s|%s|%s|%s|%s|%s' "${REPLICAS:-}" "${PARTITION:-}" "${CURRENT:-}" "$upd" "${READY:-}" "${GEN:-1}" "${OGEN:-1}" ;;
        *updateStrategy*) printf '%s|%s|%s|%s|%s' "${REPLICAS:-}" "${PARTITION:-}" "${CURRENT:-}" "$upd" "${READY:-}" ;;
        *unfroze-at*) printf '%s' "${UNFROZE_AT:-}" ;;
        '') echo "$name" ;;
        *) echo "fake kubectl: unhandled jsonpath: $jp" >&2; exit 9 ;;
      esac
    elif [[ "$kind" == pod* ]]; then
      if [[ "${1:-}" == -* || -z "${1:-}" ]]; then
        joined="$*"
        if [[ "$joined" == *deletionTimestamp* ]]; then
          # Terminating-pod census: group indexes, one per line, from the
          # scenario's terminating.txt (absent = none terminating).
          cat "$STATE_DIR/terminating.txt" 2>/dev/null || true
          exit 0
        fi
        echo "NAME READY STATUS (fake pod listing)"
      else
        # Per-call hooks let scenarios change the world between the safety
        # walk and the pre-delete re-read (n counts pod GETs in this run).
        cnt="$LOG_DIR/podgets"
        n=$(( $(cat "$cnt" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$cnt"
        if [[ -n "${KUBECTL_POD_ERROR_AFTER:-}" ]] && (( n >= KUBECTL_POD_ERROR_AFTER )); then
          echo "Unable to connect to the server: simulated API failure" >&2
          exit 1
        fi
        if [[ "${KUBECTL_FORCE_POD_ERROR:-false}" == true ]]; then
          echo "Unable to connect to the server: simulated API failure" >&2
          exit 1
        fi
        name=$1; shift
        f="$STATE_DIR/$name.pod.env"
        [[ -f "$f" ]] || { echo "pods \"$name\" not found" >&2; exit 1; }
        # shellcheck disable=SC1090
        source "$f"
        ready="${READY:-}"
        if [[ -n "${KUBECTL_POD_READY_FLIP_AFTER:-}" ]] && (( n >= KUBECTL_POD_READY_FLIP_AFTER )); then
          ready="True"
        fi
        rev="${REV:-}"
        if [[ -n "${KUBECTL_POD_REV_FLIP_AFTER:-}" ]] && (( n >= KUBECTL_POD_REV_FLIP_AFTER )); then
          rev="${KUBECTL_POD_REV_FLIP_TO:?}"
        fi
        printf '%s|%s|%s' "${TERM_TS:-}" "$rev" "$ready"
      fi
    else
      echo "fake kubectl: unhandled get $kind" >&2; exit 9
    fi
    ;;
  patch)
    kind=$1; name=$2; shift 2
    json=""
    while (($#)); do case "$1" in -p) json=$2; shift 2 ;; *) shift ;; esac; done
    if [[ "$kind" == cronjob* ]]; then
      sus=$(sed -E 's/.*"suspend":(true|false).*/\1/' <<<"$json")
      echo "PATCH-CRONJOB suspend=$sus" >> "$LOG_DIR/patches.log"
      update_state "$STATE_DIR/cronjob.env" SUSPEND "$sus"
    else
      part=$(sed -E 's/.*"partition":([0-9]+).*/\1/' <<<"$json")
      echo "PATCH $name partition=$part" >> "$LOG_DIR/patches.log"
      update_state "$STATE_DIR/$name.env" PARTITION "$part"
      # A spec change bumps metadata.generation; observedGeneration lags
      # until the (simulated) controller observes it — see observe().
      gen=$(grep '^GEN=' "$STATE_DIR/$name.env" | cut -d= -f2 || true)
      update_state "$STATE_DIR/$name.env" GEN "$(( ${gen:-1} + 1 ))"
    fi
    ;;
  delete)
    if [[ "${KUBECTL_FORCE_DELETE_ERROR:-false}" == true ]]; then
      echo "Unable to connect to the server: simulated API failure" >&2
      exit 1
    fi
    if [[ "${KUBECTL_DELETE_NOTFOUND:-false}" == true ]]; then
      echo "Error from server (NotFound): pods \"${2:-}\" not found" >&2
      exit 1
    fi
    kind=$1; name=$2
    echo "DELETE $kind $name" >> "$LOG_DIR/patches.log"
    rm -f "$STATE_DIR/$name.pod.env"
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
chmod +x "$WORK_DIR/bin/kubectl" "$WORK_DIR/bin/timeout"
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

pod() { # <name> <controller-revision> <ready: True|False> [deletion-timestamp]
  printf 'REV=%s\nREADY=%s\nTERM_TS=%s\n' "$2" "$3" "${4:-}" > "$KUBECTL_STATE_DIR/$1.pod.env"
}

observe() { # <name> — the controller observes the spec: OGEN := GEN
  local f="$KUBECTL_STATE_DIR/$1.env" gen
  gen=$(grep '^GEN=' "$f" | cut -d= -f2 || true)
  grep -v '^OGEN=' "$f" > "$f.tmp" || true
  echo "OGEN=${gen:-1}" >> "$f.tmp"
  mv "$f.tmp" "$f"
}

scenario() { # <name>
  SCEN_DIR="$WORK_DIR/scen/$1"
  mkdir -p "$SCEN_DIR/state"
  export KUBECTL_STATE_DIR="$SCEN_DIR/state"
  : > "$SCEN_DIR/patches.log"
}

run() { # [num_groups] [stall_timeout_minutes] [suspend_when_idle]
  set +e
  NAMESPACE=test NUM_NODE_GROUPS=${1:-3} STALL_TIMEOUT_MINUTES=${2:-270} \
    CRONJOB_NAME=rondb-ndbmtd-sequenced-rollout SUSPEND_WHEN_IDLE=${3:-false} \
    bash "$SCRIPT" > "$SCEN_DIR/run.log" 2>&1
  local status=$?
  set -e
  echo "$status" > "$SCEN_DIR/exit"
}

get() { (source "$KUBECTL_STATE_DIR/$1.env"; eval echo "\$$2"); }
cronjob() { printf 'SUSPEND="%s"\n' "$1" > "$KUBECTL_STATE_DIR/cronjob.env"; }
get_suspend() { (source "$KUBECTL_STATE_DIR/cronjob.env"; echo "${SUSPEND:-}"); }

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
assert "hold names the group that is actually unhealthy" '[[ $(count "held: unhealthy: node-group-1" $SCEN_DIR/run.log) == 1 ]]'
sts node-group-1 2 2 revB revB 2
run
assert "group 0 unfrozen once group 1 healed" '[[ $(get node-group-0 PARTITION) == 0 ]]'

echo "--- a pending group is itself unhealthy (bad build): deliver its fix anyway ---"
# Group 0 took bad build revB on its top pod, then fix revC landed and Helm
# re-froze the group. Its own sickness must not hold its own repair.
scenario selfsick
sts node-group-0 2 2 revA revC 1
pod node-group-0-0 revA True
pod node-group-0-1 revB False
sts node-group-1 2 2 revA revC 2
sts node-group-2 2 2 revA revC 2
run
assert "broken group unfrozen to receive the fix" '[[ $(get node-group-0 PARTITION) == 0 ]]'
assert "unfreeze logged for the broken group" '[[ $(count "unfreezing node-group-0" $SCEN_DIR/run.log) == 1 ]]'
assert "no hold logged" '[[ $(count "held:" $SCEN_DIR/run.log) == 0 ]]'
# The unfreeze run's own partition patch bumps the generation, so its delete
# defers until the controller observes the spec (fail closed on lagging
# status); the next run's retry then replaces the dead pod itself — needed
# because from k8s 1.35.0 the (beta/on) MaxUnavailableStatefulSet path
# deletes nothing in a group that already has an unavailable pod, not even
# the dead old-revision pod (k8s #137409).
assert "delete deferred until the spec is observed" '[[ $(count "unobserved spec change" $SCEN_DIR/run.log) == 1 && $(count "^DELETE" $SCEN_DIR/patches.log) == 0 ]]'
observe node-group-0
run
assert "dead pod deleted on the next run so the fix reaches it" '[[ $(count "^DELETE pod node-group-0-1" $SCEN_DIR/patches.log) == 1 ]]'

echo "--- the unhealthy pending group is not the lowest: prefer it over healthy ones ---"
# A node of group 1 is down and the pending update is its likely repair;
# unfreezing healthy group 0 first would degrade a second group instead.
scenario prefersick
sts node-group-0 2 2 revA revB 2
sts node-group-1 2 2 revA revB 1
pod node-group-1-0 revA True
pod node-group-1-1 revA False
sts node-group-2 2 2 revA revB 2
run
assert "sick pending group unfrozen first" '[[ $(get node-group-1 PARTITION) == 0 ]]'
assert "healthy lower group stays frozen" '[[ $(get node-group-0 PARTITION) == 2 ]]'
assert "only one partition patch" '[[ $(count "^PATCH" $SCEN_DIR/patches.log) == 1 ]]'
assert "delete deferred until the spec is observed" '[[ $(count "unobserved spec change" $SCEN_DIR/run.log) == 1 && $(count "^DELETE" $SCEN_DIR/patches.log) == 0 ]]'
observe node-group-1
run
assert "its dead pod deleted once the spec is observed" '[[ $(count "^DELETE pod node-group-1-1" $SCEN_DIR/patches.log) == 1 ]]'

echo "--- the sick pending group's DEAD pod is ordinal 0: hold, never delete a live pod ---"
# The controller would delete the live ordinal-1 pod first, leaving the
# group with zero replicas. Refuse and say why.
scenario deadlow
sts node-group-0 2 2 revA revB 1
pod node-group-0-0 revA False
pod node-group-0-1 revA True
sts node-group-1 2 2 revA revB 2
run
assert "no partition patches" '[[ $(count "^PATCH" $SCEN_DIR/patches.log) == 0 ]]'
assert "safety hold logged" '[[ $(count "would not replace its dead pod first" $SCEN_DIR/run.log) == 1 ]]'

echo "--- the pending update itself broke the top pod: hold, the update cannot repair it ---"
# Ordinal 1 already carries the (bad) update revision and is down; the
# controller would wait on it, so unfreezing gains nothing — hold until a
# genuinely new revision lands.
scenario badupdate
sts node-group-0 2 2 revA revB 1
pod node-group-0-0 revA True
pod node-group-0-1 revB False
sts node-group-1 2 2 revA revB 2
run
assert "no partition patches" '[[ $(count "^PATCH" $SCEN_DIR/patches.log) == 0 ]]'
assert "safety hold logged" '[[ $(count "would not replace its dead pod first" $SCEN_DIR/run.log) == 1 ]]'

echo "--- the sick pending group's dead pod object is gone entirely: safe, unfreeze ---"
scenario podgone
sts node-group-0 2 2 revA revB 1
pod node-group-0-0 revA True
run 1
assert "group unfrozen" '[[ $(get node-group-0 PARTITION) == 0 ]]'
assert "nothing to delete when the pod is already gone" '[[ $(count "^DELETE" $SCEN_DIR/patches.log) == 0 ]]'

echo "--- the dead-pod delete fails on the unfreeze run: retried on the next run ---"
scenario deleteretry
sts node-group-0 2 2 revA revC 1
pod node-group-0-0 revA True
pod node-group-0-1 revB False
sts node-group-1 2 2 revA revC 2
run
observe node-group-0
export KUBECTL_FORCE_DELETE_ERROR=true
run
unset KUBECTL_FORCE_DELETE_ERROR
assert "group still unfrozen despite the failed delete" '[[ $(get node-group-0 PARTITION) == 0 ]]'
assert "failed delete is a WARN, not a crash" '[[ $(cat $SCEN_DIR/exit) == 0 && $(count "WARN: could not delete node-group-0-1" $SCEN_DIR/run.log) == 1 ]]'
assert "no delete recorded yet" '[[ $(count "^DELETE" $SCEN_DIR/patches.log) == 0 ]]'
run
assert "delete retried and lands on the next run" '[[ $(count "^DELETE pod node-group-0-1" $SCEN_DIR/patches.log) == 1 ]]'
assert "retry logged from the unfrozen branch" '[[ $(count "replacing dead pod node-group-0-1" $SCEN_DIR/run.log) == 1 ]]'

echo "--- both pods down, top one already on the update revision: stop where the controller stops ---"
# The controller waits at the unavailable updated ordinal 1 and never
# considers ordinal 0 (classic path returns at the first unavailable pod;
# the MaxUnavailable path deletes nothing while any pod is unavailable).
# Deleting ordinal 0 ourselves would diverge from it — and could remove a
# pod recovering onto the still-working revision.
scenario bothdown
sts node-group-0 2 2 revA revB 0
pod node-group-0-0 revA False
pod node-group-0-1 revB False
sts node-group-1 2 2 revA revB 2
run
assert "no partition patches" '[[ $(count "^PATCH" $SCEN_DIR/patches.log) == 0 ]]'
assert "no pod deleted below the controller's wait point" '[[ $(count "^DELETE" $SCEN_DIR/patches.log) == 0 ]]'
assert "safety hold logged" '[[ $(count "would not replace its dead pod first" $SCEN_DIR/run.log) == 1 ]]'

echo "--- a SECOND pod of the group is also down: unfreeze, but leave the delete to the controller ---"
# With another pod unavailable, the MaxUnavailable controller would keep even
# a just-recovered candidate, so the direct delete may not claim to reproduce
# controller behaviour. Unfreezing stays correct: a classic controller
# repairs the group by itself; a gated one holds, honestly stalled.
scenario lowerdown
sts node-group-0 2 0 revA revB 0 "$(date +%s)"
pod node-group-0-0 revA False
pod node-group-0-1 revA False
sts node-group-1 2 2 revA revB 2
run
assert "group unfrozen" '[[ $(get node-group-0 PARTITION) == 0 ]]'
assert "no direct delete with a second pod down" '[[ $(count "^DELETE" $SCEN_DIR/patches.log) == 0 ]]'
assert "the skip is logged with the reason" '[[ $(count "not the group.s only unavailable pod" $SCEN_DIR/run.log) == 1 ]]'

echo "--- a DIFFERENT group has a Ready-but-terminating pod: counts as unhealthy, hold ---"
# status.readyReplicas still counts a terminating pod, so the StatefulSet
# looks healthy while the controller sees it as degraded. Cross-group
# classification must use the terminating-pod census.
scenario crossterm
sts node-group-0 2 2 revA revB 2
sts node-group-1 2 2 revB revB 2
printf '1\n' > "$KUBECTL_STATE_DIR/terminating.txt"
run 2
assert "group 0 held while group 1 has a terminating pod" '[[ $(get node-group-0 PARTITION) == 2 ]]'
assert "hold names the terminating group" '[[ $(count "held: unhealthy: node-group-1" $SCEN_DIR/run.log) == 1 ]]'

echo "--- a PENDING group with a Ready-but-terminating pod is preferred as the target ---"
scenario crosstermprefer
sts node-group-0 2 2 revA revB 2
sts node-group-1 2 2 revA revB 2
pod node-group-1-0 revA True
pod node-group-1-1 revA True 2026-09-01T00:00:00Z
printf '1\n' > "$KUBECTL_STATE_DIR/terminating.txt"
run 2
assert "terminating pending group unfrozen, not group 0" '[[ $(get node-group-1 PARTITION) == 0 && $(get node-group-0 PARTITION) == 2 ]]'

echo "--- the controller has not observed a spec change yet: defer the delete ---"
# status.updateRevision lags a spec change until the controller reconciles;
# with generation ahead of observedGeneration the status must not be trusted
# — the candidate might already carry the newly desired (e.g. rollback)
# revision.
scenario unobserved
sts node-group-0 2 2 revA revC 1
printf 'GEN=3\nOGEN=2\n' >> "$KUBECTL_STATE_DIR/node-group-0.env"
pod node-group-0-0 revA True
pod node-group-0-1 revB False
run 1
assert "group still unfrozen (repair deferred, not abandoned)" '[[ $(get node-group-0 PARTITION) == 0 ]]'
assert "no delete on an unobserved spec" '[[ $(count "^DELETE" $SCEN_DIR/patches.log) == 0 ]]'
assert "deferral is logged" '[[ $(count "unobserved spec change" $SCEN_DIR/run.log) == 1 ]]'
observe node-group-0
run 1
assert "deferred, not abandoned: delete lands once observed" '[[ $(count "^DELETE pod node-group-0-1" $SCEN_DIR/patches.log) == 1 ]]'

echo "--- the StatefulSet's update revision changes between decision and delete: leave it ---"
# sts GET #1 is the scan, #2 is replace_dead_pod's re-read — flip the update
# revision there, simulating a concurrent helm operation.
scenario stschanged
sts node-group-0 2 0 revA revC 1 "$(date +%s)"
pod node-group-0-0 revA True
pod node-group-0-1 revB False
export KUBECTL_STS_UPDATE_FLIP_AFTER=2 KUBECTL_STS_UPDATE_FLIP_TO=revD
run 1
unset KUBECTL_STS_UPDATE_FLIP_AFTER KUBECTL_STS_UPDATE_FLIP_TO
assert "no delete on a stale decision" '[[ $(count "^DELETE" $SCEN_DIR/patches.log) == 0 ]]'
assert "staleness is logged" '[[ $(count "changed since the decision" $SCEN_DIR/run.log) == 1 ]]'

echo "--- another pod is Ready but terminating: it counts as unavailable, no direct delete ---"
# The controller treats a pod with a deletion timestamp as unavailable even
# while its Ready condition is still True.
scenario termready
sts node-group-0 2 0 revA revB 1 "$(date +%s)"
pod node-group-0-0 revA True 2026-09-01T00:00:00Z
pod node-group-0-1 revA False
sts node-group-1 2 2 revA revB 2
run
assert "group unfrozen" '[[ $(get node-group-0 PARTITION) == 0 ]]'
assert "no direct delete while another pod is terminating" '[[ $(count "^DELETE" $SCEN_DIR/patches.log) == 0 ]]'
assert "the skip is logged" '[[ $(count "not the group.s only unavailable pod" $SCEN_DIR/run.log) == 1 ]]'

echo "--- intermediate partition, below-partition pod also down: no direct delete ---"
# Availability counts every replica, including below the partition: with
# ordinal 0 (below partition 1) unavailable, the MaxUnavailable controller
# would retain even a just-recovered ordinal 1, so the direct delete must
# not claim the bound here either.
scenario partialdown
sts node-group-0 2 1 revA revB 0 "$(date +%s)"
pod node-group-0-0 revA False
pod node-group-0-1 revA False
run 1
assert "no direct delete on an intermediate partition with a second pod down" '[[ $(count "^DELETE" $SCEN_DIR/patches.log) == 0 ]]'
assert "the skip is logged" '[[ $(count "not the group.s only unavailable pod" $SCEN_DIR/run.log) == 1 ]]'

echo "--- the sole-unavailable check itself fails to read a lower pod: skip the delete ---"
# pod GET #1 is the candidate; #2 is the availability check of ordinal 0 —
# fail that one. Unknown availability must suppress the delete, never allow it.
scenario lowerreadfail
sts node-group-0 2 0 revA revC 1 "$(date +%s)"
pod node-group-0-0 revA True
pod node-group-0-1 revB False
export KUBECTL_POD_ERROR_AFTER=2
run 1
unset KUBECTL_POD_ERROR_AFTER
assert "exit 0" '[[ $(cat $SCEN_DIR/exit) == 0 ]]'
assert "group still unfrozen" '[[ $(get node-group-0 PARTITION) == 0 ]]'
assert "no delete on unknown availability" '[[ $(count "^DELETE" $SCEN_DIR/patches.log) == 0 ]]'
assert "the skip is logged" '[[ $(count "not the group.s only unavailable pod" $SCEN_DIR/run.log) == 1 ]]'

echo "--- pod's revision changes between the safety walk and the delete: leave it alone ---"
scenario revflip
sts node-group-0 2 0 revA revC 1 "$(date +%s)"
pod node-group-0-0 revA True
pod node-group-0-1 revB False
export KUBECTL_POD_REV_FLIP_AFTER=2 KUBECTL_POD_REV_FLIP_TO=revC
run 1
unset KUBECTL_POD_REV_FLIP_AFTER KUBECTL_POD_REV_FLIP_TO
assert "group still unfrozen" '[[ $(get node-group-0 PARTITION) == 0 ]]'
assert "replaced pod not deleted" '[[ $(count "^DELETE" $SCEN_DIR/patches.log) == 0 ]]'
assert "revision-change skip is logged" '[[ $(count "changed since the safety check" $SCEN_DIR/run.log) == 1 ]]'

echo "--- partially unfrozen group (partition between 0 and replicas): never touch pods below the partition ---"
# partition=1: pod 1 already updated and Ready, pod 0 old and slow-starting.
# Pod 0 is BELOW the partition — it is recreated on the current revision, so
# deleting it repairs nothing and would kill it again on every reconcile.
scenario partialpartition
sts node-group-0 2 1 revA revB 1 "$(date +%s)"
pod node-group-0-0 revA False
pod node-group-0-1 revB True
run 1
assert "no delete below the partition" '[[ $(count "^DELETE" $SCEN_DIR/patches.log) == 0 ]]'
assert "no replacement logged" '[[ $(count "replacing dead pod" $SCEN_DIR/run.log) == 0 ]]'
assert "partition untouched" '[[ $(get node-group-0 PARTITION) == 1 ]]'

echo "--- pod flips Ready between the safety walk and the delete: leave it alone ---"
scenario flipready
sts node-group-0 2 0 revA revC 1 "$(date +%s)"
pod node-group-0-0 revA True
pod node-group-0-1 revB False
export KUBECTL_POD_READY_FLIP_AFTER=2
run 1
unset KUBECTL_POD_READY_FLIP_AFTER
assert "group still unfrozen" '[[ $(get node-group-0 PARTITION) == 0 ]]'
assert "recovered pod not deleted" '[[ $(count "^DELETE" $SCEN_DIR/patches.log) == 0 ]]'
assert "skip is logged" '[[ $(count "changed since the safety check" $SCEN_DIR/run.log) == 1 ]]'

echo "--- the pre-delete re-read fails: warn, skip the delete, keep the unfreeze ---"
scenario rereadfail
sts node-group-0 2 0 revA revC 1 "$(date +%s)"
pod node-group-0-0 revA True
pod node-group-0-1 revB False
# pod GET #1 is the safety walk's candidate, #2 the sole-unavailable check
# of ordinal 0, #3 the pre-delete re-read — fail that one.
export KUBECTL_POD_ERROR_AFTER=3
run 1
unset KUBECTL_POD_ERROR_AFTER
assert "exit 0 (retried on later runs, not fatal)" '[[ $(cat $SCEN_DIR/exit) == 0 ]]'
assert "re-read failure warned" '[[ $(count "WARN: could not re-read node-group-0-1" $SCEN_DIR/run.log) == 1 ]]'
assert "no delete without a fresh read" '[[ $(count "^DELETE" $SCEN_DIR/patches.log) == 0 ]]'

echo "--- pod vanishes between the re-read and the delete (NotFound): tolerated silently ---"
scenario deletenotfound
sts node-group-0 2 0 revA revC 1 "$(date +%s)"
pod node-group-0-0 revA True
pod node-group-0-1 revB False
export KUBECTL_DELETE_NOTFOUND=true
run 1
unset KUBECTL_DELETE_NOTFOUND
assert "exit 0" '[[ $(cat $SCEN_DIR/exit) == 0 ]]'
assert "delete was attempted" '[[ $(count "replacing dead pod node-group-0-1" $SCEN_DIR/run.log) == 1 ]]'
assert "NotFound is not warned about" '[[ $(count "WARN: could not delete" $SCEN_DIR/run.log) == 0 ]]'

echo "--- pod lookup fails with a non-NotFound error: fail closed, unfreeze nothing ---"
scenario podapifail
sts node-group-0 2 2 revA revB 1
pod node-group-0-0 revA True
pod node-group-0-1 revA False
export KUBECTL_FORCE_POD_ERROR=true
run 1
unset KUBECTL_FORCE_POD_ERROR
assert "exit nonzero" '[[ $(cat $SCEN_DIR/exit) != 0 ]]'
assert "pod read failure logged" '[[ $(count "ERROR: could not read pod" $SCEN_DIR/run.log) == 1 ]]'
assert "no patches after pod API failure" '[[ ! -s $SCEN_DIR/patches.log ]]'

echo "--- a sick pending group exists but ANOTHER group is also sick: hold, name it ---"
scenario twosick
sts node-group-0 2 2 revA revB 2
sts node-group-1 2 2 revB revB 1
sts node-group-2 2 2 revA revB 1
pod node-group-2-0 revA True
pod node-group-2-1 revA False
run
assert "no partition patches" '[[ $(count "^PATCH" $SCEN_DIR/patches.log) == 0 ]]'
assert "hold names the other sick group" '[[ $(count "on node-group-2 held: unhealthy: node-group-1" $SCEN_DIR/run.log) == 1 ]]'

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

echo "--- Kubernetes API failure: fail closed instead of reporting missing groups ---"
scenario api_failure
sts node-group-0 2 2 revA revB 2
export KUBECTL_FORCE_ERROR=true
run 1
unset KUBECTL_FORCE_ERROR
assert "exit nonzero" '[[ $(cat $SCEN_DIR/exit) != 0 ]]'
assert "API failure logged" '[[ $(count "ERROR: could not" $SCEN_DIR/run.log) == 1 ]]'
assert "not misreported as missing" '[[ $(count "not found; skipping" $SCEN_DIR/run.log) == 0 ]]'
assert "no patches after API failure" '[[ ! -s $SCEN_DIR/patches.log ]]'

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

echo "--- everything done with suspend enabled: suspend own CronJob ---"
scenario suspendidle
sts node-group-0 2 2 revB revB 2
sts node-group-1 2 2 revB revB 2
cronjob false
run 2 270 true
assert "cronjob suspended" '[[ $(get_suspend) == true ]]'
assert "suspend logged" '[[ $(count "suspending until the next helm" $SCEN_DIR/run.log) == 1 ]]'
assert "no partition patches" '[[ $(count "^PATCH node" $SCEN_DIR/patches.log) == 0 ]]'

echo "--- suspend disabled: leave the CronJob alone when idle ---"
scenario nosuspend
sts node-group-0 2 2 revB revB 2
cronjob false
run 1 270 false
assert "no cronjob patch" '[[ $(count "PATCH-CRONJOB" $SCEN_DIR/patches.log) == 0 ]]'
assert "plain nothing-to-do logged" '[[ $(count "nothing to do$" $SCEN_DIR/run.log) == 1 ]]'

echo "--- a manual run while suspended finds work: resume the schedule ---"
scenario resume
sts node-group-0 2 2 revA revB 2
sts node-group-1 2 2 revA revB 2
cronjob true
run 2 270 true
assert "cronjob resumed" '[[ $(get_suspend) == false ]]'
assert "resume logged" '[[ $(count "resuming the schedule" $SCEN_DIR/run.log) == 1 ]]'
assert "group 0 unfrozen" '[[ $(get node-group-0 PARTITION) == 0 ]]'

echo
echo "RESULT: $PASS passed, $FAIL failed"
[[ $FAIL == 0 ]]
