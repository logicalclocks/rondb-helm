#!/bin/bash

# This is a script to test the backup and restore functionality.
# It is not actually being used by the CI/CD pipeline, but can be run manually.
# The CI runs similar code, but is more elaborate (e.g benchmarking, etc).
# This expects the MinIO operator to be installed in the cluster.

set -e

backups_values_file=values.backup.yaml
restore_values_file=values.restore.yaml
BUCKET_SECRET_NAME=rondb-backups
MINIO_ACCESS_KEY=minio
MINIO_SECRET_KEY=minio123
./test_scripts/setup_minio.sh $backups_values_file $restore_values_file $BUCKET_SECRET_NAME $MINIO_ACCESS_KEY $MINIO_SECRET_KEY

ORIGINAL_RONDB_NAMESPACE=rondb-original
RESTORED_RONDB_NAMESPACE=rondb-restored
RONDB_CLUSTER_NAME=my-rondb

_getBackupId() {
    POD_NAME=$(kubectl get pods -n $ORIGINAL_RONDB_NAMESPACE --selector=job-name=manual-backup -o jsonpath='{.items[?(@.status.phase=="Succeeded")].metadata.name}' | head -n 1)
    BACKUP_ID=$(kubectl logs $POD_NAME -n $ORIGINAL_RONDB_NAMESPACE --container=upload-native-backups | grep -o "BACKUP-[0-9]\+" | head -n 1 | awk -F '-' '{print $2}')
    echo $BACKUP_ID
}

setupFirstCluster() {
    kubectl delete namespace $ORIGINAL_RONDB_NAMESPACE || true
    kubectl create namespace $ORIGINAL_RONDB_NAMESPACE

    kubectl create secret generic $BUCKET_SECRET_NAME \
        --namespace=$ORIGINAL_RONDB_NAMESPACE \
        --from-literal "key_id=${MINIO_ACCESS_KEY}" \
        --from-literal "access_key=${MINIO_SECRET_KEY}"

    helm install $RONDB_CLUSTER_NAME \
        --namespace=$ORIGINAL_RONDB_NAMESPACE \
        --values ./values/minikube/mini.yaml \
        --values $backups_values_file \
        --set backups.enabled=true .

    helm test -n $ORIGINAL_RONDB_NAMESPACE $RONDB_CLUSTER_NAME --logs --filter name=generate-data

    kubectl delete job -n $ORIGINAL_RONDB_NAMESPACE manual-backup || true
    kubectl create job -n $ORIGINAL_RONDB_NAMESPACE --from=cronjob/create-backup manual-backup
    bash .github/wait_job.sh $ORIGINAL_RONDB_NAMESPACE manual-backup 180
    BACKUP_ID=$(_getBackupId)
    echo "BACKUP_ID is ${BACKUP_ID}"
}

destroy_first_cluster() {
    helm delete $RONDB_CLUSTER_NAME -n $ORIGINAL_RONDB_NAMESPACE  || true
    kubectl delete namespace $ORIGINAL_RONDB_NAMESPACE  || true
}

restoreCluster() {
    BACKUP_ID=$(_getBackupId)
    echo "BACKUP_ID is ${BACKUP_ID}"

    destroy_first_cluster

    kubectl delete namespace $RESTORED_RONDB_NAMESPACE || true
    kubectl create namespace $RESTORED_RONDB_NAMESPACE

    kubectl create secret generic $BUCKET_SECRET_NAME \
        --namespace=$RESTORED_RONDB_NAMESPACE \
        --from-literal "key_id=${MINIO_ACCESS_KEY}" \
        --from-literal "access_key=${MINIO_SECRET_KEY}"

    helm install $RONDB_CLUSTER_NAME \
        --namespace=$RESTORED_RONDB_NAMESPACE \
        --values ./values/minikube/mini.yaml \
        --values $restore_values_file \
        --set restoreFromBackup.backupId=${BACKUP_ID} \
        .

    # Check that restoring worked
    helm test -n $RESTORED_RONDB_NAMESPACE $RONDB_CLUSTER_NAME --logs --filter name=verify-data
}

destroy_restored_cluster() {
    helm delete $RONDB_CLUSTER_NAME -n $RESTORED_RONDB_NAMESPACE  || true
    kubectl delete namespace $RESTORED_RONDB_NAMESPACE  || true
}

destroy_minio_tenant() {
    helm delete tenant -n $MINIO_TENANT_NAMESPACE
    kubectl delete namespace $MINIO_TENANT_NAMESPACE
}

setupFirstCluster
restoreCluster
destroy_restored_cluster
# destroy_minio_tenant

rm -f $backups_values_file
rm -f $restore_values_file
