#!/bin/bash

# Copyright (c) 2024-2024 Hopsworks AB. All rights reserved.

set -e

NAMESPACE=$1
PRIMARY_KUBECONFIG=$2
SECONDARY_KUBECONFIG=$3

BINLOG_SERVER_LOAD_BALANCER_PREFIX=binlog-server
MYSQL_SECRET_NAME="mysql-passwords"
NUM_BINLOG_SERVERS=2
PRIMARY_CLUSTER_NUMBER=1

# TODO: Fix ingress.enabled after other PR
helm upgrade -i rondb-primary \
    --namespace=$NAMESPACE \
    --kubeconfig=$PRIMARY_KUBECONFIG . \
    --set "meta.binlogServers.externalLoadBalancers.namePrefix=$BINLOG_SERVER_LOAD_BALANCER_PREFIX" \
    --set "clusterSize.minNumRdrs=0" \
    --set "mysql.credentialsSecretName=$MYSQL_SECRET_NAME" \
    --set "mysql.supplyOwnSecret=false" \
    --set "tls.ingress.enabled=false" \
    --set "globalReplication.clusterNumber=$PRIMARY_CLUSTER_NUMBER" \
    --set "globalReplication.primary.enabled=true" \
    --set "globalReplication.primary.numBinlogServers=$NUM_BINLOG_SERVERS" \
    --set "globalReplication.primary.maxNumBinlogServers=$((NUM_BINLOG_SERVERS + 1))"

echo "Waiting binlog server IPs before starting the secondary..."
BINLOG_IPS=()
for ((i = 0; i < NUM_BINLOG_SERVERS; i++)); do
    BINLOG_LB_NAME="$BINLOG_SERVER_LOAD_BALANCER_PREFIX-$i"

    echo "Waiting for external IP for $BINLOG_LB_NAME..."
    EXTERNAL_IP=""
    while [ -z "$EXTERNAL_IP" ]; do
        echo "Fetching external IP..."
        EXTERNAL_IP=$(kubectl get svc $BINLOG_LB_NAME \
            --namespace=$NAMESPACE \
            --kubeconfig=$PRIMARY_KUBECONFIG \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
        sleep 5
    done
    echo "External IP: $EXTERNAL_IP"

    BINLOG_IPS+=("$EXTERNAL_IP")
done
BINLOG_IPS_STR=$(
    IFS=,
    echo "${BINLOG_IPS[*]}"
)

echo "Binlog server IPs: $BINLOG_IPS_STR"

# Copy Secret into secondary cluster
kubectl get secret $MYSQL_SECRET_NAME --kubeconfig=$PRIMARY_KUBECONFIG --namespace=$NAMESPACE -o yaml |
    sed '/namespace/d; /creationTimestamp/d; /resourceVersion/d; /uid/d' |
    kubectl apply --kubeconfig=$SECONDARY_KUBECONFIG --namespace=$NAMESPACE -f -

# TODO: Fix ingress.enabled after other PR
helm upgrade -i rondb-secondary \
    --namespace=$NAMESPACE \
    --kubeconfig=$SECONDARY_KUBECONFIG . \
    --set "clusterSize.minNumRdrs=0" \
    --set "mysql.credentialsSecretName=$MYSQL_SECRET_NAME" \
    --set "mysql.supplyOwnSecret=true" \
    --set "tls.ingress.enabled=false" \
    --set "globalReplication.clusterNumber=$((PRIMARY_CLUSTER_NUMBER + 1))" \
    --set "globalReplication.secondary.enabled=true" \
    --set "globalReplication.secondary.replicateFrom.clusterNumber=$PRIMARY_CLUSTER_NUMBER" \
    --set "globalReplication.secondary.replicateFrom.binlogServerHosts={$BINLOG_IPS_STR}"
