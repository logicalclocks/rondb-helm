#!/bin/bash

# Copyright (c) 2024-2024 Hopsworks AB. All rights reserved.

set -e

function mysqlLocal() {
    command mysql --defaults-file=$RONDB_DATA_DIR/my.cnf --protocol=tcp -hlocalhost "$@"
}

source get_binlog_position.sh

# Get the hostname of the target binlog server
BINLOG_SERVER_HOSTNAMES=(
    {{- range .Values.globalReplication.secondary.replicateFrom.binlogServerHosts }}
        {{ . | quote }}
    {{- end }}
)

echo "Available binlog server hostnames: ${BINLOG_SERVER_HOSTNAMES[*]}"

SOURCE_PORT=3306
{{- $maxTotalMySQLds := (include "rondb.maxTotalMySQLds" $ | int) }}
{{- $serverIdOffset := mul .Values.globalReplication.clusterNumber $maxTotalMySQLds -}}
{{- $ownServerIds := list -}}
{{ range $i := until $maxTotalMySQLds -}}
    {{- $ownServerIds = append $ownServerIds (add $serverIdOffset $i) -}}
{{- end }}
# Only entirely necessary during active-active replication
IGNORE_SERVER_IDS={{ join "," $ownServerIds }}

# Binlog file and position must always be passed since they will
# be different across binlog servers
function runReplication() {
    local SOURCE_HOST=$1
    local BINLOG_FILE=$2
    local BINLOG_POSITION=$3

    echo "Starting the replication channel towards ${SOURCE_HOST} from ${BINLOG_FILE}:${BINLOG_POSITION}"

    mysqlLocal -e "STOP REPLICA;"
    mysqlLocal -e "RESET REPLICA;"
    mysqlLocal <<EOF
CHANGE REPLICATION SOURCE TO
    -- Hostname of source MySQL Server
    SOURCE_HOST="${SOURCE_HOST}",
    -- Port number of the source MySQL Server
    SOURCE_PORT=${SOURCE_PORT},
    -- Username that the replica will use on the source MySQL Server
    SOURCE_USER="${MYSQL_CLUSTER_USER}",
    -- Password of this user on the source MySQL Server
    SOURCE_PASSWORD="${MYSQL_CLUSTER_PASSWORD}",
    -- The starting binlog file on the source MySQL Server
    SOURCE_LOG_FILE="${BINLOG_FILE}",
    -- The starting position on the source MySQL Server
    SOURCE_LOG_POS=${BINLOG_POSITION},
{{- if $.Values.globalReplication.secondary.replicateFrom.useTlsConnection }}
    -- WARNING: This is needed if the binlog servers enforce SSL
    SOURCE_SSL=1,
{{- end }}

    -- Ignore replication from server IDs in backup cluster to avoid circular replication
    IGNORE_SERVER_IDS=(${IGNORE_SERVER_IDS});
EOF
    mysqlLocal -e "START REPLICA;"
}

# Return 1 or 0 whether the binlog server worked at least once
function tryBinlogServer() {
    local TARGET_BINLOG_SERVER=$1
    local WORKED_ONCE="false"

    echo "#######" && echo "Checking binlog server: $TARGET_BINLOG_SERVER"

    result_file=$(mktemp)
    if ! getBinlogPosition $TARGET_BINLOG_SERVER $result_file; then
        return 1
    fi
    BINLOG_FILE=$(sed -n '1p' $result_file)
    BINLOG_POSITION=$(sed -n '2p' $result_file)

    # We have to try replication first to know whether the binlog file
    # contains issues such as LOST_EVENTS
    runReplication $TARGET_BINLOG_SERVER $BINLOG_FILE $BINLOG_POSITION
    sleep 2

    MAX_RETRIES=5
    NOT_ACTIVE_COUNTER=0
    while true; do
        set +e
        get_replication_status.sh >/dev/null
        local exit_code=$?
        set -e
        if [[ $exit_code -eq 0 ]]; then
            NOT_ACTIVE_COUNTER=0
            WORKED_ONCE="true"
        else
            NOT_ACTIVE_COUNTER=$((NOT_ACTIVE_COUNTER + 1))
            if [[ $NOT_ACTIVE_COUNTER -gt $MAX_RETRIES ]]; then
                echo "Giving up replication from binlog server: $TARGET_BINLOG_SERVER" >&2
                if [[ "$WORKED_ONCE" == "true" ]]; then
                    return 0
                fi
                return 1
            fi
        fi
        sleep 5
    done
}

MAX_TOTAL_ATTEMPTS=3
CURRENT_ATTEMPT=0
while true; do
    CURRENT_ATTEMPT=$((CURRENT_ATTEMPT + 1))
    echo "Starting replica applier attempt: $CURRENT_ATTEMPT/$MAX_TOTAL_ATTEMPTS"
    for TARGET_BINLOG_SERVER in "${BINLOG_SERVER_HOSTNAMES[@]}"; do
        if tryBinlogServer $TARGET_BINLOG_SERVER; then
            CURRENT_ATTEMPT=0
        else
            echo "Replication never worked (very long) from binlog server $TARGET_BINLOG_SERVER" >&2
        fi
        sleep 0 # Flush stdout & stderr
    done
    if [[ $CURRENT_ATTEMPT -ge $MAX_TOTAL_ATTEMPTS ]]; then
        echo "Giving up replication from this replica applier" >&2
        echo "#######" && echo "BYE BYE" && echo "#######"
        exit 1
    fi
    sleep 2
done
