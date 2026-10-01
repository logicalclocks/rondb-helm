#!/bin/bash

# Copyright (c) 2024-2026 Hopsworks AB. All rights reserved.



set -euo pipefail

# Requires to calculate Node Id based on Pod name and Node Group

# Equivalent to replication factor of Pod
POD_ID=$(echo $POD_NAME | grep -o '[0-9]\+$')

echo "[K8s Entrypoint ndbmtd] Running Pod ID: $POD_ID in Node Group: $NODE_GROUP"

NODE_ID_OFFSET=$(($NODE_GROUP*3))
NODE_ID=$(($NODE_ID_OFFSET+$POD_ID+1))

echo "[K8s Entrypoint ndbmtd] Running Node Id: $NODE_ID"

MGM_CONNECTSTRING=$MGMD_HOST:1186

# The data node is stopped by DEACTIVATING its node id through the MGMd (a
# managed stop with handover), not by signalling ndbmtd - see handle_sigterm.
# The trap is installed before anything that can take time: bash as PID 1
# ignores an untrapped SIGTERM, so a pod deleted during startup would wait
# out its whole grace period and be SIGKILLed.
GRACE_S={{ include "rondb.gracePeriod" (dict "v" $.Values "component" "ndbmtds") }}
DAEMON_PID=""   # set by rondb.runDaemonAndWait once ndbmtd runs
TRAPPED=0       # tells its wait loop that this trap interrupted the wait

handle_sigterm() {
    TRAPPED=1
    # A signal landing between ndbmtd's launch and the DAEMON_PID assignment
    # finds the pid in the job table.
    DAEMON_PID=${DAEMON_PID:-$(jobs -p %+ 2>/dev/null || true)}
    echo "[K8s Entrypoint ndbmtd] SIGTERM received, deactivating node id $NODE_ID via MGM client"

    # Even when not deactivating nodes, having too many nodes die at once can cause
    # the arbitration to kill the cluster. The living node will not be able to form
    # a majority. Usually, since we are using a RollingUpdate strategy, only one
    # data node (per node group) will be killed at once. It does however become an issue
    # if e.g. the number of replicas is changed from 3 to 1. Then replica 3 and 2 are
    # killed simultaneously. When needing to debug such situtations it can be helpful
    # to restart all data nodes at once.

    # Two budgets, both derived from the grace period, which must also leave
    # room for the node shutdown and process teardown that follow a late
    # success: a fifth of the grace (at least 15s) is reserved for those.
    # - Each deactivate CALL may run up to the full budget (grace minus the
    #   reserve): `ndb_mgm -e "<id> deactivate"` stops the node and waits for
    #   its stop report BEFORE it changes the configuration, so a legitimate
    #   call blocks for the whole node shutdown (minutes on large nodes) and
    #   cutting it short would lose the deactivation.
    # - RETRIES after a failed call stop after 60s: against an unreachable
    #   MGMd (the whole cluster being deleted, say) every call fails at
    #   once, and retrying until the grace expires would end in the kubelet
    #   SIGKILLing ndbmtd - the silent-node stall this handler exists to
    #   prevent. After the cap ndbmtd is stopped directly.
    # Exception: when the MGMd REFUSES because this node is its node group's
    # last live replica, retries continue up to the full budget - a direct
    # stop would down the cluster just the same, while a recovering partner
    # may reach "started" meanwhile and make the deactivate succeed. The
    # refusal strings are what `ndb_mgm -e` prints for error 2002
    # (ndberror.cpp). The DEACTIVATE_*_LIMIT_S variables exist for the tests.
    local reserve_s=$((GRACE_S / 5)); [ "$reserve_s" -ge 15 ] || reserve_s=15
    local full_limit_s=$((GRACE_S - reserve_s)); [ "$full_limit_s" -ge 5 ] || full_limit_s=5
    local retry_limit_s=$full_limit_s; [ "$retry_limit_s" -le 60 ] || retry_limit_s=60
    retry_limit_s=${DEACTIVATE_RETRY_LIMIT_S:-$retry_limit_s}
    full_limit_s=${DEACTIVATE_FULL_LIMIT_S:-$full_limit_s}
    local full_deadline_s=$((SECONDS + full_limit_s)) retry_deadline_s=$((SECONDS + retry_limit_s))
    local budget_s out deactivated=0
    while :; do
        budget_s=$((full_deadline_s - SECONDS))
        [ "$budget_s" -ge 1 ] || break
        if out=$(timeout "$budget_s" ndb_mgm --ndb-connectstring="$MGM_CONNECTSTRING" --connect-retries=1 -e "$NODE_ID deactivate" 2>&1); then
            echo "$out"; deactivated=1; break
        fi
        echo "$out"
        if grep -q -e "would cause system crash" -e "not allowed while nodes are starting or stopping" <<< "$out"; then
            echo "[K8s Entrypoint ndbmtd] MGMd refuses to stop node id $NODE_ID (last live replica of its node group); retrying for up to ${full_limit_s}s" >&2
            retry_deadline_s=$full_deadline_s
        fi
        [ "$SECONDS" -lt "$retry_deadline_s" ] || break
        echo "[K8s Entrypoint ndbmtd] Deactivated node id $NODE_ID via MGM client was unsuccessful. Retrying..." >&2

        # We can be successful in shutting down the node, but unsuccessful in deactivating
        # it. So far this can be the case if multiple node groups are shutting down at the
        # same time. This is probably due to the fact that the configuration database can
        # only run one change at a time.
        budget_s=$((retry_deadline_s - SECONDS))
        sleep $((budget_s < NODE_GROUP + 2 ? budget_s : NODE_GROUP + 2))
    done
    if [ "$deactivated" = 1 ]; then
        echo "[K8s Entrypoint ndbmtd] Deactivated node id $NODE_ID via MGM client"
    elif [ -n "$DAEMON_PID" ]; then
        echo "[K8s Entrypoint ndbmtd] Deactivation of node id $NODE_ID did not succeed within its budget; stopping ndbmtd directly instead" >&2
        # The angel process ignores SIGTERM (angel.cpp); the ndbd child it
        # supervises shuts the node down cleanly on it (ndbd.cpp), after
        # which the angel exits and the wait loop ends the container.
        pkill -TERM -P "$DAEMON_PID" || true
    fi
    # Before ndbmtd runs there is nothing to wait for, and the pod must not
    # go on to start a node id that was just deactivated.
    if [ -z "$DAEMON_PID" ]; then
        echo "[K8s Entrypoint ndbmtd] SIGTERM before ndbmtd start; exiting"
        exit 0
    fi
}
# This will NOT be triggered if the data node fails due to an error.
# It WILL be triggered if the liveness probe fails or the Pod is updated/deleted/re-scheduled.
trap handle_sigterm SIGTERM

# Activating node slots is idempotent; it can however take some seconds.
# Important to run this in main container. If a probe kills the container,
# this script will deactivate the node id. But only the main container will be
# restarted. This is because Stateful Sets only support `restartPolicy: Always`.
echo "[K8s Entrypoint ndbmtd] Activating node id $NODE_ID via MGM client"
while ! ndb_mgm --ndb-connectstring="$MGM_CONNECTSTRING" --connect-retries=1 -e "$NODE_ID activate"; do
    echo "[K8s Entrypoint ndbmtd] Activation failed. Retrying..." >&2
    sleep $((NODE_GROUP + 2))
done
echo "[K8s Entrypoint ndbmtd] Activated node id $NODE_ID via MGM client"

# This is already run in the initContainer; doing this here as a sanity check.
# A main container restart should not change the Pod's IP address.
{{ include "rondb.resolveOwnIp" $ }}

# Creating symlinks to the persistent volume
BASE_DIR={{ include "rondb.dataDir" $ }}
RONDB_VOLUME=${BASE_DIR}{{ include "rondb.ndbmtd.volumeSymlinkPrefix" $ }}
{{ if $.Values.resources.requests.storage.classes.diskColumns }}
RONDB_DIRS=(log ndb_data ndb_undo_files ndb/backups)
{{ else }}
RONDB_DIRS=(log ndb_data ndb_undo_files ndb/backups ndb_data_files)
{{ end }}

echo "[K8s Entrypoint ndbmtd] Creating symlinks to the persistent volume '$RONDB_VOLUME'"
for dir in ${RONDB_DIRS[@]}
do
    # We can safely remove these directories, since the symlink is not part of the image
    rm -rf ${BASE_DIR}/${dir}
    mkdir -p ${RONDB_VOLUME}/${dir}
    ln -s ${RONDB_VOLUME}/${dir} ${BASE_DIR}/${dir}
done

LOG_DIR="${BASE_DIR}/log/"
echo "[K8s Entrypoint ndbmtd] check log dir: ${LOG_DIR}"
if [ -d "$LOG_DIR" ]; then
  ls -al "$LOG_DIR"

  # Double-checked config.ini:
  #   DataDir = ${BASE_DIR}/log
  # So ndb_*log* will move the generated error and trace log files from this directory.
  #
  # CAUTION:
  # If additional files are configured to be stored in this directory in the future,
  # be careful with this move operation — it may affect unrelated files.
  # Known non-matching file kept here deliberately: settle_events_<nodeid>.log
  # (the settle wait's durable audit trail). It must stay outside this glob, or
  # it will be split across an issue_at_ dir on every restart.
  files=($(find "$LOG_DIR" -maxdepth 1 -type f -name 'ndb_*log*'))

  if [ "${#files[@]}" -gt 0 ]; then
    timestamp=$(date +%Y%m%d_%H%M%S)
    target_dir="$LOG_DIR/issue_at_$timestamp"
    mkdir -p "$target_dir"

    echo "[K8s Entrypoint ndbmtd] $target_dir generated in ${LOG_DIR}"
    for file in "${files[@]}"; do
      mv "$file" "$target_dir/"
    done
  fi
fi

# This is the first file that is read by the ndbmtd
# WARNING: This env var needs to be aware of symlinks created here
FIRST_FILE_READ=$FILE_SYSTEM_PATH/ndb_${NODE_ID}_fs/D1/DBDIH/P0.sysfile

# Only set marker path if in-place restore mode (env vars set by ndbd.yaml).
# The marker is stored at the PVC root (RONDB_VOLUME) instead of inside ndb_data
# because ndb_data is wiped/recreated when starting with --initial. Placing the
# marker at the volume root ensures it survives an initial start and can be used
# to decide whether --initial should be run again for a given INPLACE_BACKUP_ID.
INITIAL_DONE_MARKER=""
if [ "${FORCE_INITIAL_START:-}" = "true" ] && [ -n "${INPLACE_BACKUP_ID:-}" ]; then
    INITIAL_DONE_MARKER="${RONDB_VOLUME}/inplace_restore_done_${INPLACE_BACKUP_ID}"
fi

# Determine if --initial should be used
INITIAL_START=
if [ -n "$INITIAL_DONE_MARKER" ]; then
    # In-place restore mode - check BOTH marker AND P0.sysfile for robustness
    if [ ! -f "$INITIAL_DONE_MARKER" ]; then
        echo "[K8s Entrypoint ndbmtd] In-place restore (backup $INPLACE_BACKUP_ID): first start, using --initial"
        INITIAL_START="--initial"
        touch "$INITIAL_DONE_MARKER"
    elif [ ! -f "$FIRST_FILE_READ" ]; then
        # Marker exists BUT no P0.sysfile = previous --initial was interrupted
        echo "[K8s Entrypoint ndbmtd] In-place restore: previous --initial was interrupted, retrying"
        INITIAL_START="--initial"
    else
        echo "[K8s Entrypoint ndbmtd] In-place restore: already initialized, skipping --initial"
    fi
elif [ ! -f "$FIRST_FILE_READ" ]; then
    echo "[K8s Entrypoint ndbmtd] The file $FIRST_FILE_READ does not exist - we'll do an initial start here"
    INITIAL_START="--initial"
else
    echo "[K8s Entrypoint ndbmtd] The file $FIRST_FILE_READ exists - we have started the ndbmtds here before. No initial start is needed."
fi

# Checking whether CPU manager policy is set to "static"
if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
    echo "[K8s Entrypoint ndbmtd] cgroup v2 detected"
    echo "[K8s Entrypoint ndbmtd] Available CPUs: $(cat /sys/fs/cgroup/cpuset.cpus.effective)"
else
    echo "[K8s Entrypoint ndbmtd] cgroup v1 detected"
    echo "[K8s Entrypoint ndbmtd] Available CPUs: $(cat /sys/fs/cgroup/cpuset/cpuset.cpus)"
fi

# Durable record of the settle wait's outcome. The two degraded paths below
# (cap hit, MGMd-unreachable fallback) mean the protection GAVE UP and started
# the kernel anyway; announcing that on stdout only makes it unauditable, since
# per-pod logs are not retained and `kubectl logs --previous` ages out within
# minutes. This file lives on the PV, so it survives pod churn.
#
# The name must NOT match the `ndb_*log*` glob used by the archival step above:
# that glob moves matching files into issue_at_<timestamp>/ on EVERY start, which
# would fragment the very audit trail this exists to keep.
SETTLE_EVENTS_FILE="${LOG_DIR}/settle_events_${NODE_ID}.log"
settle_event() {
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) node=${NODE_ID} $*" >> "$SETTLE_EVENTS_FILE" 2>/dev/null || true
}

# During a rolling restart, Kubernetes deletes a node group's second pod only
# after *observing* the first replacement Ready. That observation spread
# (measured 2.6-10.4s across rounds, bounded by the kubelet/API-server
# publication cycle, which the chart cannot tune) can outrun the time before
# an earlier replacement's kernel connects — and from the moment it connects
# until it reaches the phase-110 restart barrier, a peer disconnecting kills
# it with error 2308. So before starting the kernel, wait until no data node
# has DEPARTED the cluster for quiet_s: the node then begins its climb only
# after the deletion wave has passed. Departures only — replacements
# reconnecting are not a hazard and must not extend the wait. Adaptive rather
# than a fixed sleep because the wave's spread varies 3-10s roll to roll.
#
# This must never prevent a data node from starting: every failure path below
# degrades to a bounded sleep and returns 0 (the script runs under
# `set -euo pipefail`).
wait_for_wave_to_settle() {
    local quiet_s="${NDBMTD_SETTLE_QUIET_S:-8}"
    local max_s="${NDBMTD_SETTLE_MAX_S:-30}"
    local fallback_s="${NDBMTD_SETTLE_FALLBACK_S:-15}"
    local probe_timeout_s="${NDBMTD_SETTLE_PROBE_TIMEOUT_S:-5}"

    # A malformed value must fail SAFE (default) rather than open (disabled):
    # only an explicit, numeric maxWaitSeconds=0 may turn the wait off.
    case "$quiet_s" in *[!0-9]*|''|0)
        echo "[K8s Entrypoint ndbmtd] Invalid NDBMTD_SETTLE_QUIET_S='$quiet_s'; using 8"; quiet_s=8;; esac
    case "$max_s" in *[!0-9]*|'')
        echo "[K8s Entrypoint ndbmtd] Invalid NDBMTD_SETTLE_MAX_S='$max_s'; using 30"; max_s=30;; esac
    case "$fallback_s" in *[!0-9]*|'')
        echo "[K8s Entrypoint ndbmtd] Invalid NDBMTD_SETTLE_FALLBACK_S='$fallback_s'; using 15"; fallback_s=15;; esac
    case "$probe_timeout_s" in *[!0-9]*|''|0)
        echo "[K8s Entrypoint ndbmtd] Invalid NDBMTD_SETTLE_PROBE_TIMEOUT_S='$probe_timeout_s'; using 5"; probe_timeout_s=5;; esac

    if ! [ "$max_s" -gt 0 ] 2>/dev/null; then
        echo "[K8s Entrypoint ndbmtd] Settle wait disabled (NDBMTD_SETTLE_MAX_S=$max_s)"
        settle_event "disabled max_s=${max_s}"
        return 0
    fi

    echo "[K8s Entrypoint ndbmtd] Waiting for cluster membership to settle (quiet ${quiet_s}s, max ${max_s}s)"

    local start_ts now out cur prev last_change failed_probes ever_ok id gone
    start_ts=$(date +%s)
    last_change=$start_ts
    prev="__unset__"
    failed_probes=0
    ever_ok=0

    while true; do
        now=$(date +%s)
        if [ $((now - start_ts)) -ge "$max_s" ]; then
            echo "[K8s Entrypoint ndbmtd] Settle wait hit its ${max_s}s cap; starting anyway"
            settle_event "cap_hit max_s=${max_s}"
            return 0
        fi

        out=$(timeout "$probe_timeout_s" ndb_mgm --ndb-connectstring="$MGM_CONNECTSTRING" --connect-retries=1 -e show 2>/dev/null) || out=""

        if [ -z "$out" ]; then
            failed_probes=$((failed_probes + 1))
            # Blind seconds must not count towards the quiet window: quiet
            # means OBSERVED quiet, so a failed probe resets the timer.
            last_change=$now
            # The fixed-sleep fallback is only for an MGMd that has never
            # answered during this wait. A transient outage mid-wait (the
            # chart deliberately rolls the MGMd during upgrades) just keeps
            # retrying under the max_s cap.
            if [ "$ever_ok" = "0" ] && [ "$failed_probes" -ge 3 ]; then
                echo "[K8s Entrypoint ndbmtd] MGMd unreachable ($failed_probes failed probes, never answered); falling back to a fixed ${fallback_s}s sleep"
                settle_event "mgmd_unreachable_fallback fallback_s=${fallback_s} failed_probes=${failed_probes}"
                sleep "$fallback_s" || true
                return 0
            fi
        else
            ever_ok=1
            failed_probes=0
            # Membership fingerprint: the id= lines carrying a Nodegroup are
            # the connected data nodes (started or starting). Only the id
            # tokens are kept, so a node moving through start phases does not
            # reset the timer.
            cur=$(printf '%s' "$out" | grep -E '^id=[0-9]+' | grep 'Nodegroup:' | awk '{print $1}' | tr '\n' ',' || true)
            if [ "$prev" = "__unset__" ]; then
                # First successful probe: start the quiet clock here.
                prev="$cur"
                last_change=$now
            else
                # Only DEPARTURES reset the quiet timer. A peer disconnecting
                # is what kills a climbing node (FAIL_REP before the phase-110
                # barrier -> error 2308); a node CONNECTING is not a hazard,
                # and during a round every replacement's reconnect would
                # otherwise keep resetting the timer until the max_s cap.
                # Caveat: a disconnect+reconnect landing entirely between two
                # 1s polls is invisible — as it also was to the previous
                # any-change test; sampling cannot see inside the interval.
                gone=0
                for id in ${prev//,/ }; do
                    case ",$cur," in
                        *",$id,"*) ;;
                        *) gone=1; break ;;
                    esac
                done
                prev="$cur"
                if [ "$gone" = "1" ]; then
                    last_change=$now
                elif [ $((now - last_change)) -ge "$quiet_s" ]; then
                    echo "[K8s Entrypoint ndbmtd] No departures for ${quiet_s}s after $((now - start_ts))s total; safe to start"
                    settle_event "quiet_reached total_s=$((now - start_ts)) quiet_s=${quiet_s}"
                    return 0
                fi
            fi
        fi
        sleep 1 || true
    done
}

if [ -n "$INITIAL_START" ]; then
    echo "[K8s Entrypoint ndbmtd] Initial start; skipping the settle wait"
else
    wait_for_wave_to_settle
fi

# Start ndbmtd in the background and wait for it. bash defers traps while a
# foreground command runs, so with the old foreground pipeline handle_sigterm
# never ran and every planned restart ended in a SIGKILL at the end of the
# grace period (RONDB-1132).
{{ include "rondb.runDaemonAndWait" (dict
    "cmd" "ndbmtd --nodaemon --ndb-nodeid=$NODE_ID $INITIAL_START --ndb-connectstring=$MGM_CONNECTION_STRING"
    "log" "${LOG_DIR}/ndb_${NODE_ID}_out.log"
) }}
