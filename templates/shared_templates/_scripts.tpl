{{- define "rondb.nodeId" -}}
# Equivalent to replication factor of pod
POD_ID=$(echo $POD_NAME | grep -o '[0-9]\+$')
NODE_ID_OFFSET=$(($NODE_GROUP*3))
NODE_ID=$(($NODE_ID_OFFSET+$POD_ID+1))
{{- end -}}

{{- define "rondb.createRcloneConfig" -}}
echo "Location of rclone config file:"
rclone config file

echo "Templating file $RCLONE_MOUNT_FILEPATH to $RCLONE_CONFIG"
cp $RCLONE_MOUNT_FILEPATH $RCLONE_CONFIG

# Helper function to escape special characters in the variable
escape_sed() {
    echo "$1" | sed -e 's/[\/&]/\\&/g'
}

{{- if eq $.Values.restoreFromBackup.objectStorageProvider "s3" }}
# Escape the variables
ESCAPED_ACCESS_KEY_ID=$(escape_sed "$ACCESS_KEY_ID")
ESCAPED_SECRET_ACCESS_KEY=$(escape_sed "$SECRET_ACCESS_KEY")

if [[ -z "$ACCESS_KEY_ID" ]]; then
    # Use IAM Role instead
    sed -i '/access_key_id/d' "$RCLONE_CONFIG"
    sed -i '/secret_access_key/d' "$RCLONE_CONFIG"
    sed -i 's/env_auth.*/env_auth = true/g' "$RCLONE_CONFIG"
else
    sed -i "s|REG_ACCESS_KEY_ID|$ESCAPED_ACCESS_KEY_ID|g" "$RCLONE_CONFIG"
    sed -i "s|REG_SECRET_ACCESS_KEY|$ESCAPED_SECRET_ACCESS_KEY|g" "$RCLONE_CONFIG"
fi
{{- end }}
{{- end }}

{{- define "rondb.mapNewNodesToBackedUpNodes" -}}
{{ include "rondb.createRcloneConfig" $ }}

{{- if eq $.Values.restoreFromBackup.objectStorageProvider "s3" }}
REMOTE_NATIVE_BACKUP_DIR={{ include "rondb.rcloneRestoreRemoteName" . }}:{{ $.Values.restoreFromBackup.s3.bucketName }}/{{ include "rondb.restoreBackupPathPrefix" . }}/$BACKUP_ID/rondb
echo "Path of remote (native) backup: $REMOTE_NATIVE_BACKUP_DIR"
{{- end }}

DIRECTORY_NAMES=$(rclone lsd $REMOTE_NATIVE_BACKUP_DIR | awk '{print $NF}')
OLD_NODE_IDS=($DIRECTORY_NAMES)
echo "Old node IDs: ${OLD_NODE_IDS[@]}"

{{ $activeNodeIds := list }}
{{- range $nodeGroup := until ($.Values.clusterSize.numNodeGroups | int) -}}
    {{- range $replica := until 3 -}}
        {{- if ge $replica ($.Values.clusterSize.activeDataReplicas | int) -}}
            {{- continue -}}
        {{- end -}}
        {{- $offset := ( mul $nodeGroup 3) -}}
        {{- $nodeId := ( add $offset (add $replica 1)) -}}
        {{ $activeNodeIds = append $activeNodeIds $nodeId }}
    {{- end -}}
{{- end -}}
# These are only the currently active node IDs
NEW_NODE_IDS=({{ range $i, $e := $activeNodeIds }}{{ if $i }} {{ end }}{{ $e }}{{ end }})
echo "Currently active data node IDs: ${NEW_NODE_IDS[@]}"

# Map old node IDs to new node IDs
declare -A MAP_NODE_IDS
for NEW_NODE_ID in "${NEW_NODE_IDS[@]}"; do
    MAP_NODE_IDS[$NEW_NODE_ID]=""
done

# Distribute OLD_NODE_IDS among NEW_NODE_IDS
NUM_NEW_NODES=${#NEW_NODE_IDS[@]}
for IDX_OLD_NODE_ID in "${!OLD_NODE_IDS[@]}"; do
    OLD_NODE_ID=${OLD_NODE_IDS[$IDX_OLD_NODE_ID]}
    IDX_NEW_NODE=$((IDX_OLD_NODE_ID % $NUM_NEW_NODES))
    RESPONSIBLE_NODE_ID=${NEW_NODE_IDS[$IDX_NEW_NODE]}
    MAP_NODE_IDS[$RESPONSIBLE_NODE_ID]+="$OLD_NODE_ID "
done

# Print the result
for NEW_NODE_ID in "${!MAP_NODE_IDS[@]}"; do
    echo "New node ID '$NEW_NODE_ID' is restoring these old node IDs: ${MAP_NODE_IDS[$NEW_NODE_ID]}"
done
{{- end }}

{{/*
    Under load the DNS might not resolve to the correct IP immediately.
    Then a MySQLd or RDRS might be allocated to an empty API slot instead
    of one that it should be assigned to. In case of a data node, the data
    node might unnecessarily restart due to this.
*/}}
{{ define "rondb.resolveOwnIp" -}}
echo "Making sure Pod's FQDN resolves to the correct IP"

# Get the Pod's current IP
POD_FQDN=$(hostname -f)
POD_IP=$(hostname -i)
echo "Pod's FQDN: $POD_FQDN"
echo "Pod's IP: $POD_IP"

# Wait until the FQDN resolves to the Pod's IP
while true; do
  result=$(nslookup $POD_FQDN)
  echo "$result"
  RESOLVED_IP=$(echo "$result" | awk '/^Address: / { print $2 }' | head -n 1)
  if [ "$RESOLVED_IP" = "$POD_IP" ]; then
    echo "The Pod's resolved FQDN and its IP address match."
    break
  else
    echo "Mismatch in IP addresses. DNS resolution incorrect."
    sleep 1
  fi
done
{{- end }}
