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

# Set by handle_sigterm; the settle wait and the pre-start check below use it
# to avoid starting ndbmtd with a node id the trap has just deactivated.
TERM_RECEIVED=0

handle_sigterm() {
    TERM_RECEIVED=1
    echo "[K8s Entrypoint ndbmtd] SIGTERM received, deactivating node id $NODE_ID via MGM client"

    # Even when not deactivating nodes, having too many nodes die at once can cause
    # the arbitration to kill the cluster. The living node will not be able to form
    # a majority. Usually, since we are using a RollingUpdate strategy, only one
    # data node (per node group) will be killed at once. It does however become an issue
    # if e.g. the number of replicas is changed from 3 to 1. Then replica 3 and 2 are
    # killed simultaneously. When needing to debug such situtations it can be helpful
    # to restart all data nodes at once.

    while ! ndb_mgm --ndb-connectstring="$MGM_CONNECTSTRING" --connect-retries=1 -e "$NODE_ID deactivate"; do
        echo "[K8s Entrypoint ndbmtd] Deactivated node id $NODE_ID via MGM client was unsuccessful. Retrying..." >&2

        # We can be successful in shutting down the node, but unsuccessful in deactivating
        # it. So far this can be the case if multiple node groups are shutting down at the
        # same time. This is probably due to the fact that the configuration database can
        # only run one change at a time.
        sleep $((NODE_GROUP + 2))
    done
    echo "[K8s Entrypoint ndbmtd] Deactivated node id $NODE_ID via MGM client"
}

# We'll stop the data node by deactivating it instead of shutting it down.
# This will NOT be triggered if the data node fails due to an error.
# It WILL be triggered if the liveness probe fails or the Pod is updated/deleted/re-scheduled.
trap handle_sigterm SIGTERM

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

INITIAL_START=
# This is the first file that is read by the ndbmtd
# WARNING: This env var needs to be aware of symlinks created here
FIRST_FILE_READ=$FILE_SYSTEM_PATH/ndb_${NODE_ID}_fs/D1/DBDIH/P0.sysfile
if [ ! -f "$FIRST_FILE_READ" ]
then
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
        # SIGTERM deactivates our node id and, mid-loop, execution would
        # otherwise just continue; never go on to start a deactivated node.
        if [ "$TERM_RECEIVED" = "1" ]; then
            echo "[K8s Entrypoint ndbmtd] SIGTERM during settle wait; not starting ndbmtd"
            exit 0
        fi

        now=$(date +%s)
        if [ $((now - start_ts)) -ge "$max_s" ]; then
            echo "[K8s Entrypoint ndbmtd] Settle wait hit its ${max_s}s cap; starting anyway"
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

# Final guard: SIGTERM at any point since the trap was installed (including
# during the fallback sleep or between the settle wait and here) has already
# deactivated our node id; starting ndbmtd now would crash-loop on
# "Failed to allocate nodeid". The pod is being torn down anyway.
if [ "$TERM_RECEIVED" = "1" ]; then
    echo "[K8s Entrypoint ndbmtd] SIGTERM received before ndbmtd start; exiting"
    exit 0
fi

# Start ndbmtd, log to stdout and file
ndbmtd --nodaemon --ndb-nodeid=$NODE_ID $INITIAL_START --ndb-connectstring=$MGM_CONNECTION_STRING 2>&1 \
    | tee -a -- "${LOG_DIR}/ndb_${NODE_ID}_out.log"
