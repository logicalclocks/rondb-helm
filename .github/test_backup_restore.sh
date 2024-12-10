#!/bin/bash

# This is a script to test the backup and restore functionality.
# It is not actually being used by the CI/CD pipeline, but can be run manually.
# The CI runs similar code, but is more elaborate (e.g benchmarking, etc).
# This expects the MinIO operator to be installed in the cluster.

set -e

ORIGINAL_RONDB_NAMESPACE=rondb-original
RESTORED_RONDB_NAMESPACE=rondb-restored
RONDB_CLUSTER_NAME=my-rondb
BUCKET_SECRET_NAME=bucket-credentials
MINIO_ACCESS_KEY=minio
MINIO_SECRET_KEY=minio123
MINIO_TENANT_NAMESPACE=minio-tenant
BUCKET_NAME=$ORIGINAL_RONDB_NAMESPACE
BUCKET_REGION=eu-north-1

# No https/TLS needed due to `tenant.certificate.requestAutoCert=false`
MINIO_ENDPOINT=http://minio.$MINIO_TENANT_NAMESPACE.svc.cluster.local

_getBackupId() {
    POD_NAME=$(kubectl get pods -n $ORIGINAL_RONDB_NAMESPACE --selector=job-name=manual-backup -o jsonpath='{.items[?(@.status.phase=="Succeeded")].metadata.name}' | head -n 1)
    BACKUP_ID=$(kubectl logs $POD_NAME -n $ORIGINAL_RONDB_NAMESPACE --container=upload-native-backups | grep -o "BACKUP-[0-9]\+" | head -n 1 | awk -F '-' '{print $2}')
    echo $BACKUP_ID
}

setupFirstCluster() {
    helm upgrade -i \
        --namespace $MINIO_TENANT_NAMESPACE \
        --create-namespace \
        tenant minio/tenant \
        --set "tenant.pools[0].name=my-pool" \
        --set "tenant.pools[0].servers=1" \
        --set "tenant.pools[0].volumesPerServer=1" \
        --set "tenant.pools[0].size=4Gi" \
        --set "tenant.certificate.requestAutoCert=false" \
        --set "tenant.configSecret.name=myminio-env-configuration" \
        --set "tenant.configSecret.accessKey=${MINIO_ACCESS_KEY}" \
        --set "tenant.configSecret.secretKey=${MINIO_SECRET_KEY}" \
        --set "tenant.buckets[0].name=${BUCKET_NAME}" \
        --set "tenant.buckets[0].region=${BUCKET_REGION}"

    kubectl create namespace $ORIGINAL_RONDB_NAMESPACE || true

    kubectl create secret generic $BUCKET_SECRET_NAME \
        --namespace=$ORIGINAL_RONDB_NAMESPACE \
        --from-literal "key_id=${MINIO_ACCESS_KEY}" \
        --from-literal "access_key=${MINIO_SECRET_KEY}" || true

    rondb_vals=$(
        cat <<EOF
    --namespace=$ORIGINAL_RONDB_NAMESPACE \
    --values ./values/minikube/mini.yaml \
    --set backups.enabled=true \
    --set backups.s3.provider=Minio \
    --set backups.s3.endpoint=$MINIO_ENDPOINT \
    --set backups.s3.bucketName=$BUCKET_NAME \
    --set backups.s3.region=$BUCKET_REGION \
    --set backups.s3.serverSideEncryption=null \
    --set backups.s3.keyCredentialsSecret.name=$BUCKET_SECRET_NAME \
    --set backups.s3.keyCredentialsSecret.key=key_id \
    --set backups.s3.secretCredentialsSecret.name=$BUCKET_SECRET_NAME \
    --set backups.s3.secretCredentialsSecret.key=access_key
EOF
    )

    eval helm template $rondb_vals . >bla.yaml
    eval helm upgrade -i $RONDB_CLUSTER_NAME $rondb_vals .
    helm test -n $ORIGINAL_RONDB_NAMESPACE $RONDB_CLUSTER_NAME --logs --filter name=generate-data

    kubectl delete job -n $ORIGINAL_RONDB_NAMESPACE manual-backup || true
    kubectl create job -n $ORIGINAL_RONDB_NAMESPACE --from=cronjob/create-backup manual-backup
    bash .github/wait_job.sh $ORIGINAL_RONDB_NAMESPACE manual-backup 180
    BACKUP_ID=$(_getBackupId)
    echo "BACKUP_ID is ${BACKUP_ID}"
}

restoreCluster() {
    BACKUP_ID=$(_getBackupId)
    echo "BACKUP_ID is ${BACKUP_ID}"

    helm delete $RONDB_CLUSTER_NAME -n $ORIGINAL_RONDB_NAMESPACE
    kubectl delete namespace $ORIGINAL_RONDB_NAMESPACE

    kubectl create namespace $RESTORED_RONDB_NAMESPACE

    kubectl create secret generic $BUCKET_SECRET_NAME \
        --namespace=$RESTORED_RONDB_NAMESPACE \
        --from-literal "key_id=${MINIO_ACCESS_KEY}" \
        --from-literal "access_key=${MINIO_SECRET_KEY}"

    helm install $RONDB_CLUSTER_NAME \
        --namespace=$RESTORED_RONDB_NAMESPACE \
        --values ./values/minikube/mini.yaml \
        --set restoreFromBackup.backupId=${BACKUP_ID} \
        --set restoreFromBackup.s3.provider=Minio \
        --set restoreFromBackup.s3.endpoint=$MINIO_ENDPOINT \
        --set restoreFromBackup.s3.bucketName=$BUCKET_NAME \
        --set restoreFromBackup.s3.region=$BUCKET_REGION \
        --set restoreFromBackup.s3.serverSideEncryption=null \
        --set restoreFromBackup.s3.keyCredentialsSecret.name=$BUCKET_SECRET_NAME \
        --set restoreFromBackup.s3.keyCredentialsSecret.key=key_id \
        --set restoreFromBackup.s3.secretCredentialsSecret.name=$BUCKET_SECRET_NAME \
        --set restoreFromBackup.s3.secretCredentialsSecret.key=access_key \
        .

    # Check that restoring worked
    helm test -n $RESTORED_RONDB_NAMESPACE $RONDB_CLUSTER_NAME --logs --filter name=verify-data
}

destroy_restored_cluster() {
    helm delete $RONDB_CLUSTER_NAME -n $RESTORED_RONDB_NAMESPACE
    kubectl delete namespace $RESTORED_RONDB_NAMESPACE
}

destroy_minio_tenant() {
    helm delete tenant -n $MINIO_TENANT_NAMESPACE
    kubectl delete namespace $MINIO_TENANT_NAMESPACE
}

setupFirstCluster
restoreCluster
destroy_restored_cluster
