#!/bin/bash

# Copyright (c) 2024-2025 Hopsworks AB. All rights reserved.

NAMESPACE=$1

PODS=$(kubectl get pods -n $NAMESPACE -o json | jq -r '.items[] | select(.metadata.annotations["helm.sh/hook"] == "test") | .metadata.name')
if [ -z "$PODS" ]; then
    echo "No Pods with annotation 'helm.sh/hook=test' found in namespace $NAMESPACE"
    exit 0
fi

for POD in $PODS; do
    kubectl delete pod -n $NAMESPACE $POD
done
