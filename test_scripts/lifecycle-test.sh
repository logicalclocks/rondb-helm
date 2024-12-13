cat <<'EOF' >/dev/null
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

Essentially: A->B->C->D
EOF

set -e

# We use these both for namespace names and Helm instance names
CLUSTER_A_NAME=$1
CLUSTER_B_NAME=$2
CLUSTER_C_NAME=$3
CLUSTER_D_NAME=$4

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)

# Values files relating to object storage
source $SCRIPT_DIR/minio.env

namespaces=($CLUSTER_A_NAME $CLUSTER_B_NAME $CLUSTER_C_NAME $CLUSTER_D_NAME)
for namespace in ${namespaces[@]}; do
    kubectl delete namespace $namespace || true
    kubectl create namespace $namespace
done

CLUSTER_NUMBER_A=1
CLUSTER_NUMBER_B=2
CLUSTER_NUMBER_C=3
CLUSTER_NUMBER_D=4

# Using only 1 to avoid lack of CPUs
NUM_BINLOG_SERVERS=1
MAX_NUM_BINLOG_SERVERS=$((NUM_BINLOG_SERVERS + 1))
BINLOG_SERVER_STATEFUL_SET=mysqld-binlog-servers
BINLOG_SERVER_HEADLESS=headless-binlog-servers

MYSQL_SECRET_NAME="mysql-passwords"

getBinlogHostsString() {
    local namespace=$1
    local BINLOG_HOSTS=()
    for ((i = 0; i < NUM_BINLOG_SERVERS; i++)); do
        local BINLOG_SERVER_HOST="${BINLOG_SERVER_STATEFUL_SET}-$i.${BINLOG_SERVER_HEADLESS}.${namespace}.svc.cluster.local"
        BINLOG_HOSTS+=("$BINLOG_SERVER_HOST")
    done
    # Output the comma-separated list of hosts
    (
        IFS=,
        echo "${BINLOG_HOSTS[*]}"
    )
}

getBackupId() {
    local namespace=$1
    POD_NAME=$(kubectl get pods -n $namespace --selector=job-name=manual-backup -o jsonpath='{.items[?(@.status.phase=="Succeeded")].metadata.name}' | head -n 1)
    BACKUP_ID=$(kubectl logs $POD_NAME -n $namespace --container=upload-native-backups | grep -o "BACKUP-[0-9]\+" | head -n 1 | awk -F '-' '{print $2}')
    echo $BACKUP_ID
}

# Mostly to check that the replica applier doesn't trip up (the heartbeat will cause further replication)
testStability() {
    timeout 300 env K8S_NAMESPACE=$1 SLEEP_SECONDS=10 MIN_STABLE_MINUTES=1 bash -c .github/test_deploy_stability.sh || {
        echo "Cluster $1 did not stabilize"
        exit 1
    }
}

# This makes sense if the primary cluster will be killed
stopReplicaAppliers() {
    local namespace=$1
    helm upgrade -i $namespace \
        --namespace=$namespace \
        --reuse-values \
        --set "globalReplication.secondary.enabled=false" \
        .
}

deleteCluster() {
    local clusterName=$1
    helm delete $clusterName --namespace=$clusterName
    kubectl delete namespace $clusterName
}

#########################
# [Test: generate data] #
#########################

helm upgrade -i $CLUSTER_A_NAME \
    --namespace=$CLUSTER_A_NAME . \
    --values values/minikube/mini.yaml \
    --values values/end_to_end_tls.yaml \
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

kubectl create secret generic $BUCKET_SECRET_NAME \
    --namespace=$CLUSTER_B_NAME \
    --from-literal "key_id=${MINIO_ACCESS_KEY}" \
    --from-literal "access_key=${MINIO_SECRET_KEY}"

# This will first be a secondary but then turn into a primary, hence we're
# already activating the binlog servers.

helm upgrade -i $CLUSTER_B_NAME \
    --namespace=$CLUSTER_B_NAME . \
    --values values/minikube/mini.yaml \
    --values values/end_to_end_tls.yaml \
    --values $backups_values_file \
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

# Make sure replica appliers are up
testStability $CLUSTER_B_NAME

# Check that data has been created correctly
helm test -n $CLUSTER_B_NAME $CLUSTER_B_NAME --logs --filter name=verify-data

stopReplicaAppliers $CLUSTER_B_NAME
deleteCluster $CLUSTER_A_NAME

#########################
# [Test: create backup] #
#########################

kubectl delete job -n $CLUSTER_B_NAME manual-backup || true
kubectl create job -n $CLUSTER_B_NAME --from=cronjob/create-backup manual-backup
bash .github/wait_job.sh $CLUSTER_B_NAME manual-backup 180
BACKUP_B_ID=$(getBackupId $CLUSTER_B_NAME)
echo "BACKUP_B_ID is ${BACKUP_B_ID}"

##########################
# [Test: restore backup] #
##########################

# First just restore backup and validate data.
# Don't start replica appliers just yet.
# Since we will also be replicating *from* this cluster,
# we already activate the binlog servers. Better now than
# that they miss the first heartbeats from the primary.

kubectl create secret generic $BUCKET_SECRET_NAME \
    --namespace=$CLUSTER_C_NAME \
    --from-literal "key_id=${MINIO_ACCESS_KEY}" \
    --from-literal "access_key=${MINIO_SECRET_KEY}"

helm upgrade -i $CLUSTER_C_NAME \
    --namespace=$CLUSTER_C_NAME . \
    --values values/minikube/mini.yaml \
    --values values/end_to_end_tls.yaml \
    --values $restore_values_file \
    --set "clusterSize.minNumRdrs=0" \
    --set "restoreFromBackup.backupId=$BACKUP_B_ID" \
    --set "priorityClass=$CLUSTER_C_NAME" \
    --set "mysql.credentialsSecretName=$MYSQL_SECRET_NAME" \
    --set "mysql.supplyOwnSecret=true" \
    --set "globalReplication.clusterNumber=$CLUSTER_NUMBER_C" \
    --set "globalReplication.primary.enabled=true" \
    --set "globalReplication.primary.numBinlogServers=$NUM_BINLOG_SERVERS" \
    --set "globalReplication.primary.maxNumBinlogServers=$MAX_NUM_BINLOG_SERVERS" \
    --set "meta.binlogServers.statefulSet.name=$BINLOG_SERVER_STATEFUL_SET" \
    --set "meta.binlogServers.headlessClusterIp.name=$BINLOG_SERVER_HEADLESS" \

helm test -n $CLUSTER_C_NAME $CLUSTER_C_NAME --logs --filter name=verify-data

###########################################
# [Test: replicate from primary's backup] #
###########################################

# Now also start replicating

BINLOG_HOSTS_B=$(getBinlogHostsString $CLUSTER_B_NAME)

helm upgrade -i $CLUSTER_C_NAME \
    --namespace=$CLUSTER_C_NAME . \
    --reuse-values \
    --set "globalReplication.secondary.enabled=true" \
    --set "globalReplication.secondary.replicateFrom.clusterNumber=$CLUSTER_NUMBER_B" \
    --set "globalReplication.secondary.replicateFrom.binlogServerHosts={$BINLOG_HOSTS_B}"

testStability $CLUSTER_C_NAME
stopReplicaAppliers $CLUSTER_C_NAME
deleteCluster $CLUSTER_B_NAME

###########################################
# [Test: replicate from 3rd party backup] #
###########################################

# The epoch from the backup is unrelated to the cluster we are replicating from

BINLOG_HOSTS_C=$(getBinlogHostsString $CLUSTER_C_NAME)

kubectl create secret generic $BUCKET_SECRET_NAME \
    --namespace=$CLUSTER_D_NAME \
    --from-literal "key_id=${MINIO_ACCESS_KEY}" \
    --from-literal "access_key=${MINIO_SECRET_KEY}"

helm upgrade -i $CLUSTER_D_NAME \
    --namespace=$CLUSTER_D_NAME . \
    --values values/minikube/mini.yaml \
    --values values/end_to_end_tls.yaml \
    --values $restore_values_file \
    --set "clusterSize.minNumRdrs=0" \
    --set "restoreFromBackup.backupId=$BACKUP_B_ID" \
    --set "priorityClass=$CLUSTER_D_NAME" \
    --set "mysql.credentialsSecretName=$MYSQL_SECRET_NAME" \
    --set "mysql.supplyOwnSecret=true" \
    --set "globalReplication.clusterNumber=$CLUSTER_NUMBER_D" \
    --set "globalReplication.secondary.enabled=true" \
    --set "globalReplication.secondary.replicateFrom.clusterNumber=$CLUSTER_NUMBER_C" \
    --set "globalReplication.secondary.replicateFrom.binlogServerHosts={$BINLOG_HOSTS_C}"

helm test -n $CLUSTER_D_NAME $CLUSTER_D_NAME --logs --filter name=verify-data

testStability $CLUSTER_D_NAME

deleteCluster $CLUSTER_C_NAME
deleteCluster $CLUSTER_D_NAME

# Sanity check; delete all namespaces again
for namespace in ${namespaces[@]}; do
    kubectl delete namespace $namespace || true
done
