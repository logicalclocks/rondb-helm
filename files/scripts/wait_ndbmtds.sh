#!/bin/bash

# Copyright (c) 2024-2026 Hopsworks AB. All rights reserved.



until nslookup $MGMD_HOSTNAME; do
    echo "Waiting for $MGMD_HOSTNAME to be resolvable..."
    sleep $(((RANDOM % 2) + 2))
done

echo "trying to connect to the management node.."
until /srv/hops/mysql/bin/ndb_mgm --ndb-connectstring $MGMD_HOSTNAME -e "show"; do
    echo "Waiting for $MGMD_HOSTNAME to be ready..."
    sleep $(((RANDOM % 2) + 2))
done

{{- $nodeGroups := list -}}
{{- range $nodeGroup := until ($.Values.clusterSize.numNodeGroups | int) -}}
{{- $nodeIds := list -}}
{{- range $replica := until 3 -}}
{{- if lt $replica ($.Values.clusterSize.activeDataReplicas | int) -}}
{{- $nodeIds = append $nodeIds (add (mul $nodeGroup 3) $replica 1) -}}
{{- end -}}
{{- end -}}
{{- $nodeGroups = append $nodeGroups (join " " $nodeIds) -}}
{{- end }}

# The active ndbmtd node ids of each node group
NODE_GROUPS=({{ range $i, $group := $nodeGroups }}{{ if $i }} {{ end }}"{{ $group }}"{{ end }})

# Wait for the ndbmtds in two stages:
#
# 1. Until every node group has a started ndbmtd. Only then is the cluster
#    operational, so this stage has no time limit.
#
# 2. Until every active ndbmtd is started, for at most
#    WAIT_ALL_DATANODES_SECONDS once stage 1 is met. An ndbmtd that is down,
#    e.g. because its host crashed, does not stop an operational cluster
#    from serving, so it must not keep every MySQLd that restarts in Init
#    until that ndbmtd is back. An empty WAIT_ALL_DATANODES_SECONDS means no
#    time limit: the consumers that act on every ndbmtd, such as the restore
#    Job, need all of them (see rondb.container.waitAllDatanodes).
#
# Neither stage gives up with an error. This runs as an init container,
# and staying alive until the dependency is met is the init container
# contract: several consumers are Jobs with backoffLimit=0 (setup-mysqld,
# in-place restore), where exiting non-zero is TERMINAL. A data node that
# finished starting a minute after a bounded wait gave up used to fail the
# setup-mysqld Job permanently — nothing re-runs it, the mysqlds wait forever
# on the Job, and the install is bricked. A stuck wait surfaces as the pod
# staying in Init, which is visible and recoverable; giving up is not.

# "all status" prints one "Node <id>: <state> ..." line per ndbmtd. Match
# the whole prefix: "Node 2: not started" also contains "started".
ndbmtd_started() {
    grep -q "^Node $1: started" <<< "$STATUS"
}

echo "Waiting for the active ndbmtds to be started..."
DEADLINE=""
LAST_REPORT=""
LAST_REPORT_TIME=0
while true; do
    STATUS=$(/srv/hops/mysql/bin/ndb_mgm --ndb-connectstring $MGMD_HOSTNAME -e "all status" 2>&1)

    NOT_STARTED=""
    OPERATIONAL=true
    for NODE_GROUP_IDS in "${NODE_GROUPS[@]}"; do
        NODE_GROUP_STARTED=false
        for NODE_ID in $NODE_GROUP_IDS; do
            if ndbmtd_started $NODE_ID; then
                NODE_GROUP_STARTED=true
            else
                NOT_STARTED="$NOT_STARTED $NODE_ID"
            fi
        done
        if [[ "$NODE_GROUP_STARTED" == "false" ]]; then
            OPERATIONAL=false
        fi
    done

    if [[ -z "$NOT_STARTED" ]]; then
        echo "$STATUS"
        echo "Successfully waited for all active ndbmtds to be started"
        break
    fi

    if [[ "$OPERATIONAL" == "true" ]]; then
        REPORT="Every node group has a started ndbmtd; waiting for ndbmtd(s)$NOT_STARTED"
        if [[ -n "$WAIT_ALL_DATANODES_SECONDS" ]]; then
            if [[ -z "$DEADLINE" ]]; then
                DEADLINE=$(( SECONDS + WAIT_ALL_DATANODES_SECONDS ))
            fi
            if (( SECONDS >= DEADLINE )); then
                echo "$STATUS"
                echo "WARNING: ndbmtd(s)$NOT_STARTED not started after ${WAIT_ALL_DATANODES_SECONDS}s;" \
                     "every node group has a started ndbmtd, so continuing without them"
                break
            fi
            REPORT="$REPORT for at most ${WAIT_ALL_DATANODES_SECONDS}s"
        fi
    else
        # The time limit only runs while the cluster is operational
        DEADLINE=""
        REPORT="Waiting for every node group to have a started ndbmtd; not started:$NOT_STARTED"
    fi

    # Report each change, and every two minutes while nothing changes
    if [[ "$STATUS$REPORT" != "$LAST_REPORT" ]] || (( SECONDS - LAST_REPORT_TIME >= 120 )); then
        echo "$STATUS"
        echo "$REPORT"
        LAST_REPORT="$STATUS$REPORT"
        LAST_REPORT_TIME=$SECONDS
    fi
    sleep $(((RANDOM % 2) + 2))
done
