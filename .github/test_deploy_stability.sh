#!/bin/bash

set +e

TOTAL=0
OK_SECONDS=0
SKIP=0

while true; do
    sleep $SLEEP_SECONDS
    TOTAL=$((TOTAL + SLEEP_SECONDS))

    NUM_NOT_READY=$(kubectl \
        -n $K8S_NAMESPACE \
        get pods \
        -o custom-columns="POD:metadata.name,POD_PHASE:status.phase,READY:status.containerStatuses[*].ready" |
        egrep -v "Succeeded" |
        grep -e POD -e POD_PHASE -e "Pending" -e "false")

    # lt 2 because of header (keep for readability)
    if [ $(echo "$NUM_NOT_READY" | wc -l) -lt 2 ]; then
        OK_SECONDS=$((OK_SECONDS + SLEEP_SECONDS))
        echo "All pods have been ready for $OK_SECONDS seconds now"
        OK_MINUTES=$((OK_SECONDS / 60))
        if [ $OK_MINUTES -ge $MIN_STABLE_MINUTES ]; then
            echo "The cluster seems stable"
            exit 0
        fi
        continue
    fi

    # Avoid this printing if everything is fine
    echo "################################"
    echo "Iteration after $TOTAL seconds"
    echo "################################"

    OK_SECONDS=0

    # Only print this when failing bnut just if SKIP=30
    if [ $SKIP -eq 30 ]; then
        echo
        echo "####################################################"
        echo "Pods not ready"
        echo "####################################################"
        echo && kubectl get pods -o wide -n $K8S_NAMESPACE && echo
        echo && kubectl top pod -n $K8S_NAMESPACE && echo && echo
        echo && kubectl get node && echo
        echo && kubectl top node && echo
        SKIP=0
    else
        SKIP=$((SKIP + 1))
    fi

    echo "Some Pods are pending or not ready yet" && echo
    echo "$NUM_NOT_READY" && echo
done
