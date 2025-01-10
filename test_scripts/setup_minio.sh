#!/bin/bash

# Copyright (c) 2024-2025 Hopsworks AB. All rights reserved.

# Script to start a MinIO tenant and write values files for backups and restores

set -e

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

source $SCRIPT_DIR/minio.env

helm repo add minio https://operator.min.io/

BUCKET_NAME=rondb-backups
BUCKET_REGION=eu-north-1

# TODO: Wait for MinIO controller to be ready

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

# No https/TLS needed due to `tenant.certificate.requestAutoCert=false`
MINIO_ENDPOINT=http://minio.$MINIO_TENANT_NAMESPACE.svc.cluster.local

# Object storage info is re-usable for both backups and restores
writeValuesFiles() {
    local YAML_CONTENT=$(
        cat <<EOF
  s3:
    provider: Minio
    endpoint: $MINIO_ENDPOINT
    bucketName: $BUCKET_NAME
    region: $BUCKET_REGION
    serverSideEncryption: null
    keyCredentialsSecret:
      name: $BUCKET_SECRET_NAME
      key: key_id
    secretCredentialsSecret:
      name: $BUCKET_SECRET_NAME
      key: access_key
EOF
    )

    # We write two different values files to make sure the templating is correct
    {
        echo "backups:"
        echo "$YAML_CONTENT"
    } >"$backups_values_file"

    {
        echo "restoreFromBackup:"
        echo "$YAML_CONTENT"
    } >"$restore_values_file"
}

writeValuesFiles
