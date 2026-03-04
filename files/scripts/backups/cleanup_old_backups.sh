#!/bin/bash

# Copyright (c) 2024-2026 Hopsworks AB. All rights reserved.



set -e

{{- include "rondb.backups.defineBackupIdEnv" . }}

REMOTE_BACKUP_BASE_DIR={{ include "rondb.rcloneBackupRemoteName" . }}:{{ include "rondb.backups.bucketName" (dict "backupConfig" .Values.backups "global" .Values.global) }}/{{ include "rondb.takeBackupPathPrefix" . }}

if [ -z "$TTL" ]; then
  echo "No TTL configuration found."
  exit 0
fi

echo "Check expired backups in $REMOTE_BACKUP_BASE_DIR with TTL $TTL "

# Only check top-level files (databases.sql, users.sql) to determine backup age.
# These are always uploaded first (backup-metadata init container) and are at least
# as old as the nested rondb data files, so their timestamp is a safe TTL indicator.
# This avoids a slow recursive listing of all objects in the bucket.
TTL_EXPIRED=$(
  rclone lsf --recursive --files-only "$REMOTE_BACKUP_BASE_DIR" --min-age "$TTL" --max-depth 2 \
    --include "*/databases.sql" --include "*/users.sql" \
  | cut -d'/' -f1 \
  | sort -u
)

if [ -z "$TTL_EXPIRED" ]; then
  echo "No TTL expired backups found."
  exit 0
fi

echo "TTL expired backups detected:"
echo "$TTL_EXPIRED"

echo "Deleting TTL-expired backups from object storage"

{{- if include "rondb.backups.metadataStore.configMapName" . }}
CONFIGMAPS=$(kubectl get cm -n {{ .Release.Namespace }} \
  -l "app=backups-metadata,service=rondb,managed-by=cronjob" \
  -o jsonpath='{.items[*].metadata.name}')
{{- end }}

for id in $TTL_EXPIRED; do
  if [ "$id" = "$BACKUP_ID" ]; then
      echo "Skipping $id since this is the last active backup"
      continue
  fi
  BACKUP_PATH="$REMOTE_BACKUP_BASE_DIR/$id"
  echo "Deleting $BACKUP_PATH"
  rclone delete -v "$BACKUP_PATH" --rmdirs
  
{{- if include "rondb.backups.metadataStore.configMapName" . }}
  PATCH_JSON="{\"data\": {\"$id\": null}}"
  for cm in $CONFIGMAPS; do
    echo "Cleaning metadata from ConfigMap: $cm with $PATCH_JSON"
    kubectl patch cm "$cm" -n {{ .Release.Namespace }} --type merge -p "$PATCH_JSON" || true
  done
{{- end }}
done
