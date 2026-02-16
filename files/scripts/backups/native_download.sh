#!/bin/bash

# Copyright (c) 2024-2026 Hopsworks AB. All rights reserved.



set -e

{{ include "rondb.nodeId" $ }}

{{- if not (include "rondb.restoreFromBackup.isInPlace" $) }}
# Normal restore: skip if data already exists
# This is the first file that is read by the ndbmtd
FIRST_FILE_READ=$FILE_SYSTEM_PATH/ndb_${NODE_ID}_fs/D1/DBDIH/P0.sysfile
if [ -f "$FIRST_FILE_READ" ]; then
    echo "The data node has started before, no need to download a backup"
    exit 0
fi
{{- else }}
# In-place restore: use marker file to track download completion
# (backup dir may be deleted after restore, so we can't rely on its presence)
DOWNLOAD_MARKER=/home/hopsworks/data/backup_downloaded_${BACKUP_ID}
if [ -f "$DOWNLOAD_MARKER" ]; then
    echo "In-place restore: backup already downloaded (marker found), skipping"
    exit 0
fi
echo "In-place restore mode: downloading backup"
{{- end }}

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
{{- if include "rondb.restoreFromBackup.isInPlace" $ }}
    # Mark download as complete for this backup ID
    touch /home/hopsworks/data/backup_downloaded_${BACKUP_ID}
{{- end }}
else
    echo "No native backup has been downloaded by this node"
fi

