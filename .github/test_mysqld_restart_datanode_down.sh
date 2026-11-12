#!/bin/bash

# Copyright (c) 2024-2026 Hopsworks AB. All rights reserved.

# A MySQLd that (re)starts while an active data node stays down must still
# come up: its wait-datanodes-dependency init container waits without a
# time limit only until every node group has a started data node, and then
# at most timeoutsMinutes.waitAllDatanodes for the rest.
#
# Takes data node 2 (pod node-group-0-1) down by scaling node-group-0 to one
# replica, restarts every MySQLd, and checks that each one becomes Ready,
# logged that it continued without node 2, and reads from the data nodes.
# Brings node 2 back on exit. Needs activeDataReplicas=2 and the data of the
# generate-data helm test.
#
# Usage: test_mysqld_restart_datanode_down.sh <namespace>

set -euo pipefail

NS=$1
READY_TIMEOUT=${READY_TIMEOUT:-10m}

trap 'echo "Bringing data node 2 back"; kubectl -n "$NS" scale statefulset node-group-0 --replicas=2' EXIT

echo "Taking data node 2 down"
kubectl -n "$NS" scale statefulset node-group-0 --replicas=1
kubectl -n "$NS" wait --for=delete pod/node-group-0-1 --timeout=5m

MYSQLDS=$(kubectl -n "$NS" get pods -l rondbService=mysqld -o jsonpath='{.items[*].metadata.name}')
[ -n "$MYSQLDS" ] || { echo "No MySQLd pods found"; exit 1; }

echo "Restarting MySQLds: $MYSQLDS"
# Waits until the old pods are gone, so a pod found by name below is the new one
kubectl -n "$NS" delete pod $MYSQLDS

for POD in $MYSQLDS; do
    for ((i = 0; i < 60; i++)); do
        kubectl -n "$NS" get pod "$POD" >/dev/null 2>&1 && break
        sleep 2
    done
    kubectl -n "$NS" wait --for=condition=Ready "pod/$POD" --timeout="$READY_TIMEOUT"

    WAIT_LOG=$(kubectl -n "$NS" logs "$POD" -c wait-datanodes-dependency)
    if ! grep -q "WARNING: ndbmtd(s) 2 not started" <<< "$WAIT_LOG"; then
        echo "$POD did not log that it continued without data node 2:"
        echo "$WAIT_LOG" | tail -20
        exit 1
    fi

    # Readiness only runs "SELECT 1"; reading an NDB table shows the MySQLd
    # is connected to the data nodes. helmtest.t1 is written by the
    # generate-data helm test, which the cluster user can read.
    ROWS=$(kubectl -n "$NS" exec "$POD" -c mysqld -- bash -c \
        'mysql --defaults-file=$RONDB_DATA_DIR/my.cnf --protocol=tcp -N -e "SELECT COUNT(*) FROM helmtest.t1"')
    echo "$POD is Ready and reads $ROWS rows from helmtest.t1"
    if ! [[ "$ROWS" =~ ^[0-9]+$ ]] || [ "$ROWS" -eq 0 ]; then
        echo "Expected rows in helmtest.t1 (written by the generate-data helm test)"
        exit 1
    fi
done

echo "All MySQLds came up while data node 2 was down"
