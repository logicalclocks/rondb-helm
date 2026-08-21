#!/bin/bash

set +e

TOTAL=0
OK_SECONDS=0
SKIP=0

while true; do
    sleep $SLEEP_SECONDS
    TOTAL=$((TOTAL + SLEEP_SECONDS))

    # A failing kubectl must never read as "everything is ready": an empty
    # result would pass every check below, so an unreachable API server would
    # silently report a broken cluster as stable.
    POD_STATUS=$(kubectl \
        -n $K8S_NAMESPACE \
        get pods \
        -o custom-columns="POD:metadata.name,POD_PHASE:status.phase,READY:status.containerStatuses[*].ready" 2>&1)
    if [ $? -ne 0 ]; then
        echo "kubectl get pods failed after $TOTAL seconds, treating cluster as not ready:"
        echo "$POD_STATUS"
        OK_SECONDS=0
        continue
    fi

    NUM_NOT_READY=$(echo "$POD_STATUS" |
        egrep -v "Succeeded" |
        grep -e POD -e POD_PHASE -e "Pending" -e "false")

    # Check that all StatefulSets have their desired replica count.
    # This catches scenarios where a StatefulSet has 0 pods (e.g. FailedCreate),
    # which the pod readiness check above would vacuously pass.
    STS_RAW=$(kubectl get statefulsets -n $K8S_NAMESPACE --no-headers 2>&1)
    if [ $? -ne 0 ]; then
        echo "kubectl get statefulsets failed after $TOTAL seconds, treating cluster as not ready:"
        echo "$STS_RAW"
        OK_SECONDS=0
        continue
    fi
    # Only parse well-formed "<name> <ready>/<desired>" rows. Anything else is
    # kubectl chatter rather than a StatefulSet - notably the "No resources
    # found" notice, which arrives on stderr and would otherwise be read as a
    # StatefulSet that is short of replicas.
    STS_NOT_READY=$(echo "$STS_RAW" | awk '$2 ~ /^[0-9]+\/[0-9]+$/ { split($2,a,"/"); if (a[1] != a[2]) print $0 }')

    PODS_READY=true
    # lt 2 because of header (keep for readability)
    if [ $(echo "$NUM_NOT_READY" | wc -l) -ge 2 ]; then
        PODS_READY=false
    fi

    if $PODS_READY && [ -z "$STS_NOT_READY" ]; then
        OK_SECONDS=$((OK_SECONDS + SLEEP_SECONDS))
        echo "All pods and StatefulSets have been ready for $OK_SECONDS seconds now"
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
        if [ -n "$STS_NOT_READY" ]; then
            echo
            echo "####################################################"
            echo "StatefulSets not at desired replica count"
            echo "####################################################"
            kubectl get statefulsets -n $K8S_NAMESPACE && echo
            kubectl describe statefulsets -n $K8S_NAMESPACE && echo
        fi
        SKIP=0
    else
        SKIP=$((SKIP + 1))
    fi

    if ! $PODS_READY; then
        echo "Some Pods are pending or not ready yet" && echo
        echo "$NUM_NOT_READY" && echo
    fi
    if [ -n "$STS_NOT_READY" ]; then
        echo "Some StatefulSets don't have all replicas ready:" && echo
        echo "$STS_NOT_READY" && echo
    fi
done
