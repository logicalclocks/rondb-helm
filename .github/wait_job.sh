#!/bin/bash

set +e

namespace=$1
job_name=$2
timeout_seconds=$3

kubectl wait --for=condition=complete -n $namespace --timeout=${timeout_seconds}s job/$job_name &
JOB_COMPLETION_PID=$!

set +e
while kill -0 $JOB_COMPLETION_PID 2>/dev/null; do
    echo "$(date) Job $job_name is still running..."
    sleep 20
    kubectl get pods -o wide -n $namespace

    # Check if the job has failed
    JOB_STATUS=$(kubectl get job $job_name -n $namespace -o jsonpath='{.status.failed}' 2>/dev/null || echo 0)
    if [[ "$JOB_STATUS" -gt 0 ]]; then
        echo "Job has failed. Stopping CI."
        kubectl describe job $job_name -n $namespace
        kubectl logs -l job-name=$job_name -n $namespace --tail=-1
        exit 1
    fi
done
set -e

wait $JOB_COMPLETION_PID
exit $?
