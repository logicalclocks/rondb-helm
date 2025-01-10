#!/bin/bash

# Copyright (c) 2024-2025 Hopsworks AB. All rights reserved.

set -e

{{ include "rondb.nodeId" $ }}

# This is the first file that is read by the ndbmtd
FIRST_FILE_READ=$FILE_SYSTEM_PATH/ndb_${NODE_ID}_fs/D1/DBDIH/P0.sysfile
if [ -f "$FIRST_FILE_READ" ]; then
    echo "The data node has started before, no need to download a backup"
    exit 0
fi

{{ include "rondb.mapNewNodesToBackedUpNodes" . }}

BACKUP_NODE_IDS=${MAP_NODE_IDS[$NODE_ID]}
echo "This node (node ID '$NODE_ID') is restoring these old node IDs: $BACKUP_NODE_IDS"

LOCAL_BACKUP_DIR=/home/hopsworks/data/ndb/backups/BACKUP/BACKUP-$BACKUP_ID
for BACKUP_NODE_ID in $BACKUP_NODE_IDS; do
    set +x
    LOCAL_DIR=$LOCAL_BACKUP_DIR/$BACKUP_NODE_ID
    mkdir -p "$LOCAL_DIR"
    
    REMOTE_DIR=$REMOTE_NATIVE_BACKUP_DIR/$BACKUP_NODE_ID

    set -x
    rclone ls "$REMOTE_DIR"
    rclone copy "$REMOTE_DIR" "$LOCAL_DIR"
done

if [[ -d $LOCAL_BACKUP_DIR ]]; then
    echo "Successfully copied over all relevant native backups"
    ls -la $LOCAL_BACKUP_DIR
else
    echo "No native backup has been downloaded by this node"
fi

