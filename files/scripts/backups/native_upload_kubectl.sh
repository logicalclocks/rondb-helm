#!/bin/bash

# Copyright (c) 2024-2025 Hopsworks AB. All rights reserved.

set -e

mkdir -p logs

wait_pids=()
NUM_NODE_GROUPS={{ .Values.clusterSize.numNodeGroups }}
NUM_REPLICAS={{ .Values.clusterSize.activeDataReplicas }}

{{ include "rondb.backups.defineBackupIdEnv" $ }}
SOURCE_DIR=/home/hopsworks/data/ndb/backups/BACKUP/BACKUP-$BACKUP_ID
REMOTE_BACKUP_DIR={{ include "rondb.rcloneBackupRemoteName" . }}:{{ include "rondb.backups.bucketName" (dict "backupConfig" .Values.backups "global" .Values.global) }}/{{ include "rondb.takeBackupPathPrefix" . }}/$BACKUP_ID

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

{{ $configMap := include "rondb.backups.metadataStore.configMapName" . }}
{{- if $configMap }}

MAX_KEYS=5000
MAX_SIZE_BYTES=900000
BASE_CONFIGMAP={{ $configMap }}

get_active_configmap(){
    kubectl get cm -n {{ .Release.Namespace }} -l "app=backups-metadata,service=rondb,managed-by=cronjob,active=active" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

log_stderr(){
    echo "$*" >&2
}

create_configmap_if_missing() {
  local name="$1"
  if ! kubectl get configmap "$name" -n {{ .Release.Namespace }} >/dev/null 2>&1; then
    log_stderr "Creating ConfigMap $name"
    kubectl create configmap "$name" -n {{ .Release.Namespace }} >/dev/null 2>&1
    kubectl label configmap "$name" -n {{ .Release.Namespace }} app=backups-metadata service=rondb managed-by=cronjob active=active --overwrite >/dev/null 2>&1
  fi
}

rotate_if_needed() {
  local cm="$1"

  local key_count size_bytes
  key_count=$(kubectl get configmap "$cm" -n {{ .Release.Namespace }} -o json | jq '.data | length')
  size_bytes=$(kubectl get configmap "$cm" -n {{ .Release.Namespace }} -o json | jq -r '.' | wc -c)

  log_stderr "ConfigMap: $cm | Keys=$key_count | Size=${size_bytes}B"

  if (( key_count >= MAX_KEYS )) || (( size_bytes >= MAX_SIZE_BYTES )); then
    log_stderr "Threshold exceeded, rotating ConfigMap..."
    local suffix next_suffix new_cm
    suffix="${cm#$BASE_CONFIGMAP-}"
    if [[ "$suffix" =~ ^[0-9]+$ ]]; then
      next_suffix=$((suffix + 1))
    else
      next_suffix=1
    fi
    new_cm="${BASE_CONFIGMAP}-${next_suffix}"

    # Create and label the new ConfigMap
    create_configmap_if_missing "$new_cm"

    # Remove active label from old configmap
    kubectl label configmap "$cm" -n {{ .Release.Namespace }} active- --overwrite >/dev/null 2>&1  || true

    log_stderr "Rotated to new ConfigMap: $new_cm"
    echo "$new_cm"
  else
    echo "$cm"
  fi
}

ACTIVE_CM=$(get_active_configmap)
if [[ -z "$ACTIVE_CM" ]]; then
  ACTIVE_CM="$BASE_CONFIGMAP"
  echo "No active ConfigMap found. Creating $ACTIVE_CM ..."
  create_configmap_if_missing "$ACTIVE_CM"
fi

ACTIVE_CM=$(rotate_if_needed "$ACTIVE_CM")

# Build backup metadata info json
echo "Updating backup metadata on ConfigMap $ACTIVE_CM "
START_TS=$(stat -c %Y {{ include "rondb.backups.backupIdFile" . }} | awk '{printf "%.3f", $1}')
END_TS=$(date +%s.%3N)

DURATION_MS=$(awk -v start="$START_TS" -v end="$END_TS" 'BEGIN { printf "%.0f", (end - start) * 1000 }')

START_TIME=$(date -u -d @"${START_TS%.*}" +"%Y-%m-%dT%H:%M:%S").$(printf "%03d" "${START_TS#*.}")Z
END_TIME=$(date -u -d @"${END_TS%.*}" +"%Y-%m-%dT%H:%M:%S").$(printf "%03d" "${END_TS#*.}")Z

STATE="SUCCESS"

PATCH_JSON=$(cat <<EOF
{
  "data": {
    "$BACKUP_ID": "{\"start_time\":\"$START_TIME\",\"end_time\":\"$END_TIME\",\"duration_ms\":$DURATION_MS,\"state\":\"$STATE\",\"path\":\"{{ include "rondb.backups.pathScheme" . }}/{{ include "rondb.backups.bucketName" (dict "backupConfig" .Values.backups "global" .Values.global) }}/{{ include "rondb.takeBackupPathPrefix" . }}/$BACKUP_ID\"}"
  }
}
EOF
)

kubectl patch configmap "$ACTIVE_CM" -n {{ .Release.Namespace }} --type merge -p "$PATCH_JSON"
{{- end }}