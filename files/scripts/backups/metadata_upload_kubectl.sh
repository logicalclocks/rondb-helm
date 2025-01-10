#!/bin/bash

# Copyright (c) 2024-2025 Hopsworks AB. All rights reserved.

# Running this on the MySQLd to have root MySQL access; we need permissions
# for everything we want to back up. Root cannot be used over the network.
set -e

{{ include "rondb.createRcloneConfig" . }}

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

{{ include "rondb.backups.defineJobNumberEnv" $ }}
REMOTE_BACKUP_DIR={{ include "rondb.rcloneBackupRemoteName" . }}:{{ .Values.backups.s3.bucketName }}/{{ include "rondb.takeBackupPathPrefix" . }}/$JOB_NUMBER
echo && rclone mkdir $REMOTE_BACKUP_DIR
echo && rclone ls $REMOTE_BACKUP_DIR
echo "Copying backup from $LOCAL_BACKUP_DIR to $REMOTE_BACKUP_DIR"
rclone move $LOCAL_BACKUP_DIR $REMOTE_BACKUP_DIR
rclone ls $REMOTE_BACKUP_DIR
