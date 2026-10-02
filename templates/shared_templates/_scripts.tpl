{{- define "rondb.nodeId" -}}
# Equivalent to replication factor of pod
POD_ID=$(echo $POD_NAME | grep -o '[0-9]\+$')
NODE_ID_OFFSET=$(($NODE_GROUP*3))
NODE_ID=$(($NODE_ID_OFFSET+$POD_ID+1))
{{- end -}}

{{- define "rondb.mapNewNodesToBackedUpNodes" -}}

REMOTE_NATIVE_BACKUP_DIR={{ include "rondb.rcloneRestoreRemoteName" . }}:{{ include "rondb.backups.bucketName" (dict "backupConfig" $.Values.restoreFromBackup "global" $.Values.global) }}/{{ include "rondb.restoreBackupPathPrefix" . }}/$BACKUP_ID/rondb
echo "Path of remote (native) backup: $REMOTE_NATIVE_BACKUP_DIR"

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
############################################
# CHECK POD'S FQDN IS CORRECTLY RESOLVABLE #
############################################

echo "[K8s Entrypoint] Making sure Pod's FQDN resolves to the correct IP"

# Get the Pod's current IP
POD_FQDN=$(hostname -f)
POD_IP=$(hostname -i)
echo "[K8s Entrypoint] Pod's FQDN: $POD_FQDN"
echo "[K8s Entrypoint] Pod's IP: $POD_IP"

# Wait until the FQDN resolves to the Pod's IP
while true; do
  # Callers include this under differing shell flags; with `set -e` a failing
  # command substitution kills the whole script on the first failed lookup.
  # An until-condition is exempt from errexit, so the lookup retries as
  # intended in every caller.
  until result=$(nslookup "$POD_FQDN" 2>/dev/null); do
    echo "[K8s Entrypoint] FQDN not resolvable yet; retrying"
    sleep 1
  done
  echo "$result"
  RESOLVED_IP=$(echo "$result" | awk '/^Address: / { print $2 }' | head -n 1)
  if [ "$RESOLVED_IP" = "$POD_IP" ]; then
    echo "[K8s Entrypoint] The Pod's resolved FQDN and its IP address match."
    break
  else
    echo "[K8s Entrypoint] Mismatch in IP addresses. DNS resolution incorrect."
    sleep 1
  fi
done
{{- end }}

{{/*
    SIGTERM delivery to daemons run under a bash PID 1 (RONDB-1132).

    bash as PID 1 ignores an untrapped SIGTERM, and defers a trapped one
    until the current foreground command returns. The entrypoints ran their
    daemon as a foreground `daemon | tee` pipeline, so the kubelet's SIGTERM
    never reached it and every planned pod stop ended in a SIGKILL when the
    grace period expired. For a data node that leaves a silent node with
    open sockets, which stalls the cluster until heartbeat detection.

    Scope: the daemons the chart runs this way - ndb_mgmd, mysqld, rdrs2,
    run_applier.sh, and ndbmtd (ndbmtds.sh keeps its own trap, the managed
    stop, and uses rondb.runDaemonAndWait only). Init containers and Jobs are
    deliberately NOT covered: a deleted pod waiting out its grace period
    there is a delay, not an outage.

    rondb.sigtermTrap is the entrypoint's first statement: it forwards
    SIGTERM to the daemon once it runs and exits before that. The daemons
    themselves shut down cleanly on SIGTERM.
    rondb.runDaemonAndWait (dict "cmd" <command> "log" <file, optional>)
    starts the daemon in the background, through tee when a log file is
    given (RONDB-982's log capture), waits for it and exits with its status.
    Contract between the two: the trap sets TRAPPED=1 and signals DAEMON_PID.
*/}}
{{ define "rondb.sigtermTrap" -}}
# Forward SIGTERM to the daemon, or exit while it is not running yet; see
# rondb.sigtermTrap in _scripts.tpl. The job-table lookup covers a signal
# landing between the daemon's launch and the DAEMON_PID assignment.
DAEMON_PID=""
TRAPPED=0
trap 'TRAPPED=1; DAEMON_PID=${DAEMON_PID:-$(jobs -p %+ 2>/dev/null || true)}; if [ -n "$DAEMON_PID" ]; then kill -TERM "$DAEMON_PID" 2>/dev/null || true; else echo "SIGTERM during startup; exiting"; exit 0; fi' TERM
{{- end }}

{{ define "rondb.runDaemonAndWait" -}}
# Background launch + interruptible wait; see rondb.runDaemonAndWait in
# _scripts.tpl.
{{ .cmd }}{{ if .log }} 2>&1 | tee -a -- "{{ .log }}"{{ end }} &
DAEMON_PID=${DAEMON_PID:-$(jobs -p %+)}    # the pipeline's first process
# Waiting on the daemon's pid waits for its whole pipeline (tee has written
# the last lines when it returns) and reports the pipeline's status, which
# is the daemon's only under pipefail.
set -o pipefail
# A wait interrupted by the trap returns 143 without collecting the daemon's
# exit status, so wait again whenever the trap fired: bash keeps the status
# of a daemon that exited while the trap ran. A daemon that itself died of
# a signal also reports >128; its second wait returns the same saved status
# and the loop ends.
RC=0
while :; do
    TRAPPED=0
    if wait "$DAEMON_PID" 2>/dev/null; then RC=0; else RC=$?; fi
    if [ "$TRAPPED" = 0 ] || [ "$RC" -le 128 ]; then break; fi
done
exit "$RC"
{{- end }}
