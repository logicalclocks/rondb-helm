#!/bin/bash

# Copyright (c) 2024-2025 Hopsworks AB. All rights reserved.

# Running this on the MySQLd to have root MySQL access; we need permissions
# for everything we want to back up. Root cannot be used over the network.
set -e

kubectl exec \
    $MYSQLD_PODNAME \
    -c mysqld \
    -n {{ .Release.Namespace }} \
    -- /bin/bash -c "{{ include "rondb.dataDir" $ }}/metadata_create.sh $REMOTE_BACKUP_DIR"

# Not running rclone on a MySQLd sidecar because it would require creating an
# additional shared volume on the MySQLd pod.
echo "Copying metadata backup from $MYSQLD_PODNAME to $LOCAL_BACKUP_DIR"
mkdir -p $LOCAL_BACKUP_DIR
kubectl cp \
    {{ .Release.Namespace }}/$MYSQLD_PODNAME:$REMOTE_BACKUP_DIR \
    -c mysqld $LOCAL_BACKUP_DIR
ls -la $LOCAL_BACKUP_DIR

{{ include "rondb.backups.defineBackupIdEnv" $ }}
REMOTE_BACKUP_DIR={{ include "rondb.rcloneBackupRemoteName" . }}:{{include "rondb.backups.bucketName" (dict "backupConfig" .Values.backups "global" .Values.global)}}/{{ include "rondb.takeBackupPathPrefix" . }}/$BACKUP_ID

if rclone lsf "$REMOTE_BACKUP_DIR" 2>/dev/null | grep -q .; then
    echo "Remote backup direcotry $REMOTE_BACKUP_DIR exists and contains files — exiting."
    rclone ls "$REMOTE_BACKUP_DIR"
    exit 1
fi

echo "Copying backup from $LOCAL_BACKUP_DIR to $REMOTE_BACKUP_DIR"
rclone move $LOCAL_BACKUP_DIR $REMOTE_BACKUP_DIR
rclone ls $REMOTE_BACKUP_DIR
