#!/bin/bash

# Copyright (c) 2024-2025 Hopsworks AB. All rights reserved.

set -e

PRIMARY_NAMESPACE=$1
SECONDARY_NAMESPACE=$2

PRIMARY_CLUSTER_NUMBER=1

NUM_BINLOG_SERVERS=2
BINLOG_SERVER_STATEFUL_SET=mysqld-binlog-servers
BINLOG_SERVER_HEADLESS=headless-binlog-servers

MYSQL_SECRET_NAME="mysql-passwords"

helm upgrade -i rondb-primary \
    --namespace=$PRIMARY_NAMESPACE . \
    --values values/minikube/mini.yaml \
    --set "clusterSize.minNumRdrs=0" \
    --set "mysql.credentialsSecretName=$MYSQL_SECRET_NAME" \
    --set "mysql.supplyOwnSecret=false" \
    --set "globalReplication.clusterNumber=$PRIMARY_CLUSTER_NUMBER" \
    --set "globalReplication.primary.enabled=true" \
    --set "globalReplication.primary.numBinlogServers=$NUM_BINLOG_SERVERS" \
    --set "globalReplication.primary.maxNumBinlogServers=$((NUM_BINLOG_SERVERS+1))" \
    --set "meta.binlogServers.statefulSet.name=$BINLOG_SERVER_STATEFUL_SET" \
    --set "meta.binlogServers.headlessClusterIp.name=$BINLOG_SERVER_HEADLESS"

echo "Waiting before starting the secondary..."
(
    set -x
    kubectl wait \
        -n $PRIMARY_NAMESPACE \
        --for=condition=complete \
        --timeout=6m \
        job/setup-mysqld-dont-remove
)

# Copy Secret into new namespace
kubectl get secret $MYSQL_SECRET_NAME --namespace=$PRIMARY_NAMESPACE -o yaml |
    sed '/namespace/d; /creationTimestamp/d; /resourceVersion/d; /uid/d' | 
    kubectl apply --namespace=$SECONDARY_NAMESPACE -f -

BINLOG_HOSTS=()
for (( i=0; i<NUM_BINLOG_SERVERS; i++ )); do
    BINLOG_SERVER_HOST="${BINLOG_SERVER_STATEFUL_SET}-$i.${BINLOG_SERVER_HEADLESS}.${PRIMARY_NAMESPACE}.svc.cluster.local"
    BINLOG_HOSTS+=("$BINLOG_SERVER_HOST")
done
BINLOG_HOSTS_STR=$(IFS=,; echo "${BINLOG_HOSTS[*]}")

helm upgrade -i rondb-secondary \
    --namespace=$SECONDARY_NAMESPACE . \
    --values values/minikube/mini.yaml \
    --set "clusterSize.minNumRdrs=0" \
    --set "priorityClass=new-class" \
    --set "mysql.credentialsSecretName=$MYSQL_SECRET_NAME" \
    --set "mysql.supplyOwnSecret=true" \
    --set "globalReplication.clusterNumber=$((PRIMARY_CLUSTER_NUMBER+1))" \
    --set "globalReplication.secondary.enabled=true" \
    --set "globalReplication.secondary.replicateFrom.clusterNumber=$PRIMARY_CLUSTER_NUMBER" \
    --set "globalReplication.secondary.replicateFrom.binlogServerHosts={$BINLOG_HOSTS_STR}"
