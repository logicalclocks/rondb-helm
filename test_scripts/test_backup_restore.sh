#!/bin/bash

# This is a script to test the backup and restore functionality.
# It is not actually being used by the CI/CD pipeline, but can be run manually.
# The CI runs similar code, but is more elaborate (e.g benchmarking, etc).
# This expects the MinIO operator to be installed in the cluster.

set -e

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# Values files relating to object storage
source $SCRIPT_DIR/minio.env

ORIGINAL_RONDB_NAMESPACE=rondb-original
RESTORED_RONDB_NAMESPACE=rondb-restored
RONDB_CLUSTER_NAME=my-rondb

getBackupId() {
    local namespace=$1
    POD_NAME=$(kubectl get pods -n $namespace --selector=job-name=manual-backup -o jsonpath='{.items[?(@.status.phase=="Succeeded")].metadata.name}' | head -n 1)
    BACKUP_ID=$(kubectl logs $POD_NAME -n $namespace --container=upload-native-backups | grep -o "BACKUP-[0-9]\+" | head -n 1 | awk -F '-' '{print $2}')
    echo $BACKUP_ID
}

destroy_cluster() {
    local namespace=$1
    helm delete $RONDB_CLUSTER_NAME -n $namespace || true
    kubectl delete namespace $namespace || true
}

setupFirstCluster() {
    local namespace=$1
    kubectl delete namespace $namespace || true
    kubectl create namespace $namespace

    kubectl create secret generic $BUCKET_SECRET_NAME \
        --namespace=$namespace \
        --from-literal "key_id=${MINIO_ACCESS_KEY}" \
        --from-literal "access_key=${MINIO_SECRET_KEY}"

    helm install $RONDB_CLUSTER_NAME \
        --namespace=$namespace \
        --values ./values/minikube/mini.yaml \
        --values $backups_values_file \
        --set backups.enabled=true .

    helm test -n $namespace $RONDB_CLUSTER_NAME --logs --filter name=generate-data

    kubectl delete job -n $namespace manual-backup || true
    kubectl create job -n $namespace --from=cronjob/create-backup manual-backup
    bash .github/wait_job.sh $namespace manual-backup 180
    BACKUP_ID=$(getBackupId $namespace)
    echo "BACKUP_ID is ${BACKUP_ID}"
}

restoreCluster() {
    local namespace=$1
    local backupId=$2

    kubectl delete namespace $namespace || true
    kubectl create namespace $namespace

    kubectl create secret generic $BUCKET_SECRET_NAME \
        --namespace=$namespace \
        --from-literal "key_id=${MINIO_ACCESS_KEY}" \
        --from-literal "access_key=${MINIO_SECRET_KEY}"

    helm install $RONDB_CLUSTER_NAME \
        --namespace=$namespace \
        --values ./values/minikube/mini.yaml \
        --values $restore_values_file \
        --set restoreFromBackup.backupId=${backupId} \
        .

    # Check that restoring worked
    helm test -n $namespace $RONDB_CLUSTER_NAME --logs --filter name=verify-data
}

setupFirstCluster $ORIGINAL_RONDB_NAMESPACE
BACKUP_ID=$(getBackupId $ORIGINAL_RONDB_NAMESPACE)
# We destroy this here in order to free up resources
destroy_cluster $ORIGINAL_RONDB_NAMESPACE

restoreCluster $RESTORED_RONDB_NAMESPACE $BACKUP_ID
destroy_cluster $RESTORED_RONDB_NAMESPACE

rm -f $backups_values_file
rm -f $restore_values_file
