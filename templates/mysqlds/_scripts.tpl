{{/*
    This is run everywhere we want fixed node IDs in the config.ini.
    This means everywhere we can expect fixed network IDs:

    - Stateful Set of MySQLds           (starting node ID 67)
    - Stateful Set of binlog servers    (starting node ID 67 + MySQLds)
    - Stateful Set of replica appliers  (starting node ID 67 + MySQLds + binlog servers)

    Hence, we need to know the starting node ID and the number of connections per MySQLd.
*/}}
{{- define "rondb.sedMyCnfFile" -}}
###################
# SED MY.CNF FILE #
###################

STARTING_NODE_ID={{ .startingNodeId | required "startingNodeId is required" }}
CONNECTIONS_PER_MYSQLD={{ .connectionsPerMySQLd | required "connectionsPerMySQLd is required" }}

RAW_MYCNF_FILEPATH=$RONDB_DATA_DIR/my-raw.cnf
MYCNF_FILEPATH=$RONDB_DATA_DIR/my.cnf
cp $RAW_MYCNF_FILEPATH $MYCNF_FILEPATH

# Calculate Node Ids based on Pod name
# Pod name is equivalent to replication factor of pod
{{ include "rondb.define_MYSQLD_NR" . }}
FIRST_NODE_ID=$(($STARTING_NODE_ID + ($MYSQLD_NR * $CONNECTIONS_PER_MYSQLD)))
LAST_NODE_ID=$(($FIRST_NODE_ID + $CONNECTIONS_PER_MYSQLD - 1))
NODES_SEQ=$(seq -s, $FIRST_NODE_ID $LAST_NODE_ID)
echo "[K8s Entrypoint MySQLd] Running MySQLd nr. $MYSQLD_NR with $CONNECTIONS_PER_MYSQLD connections using node ids: $NODES_SEQ"

{{ include "rondb.define_SERVER_ID" . }}
echo "[K8s Entrypoint MySQLd] Running MySQLd with global server ID $SERVER_ID"

# Replace the existing lines in my.cnf
sed -i "/ndb-cluster-connection-pool\s*=/c\ndb-cluster-connection-pool=$CONNECTIONS_PER_MYSQLD" $MYCNF_FILEPATH
sed -i "/ndb-cluster-connection-pool-nodeids/c\ndb-cluster-connection-pool-nodeids=$NODES_SEQ" $MYCNF_FILEPATH
# Note that this is used for liveliness/readiness probes
sed -i "/^[ ]*password[ ]*=/c\password=$MYSQL_CLUSTER_PASSWORD" $MYCNF_FILEPATH
sed -i "/^[ ]*server-id[ ]*=/c\server-id=$SERVER_ID" $MYCNF_FILEPATH
{{- end }}

{{- define "rondb.define_MYSQLD_NR" }}
MYSQLD_NR=$(echo $POD_NAME | grep -o '[0-9]\+$')
{{- end }}

{{- define "rondb.define_SERVER_ID" }}
# Calculate server id for global replication based on Pod name
SERVER_IDS_CSV={{ join "," .globalServerIds | required "globalServerIds is required" | quote }}
IFS=',' read -r -a SERVER_IDS <<< "$SERVER_IDS_CSV"
SERVER_ID=${SERVER_IDS[$MYSQLD_NR]}
{{- end }}

{{- define "rondb.initializeMySQLd" -}}
####################
# CONFIGURE MYSQLD #
####################

CMD=("mysqld" "--defaults-file=$MYCNF_FILEPATH")

echo && echo "[K8s Entrypoint MySQLd] Validating config file" && echo
(
    set -x
    "${CMD[@]}" --validate-config
)

echo && echo "[K8s Entrypoint MySQLd] Initializing MySQLd" && echo
(
    set -x
    "${CMD[@]}" \
        --log-error-verbosity=3 \
        --initialize-insecure \
)

echo && echo "[K8s Entrypoint MySQLd] Successfully initialized MySQLd" && echo
{{- end }}

{{- define "rondb.checkDnsResolvable" -}}
set -e

###############################
# CHECK OUR DNS IS RESOLVABLE #
###############################

{{ include "rondb.define_MYSQLD_NR" . }}

# We need this, otherwise the MGMd will not recognise our IP address
# when we try to connect at startup.
{{- $ownHostname := print
    (.statefulSetName | required "statefulSetName is required")
    "-$MYSQLD_NR."
    (.headlessClusterIpName | required "headlessClusterIpName is required")
    "."
    (.namespace | required "namespace is required")
    ".svc.cluster.local"
}}
OWN_HOSTNAME={{ $ownHostname | quote}}
until nslookup $OWN_HOSTNAME; do
    echo "[K8s Entrypoint MySQLd] Waiting for $OWN_HOSTNAME to be resolvable..."
    sleep $(((RANDOM % 2) + 2))
done

echo "[K8s Entrypoint MySQLd] $OWN_HOSTNAME is resolvable..."
{{- end }}
