#!/bin/bash

# Copyright (c) 2024-2025 Hopsworks AB. All rights reserved.

set -e

mkdir -p logs

wait_pids=()
NUM_NODE_GROUPS={{ .Values.clusterSize.numNodeGroups }}
NUM_REPLICAS={{ .Values.clusterSize.activeDataReplicas }}

{{ include "rondb.backups.defineJobNumberEnv" $ }}
SOURCE_DIR=/home/hopsworks/data/ndb/backups/BACKUP/BACKUP-$JOB_NUMBER
REMOTE_BACKUP_DIR={{ include "rondb.rcloneBackupRemoteName" . }}:{{ .Values.backups.s3.bucketName }}/{{ include "rondb.takeBackupPathPrefix" . }}/$JOB_NUMBER

echo "Uploading backups from '$SOURCE_DIR' to object storage $REMOTE_BACKUP_DIR in parallel"
for ((g = 0; g < NUM_NODE_GROUPS; g++)); do
    for ((r = 0; r < NUM_REPLICAS; r++)); do
        DATANODE_PODNAME="node-group-$g-$r"

        # target: sink/<backup-id>/rondb/<node-id>
        NODE_ID_OFFSET=$(($g*3))
        NODE_ID=$(($NODE_ID_OFFSET+$r+1))
        REMOTE_DIR=$REMOTE_BACKUP_DIR/rondb/$NODE_ID
        
        RUN_CMD="echo 'Source dir ($SOURCE_DIR):' \
            && ls -la $SOURCE_DIR \
            && rclone mkdir $REMOTE_DIR \
            && echo 'Remote dir before copying ($REMOTE_DIR):' \
            && rclone ls $REMOTE_DIR \
            && echo \
            && rclone move $SOURCE_DIR $REMOTE_DIR \
            && echo 'Remote dir after copying ($REMOTE_DIR):' \
            && rclone ls $REMOTE_DIR"
        kubectl exec \
            $DATANODE_PODNAME \
            -c rclone-listener \
            -n {{ .Release.Namespace }} \
            -- /bin/bash -c "$RUN_CMD" \
            >logs/$DATANODE_PODNAME.log 2>&1 &
        KUBECTL_PID=$!
        echo "Started backup upload for $DATANODE_PODNAME with PID $KUBECTL_PID"
        wait_pids+=($KUBECTL_PID)
    done
done

set +e
FAILED=false
for pid in "${wait_pids[@]}"; do
    wait "$pid"
    status=$?
    if [ $status -ne 0 ]; then
        echo "Upload-process with PID $pid failed with status $status" && echo
        FAILED=true
        continue
    fi
    echo "Upload-process with PID $pid succeeded"
done

# Printing logs in any case
echo "Backup upload logs:" && echo "---"
for file in logs/*; do
    echo "File: $file"
    cat "$file"
    echo "---"
done

# We won't be able to run a job with the same ID again, so we're better
# off *always* deleting the backup.
echo "Removing source backup directories"
for ((g = 0; g < NUM_NODE_GROUPS; g++)); do
    for ((r = 0; r < NUM_REPLICAS; r++)); do
        DATANODE_PODNAME="node-group-$g-$r"
        kubectl exec \
            $DATANODE_PODNAME \
            -c rclone-listener \
            -n {{ .Release.Namespace }} \
            -- /bin/bash -c "echo 'Removing source backup dir $SOURCE_DIR in pod $DATANODE_PODNAME' && rm -r $SOURCE_DIR"
    done
done
echo ">>> Succeeded cleaning up all backups"

if [ "$FAILED" = true ]; then
    echo "Some backup uploads failed"
    exit 1
fi
echo ">>> Succeeded uploading all backups"
