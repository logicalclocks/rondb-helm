#!/bin/bash

# Copyright (c) 2024-2024 Hopsworks AB. All rights reserved.

# Requires to calculate Node Id based on Pod name and Node Group

# Equivalent to replication factor of Pod
POD_ID=$(echo $POD_NAME | grep -o '[0-9]\+$')

echo "[K8s Entrypoint ndbmtd] Running Pod ID: $POD_ID in Node Group: $NODE_GROUP"

NODE_ID_OFFSET=$(($NODE_GROUP*3))
NODE_ID=$(($NODE_ID_OFFSET+$POD_ID+1))

echo "[K8s Entrypoint ndbmtd] Running Node Id: $NODE_ID"

MGM_CONNECTSTRING=$MGMD_HOST:1186

# Activating node slots is idempotent; it can however take some seconds
(
    set -e
    echo "Activating node id $NODE_ID via MGM client"
    ndb_mgm --ndb-connectstring=$MGM_CONNECTSTRING -e "$NODE_ID activate"
)

{{ include "rondb.resolveOwnIp" $ }}

handle_sigterm() {
    echo "[K8s Entrypoint ndbmtd] SIGTERM received, deactivating node id $NODE_ID via MGM client"

    # Even when not deactivating nodes, having too many nodes die at once can cause
    # the arbitration to kill the cluster. The living node will not be able to form
    # a majority.
    {{- $secondsPerReplica := div $.Values.terminationGracePeriodSeconds 3 }}
    SLEEP_TIME=$(($POD_ID*{{ $secondsPerReplica }}))
    sleep $SLEEP_TIME

    while true; do
        ndb_mgm --ndb-connectstring=$MGM_CONNECTSTRING -e "$NODE_ID deactivate"
        exit_status=$?
        
        if [ $exit_status -eq 0 ]; then
            echo "[K8s Entrypoint ndbmtd] Deactivated node id $NODE_ID via MGM client"
            break
        fi
        echo "[K8s Entrypoint ndbmtd] Deactivated node id $NODE_ID via MGM client was unsuccessful. Retrying..."

        # We can be successful in shutting down the node, but unsuccessful in deactivating
        # it. So far this can be the case if multiple node groups are shutting down at the
        # same time. This is probably due to the fact that the configuration database can
        # only run one change at a time.
        sleep $NODE_GROUP
    done
}

# We'll stop the data node by deactivating it insetad of shutting it down
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

# Start ndbmtd in the background and log to stdout
ndbmtd --nodaemon --ndb-nodeid=$NODE_ID $INITIAL_START --ndb-connectstring=$MGM_CONNECTION_STRING &
main_pid=$!
wait $main_pid
exit $?
