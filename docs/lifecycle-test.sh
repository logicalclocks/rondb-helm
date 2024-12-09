cat << 'EOF' > /dev/null
This runs a test suite with the following steps:
1. [Test: generate data] Setup cluster A, generate data
2. [Test: replicate from scratch] Setup cluster B, replicate A->B, verify data
3. Shut down cluster A
4. [Test: create backup] Create backup B from cluster B
5. [Test: restore backup] Setup cluster C, restore backup B, verify data
6. [Test: replicate from primary's backup] Replicate B->C
7. Shut down cluster B
8. Setup cluster D, restore B
9. [Test: replicate from 3rd party backup] Replicate C->D, verify data
EOF

set -e

CLUSTER_A_NAME=cluster-a
CLUSTER_B_NAME=cluster-b
CLUSTER_C_NAME=cluster-c
CLUSTER_D_NAME=cluster-d

namespaces=($CLUSTER_A_NAME $CLUSTER_B_NAME $CLUSTER_C_NAME $CLUSTER_D_NAME)
for namespace in ${namespaces[@]}; do
    kubectl create namespace $namespace
done

CLUSTER_NUMBER_A=1
CLUSTER_NUMBER_B=2
CLUSTER_NUMBER_C=3
CLUSTER_NUMBER_D=4

NUM_BINLOG_SERVERS=2
MAX_NUM_BINLOG_SERVERS=$((NUM_BINLOG_SERVERS+1))
BINLOG_SERVER_STATEFUL_SET=mysqld-binlog-servers
BINLOG_SERVER_HEADLESS=headless-binlog-servers

MYSQL_SECRET_NAME="mysql-passwords"

# TODO: Test this function
function getBinlogHostsString() {
    local namespace=$1
    local BINLOG_HOSTS=()
    for (( i=0; i<NUM_BINLOG_SERVERS; i++ )); do
        BINLOG_SERVER_HOST="${BINLOG_SERVER_STATEFUL_SET}-$i.${BINLOG_SERVER_HEADLESS}.${namespace}.svc.cluster.local"
        BINLOG_HOSTS+=("$BINLOG_SERVER_HOST")
    done
    return (IFS=,; echo "${BINLOG_HOSTS[*]}")
}

#########################
# [Test: generate data] #
#########################

helm upgrade -i $CLUSTER_A_NAME \
    --namespace=$CLUSTER_A_NAME . \
    --values values/minikube/mini.yaml \
    --set "clusterSize.minNumRdrs=0" \
    --set "priorityClass=$CLUSTER_A_NAME" \
    --set "mysql.credentialsSecretName=$MYSQL_SECRET_NAME" \
    --set "mysql.supplyOwnSecret=false" \
    --set "globalReplication.clusterNumber=$CLUSTER_NUMBER_A" \
    --set "globalReplication.primary.enabled=true" \
    --set "globalReplication.primary.numBinlogServers=$NUM_BINLOG_SERVERS" \
    --set "globalReplication.primary.maxNumBinlogServers=$MAX_NUM_BINLOG_SERVERS" \
    --set "meta.binlogServers.statefulSet.name=$BINLOG_SERVER_STATEFUL_SET" \
    --set "meta.binlogServers.headlessClusterIp.name=$BINLOG_SERVER_HEADLESS"

helm test -n $CLUSTER_A_NAME $CLUSTER_A_NAME --logs --filter name=generate-data

# Copy Secret into every namespace
for namespace in ${namespaces[@]}; do
    kubectl get secret $MYSQL_SECRET_NAME --namespace=$CLUSTER_A_NAME -o yaml |
        sed '/namespace/d; /creationTimestamp/d; /resourceVersion/d; /uid/d' | 
        kubectl apply --namespace=$namespace -f -
done

##################################
# [Test: replicate from scratch] #
##################################

BINLOG_HOSTS_A=$(getBinlogHostsString $CLUSTER_A_NAME)

# This will first be a secondary but then turn into a primary, hence we're
# already activating the binlog servers.

helm upgrade -i $CLUSTER_B_NAME \
    --namespace=$CLUSTER_B_NAME . \
    --values values/minikube/mini.yaml \
    --set "clusterSize.minNumRdrs=0" \
    --set "backups.enabled=true" \
    --set "priorityClass=$CLUSTER_B_NAME" \
    --set "mysql.credentialsSecretName=$MYSQL_SECRET_NAME" \
    --set "mysql.supplyOwnSecret=true" \
    --set "globalReplication.clusterNumber=$CLUSTER_NUMBER_B" \
    --set "globalReplication.primary.enabled=true" \
    --set "globalReplication.primary.numBinlogServers=$NUM_BINLOG_SERVERS" \
    --set "globalReplication.primary.maxNumBinlogServers=$MAX_NUM_BINLOG_SERVERS" \
    --set "meta.binlogServers.statefulSet.name=$BINLOG_SERVER_STATEFUL_SET" \
    --set "meta.binlogServers.headlessClusterIp.name=$BINLOG_SERVER_HEADLESS" \
    --set "globalReplication.secondary.enabled=true" \
    --set "globalReplication.secondary.replicateFrom.clusterNumber=$CLUSTER_NUMBER_A" \
    --set "globalReplication.secondary.replicateFrom.binlogServerHosts={$BINLOG_HOSTS_A}"

# Check that data has been created correctly
helm test -n $CLUSTER_B_NAME $CLUSTER_B_NAME --logs --filter name=verify-data

helm delete $CLUSTER_A_NAME --namespace=$CLUSTER_A_NAME

#########################
# [Test: create backup] #
#########################

# TODO: Create backup in $CLUSTER_B_NAME

# TODO: Get backup ID
BACKUP_B_ID=42

##########################
# [Test: restore backup] #
##########################

# First just restore backup and validate data
# Prepare replica appliers, but don't start them

helm upgrade -i $CLUSTER_C_NAME \
    --namespace=$CLUSTER_C_NAME . \
    --values values/minikube/mini.yaml \
    --set "clusterSize.minNumRdrs=0" \
    --set "restoreFromBackup.backupId=$BACKUP_B_ID" \
    --set "priorityClass=$CLUSTER_C_NAME" \
    --set "mysql.credentialsSecretName=$MYSQL_SECRET_NAME" \
    --set "mysql.supplyOwnSecret=true" \
    --set "globalReplication.clusterNumber=$CLUSTER_NUMBER_C"

helm test -n $CLUSTER_C_NAME $CLUSTER_C_NAME --logs --filter name=verify-data

###########################################
# [Test: replicate from primary's backup] #
###########################################

# Now also start replicating

BINLOG_HOSTS_B=$(getBinlogHostsString $CLUSTER_B_NAME)

helm upgrade -i $CLUSTER_C_NAME \
    --namespace=$CLUSTER_C_NAME . \
    --values values/minikube/mini.yaml \
    --set "clusterSize.minNumRdrs=0" \
    --set "restoreFromBackup.backupId=$BACKUP_B_ID" \
    --set "priorityClass=$CLUSTER_C_NAME" \
    --set "mysql.credentialsSecretName=$MYSQL_SECRET_NAME" \
    --set "mysql.supplyOwnSecret=true" \
    --set "globalReplication.clusterNumber=$CLUSTER_NUMBER_C" \
    --set "globalReplication.secondary.enabled=true" \
    --set "globalReplication.secondary.replicateFrom.clusterNumber=$CLUSTER_NUMBER_B" \
    --set "globalReplication.secondary.replicateFrom.binlogServerHosts={$BINLOG_HOSTS_B}"

helm delete $CLUSTER_B_NAME --namespace=$CLUSTER_B_NAME

###########################################
# [Test: replicate from 3rd party backup] #
###########################################

# The epoch from the backup is unrelated to the cluster we are replicating from

BINLOG_HOSTS_C=$(getBinlogHostsString $CLUSTER_C_NAME)

helm upgrade -i $CLUSTER_D_NAME \
    --namespace=$CLUSTER_D_NAME . \
    --values values/minikube/mini.yaml \
    --set "clusterSize.minNumRdrs=0" \
    --set "restoreFromBackup.backupId=$BACKUP_B_ID" \
    --set "priorityClass=$CLUSTER_D_NAME" \
    --set "mysql.credentialsSecretName=$MYSQL_SECRET_NAME" \
    --set "mysql.supplyOwnSecret=true" \
    --set "globalReplication.clusterNumber=$CLUSTER_NUMBER_D" \
    --set "globalReplication.secondary.enabled=true" \
    --set "globalReplication.secondary.replicateFrom.clusterNumber=$CLUSTER_NUMBER_C" \
    --set "globalReplication.secondary.replicateFrom.binlogServerHosts={$BINLOG_HOSTS_C}"

helm delete $CLUSTER_C_NAME --namespace=$CLUSTER_C_NAME
helm delete $CLUSTER_D_NAME --namespace=$CLUSTER_D_NAME

# Delete all namespaces
for namespace in ${namespaces[@]}; do
    kubectl delete namespace $namespace
done
