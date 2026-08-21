#!/bin/bash

# Copyright (c) 2024-2026 Hopsworks AB. All rights reserved.



until nslookup $MGMD_HOSTNAME; do
    echo "Waiting for $MGMD_HOSTNAME to be resolvable..."
    sleep $(((RANDOM % 2) + 2))
done

echo "trying to connect to the management node.."
until /srv/hops/mysql/bin/ndb_mgm --ndb-connectstring $MGMD_HOSTNAME -e "show"; do
    echo "Waiting for $MGMD_HOSTNAME to be ready..."
    sleep $(((RANDOM % 2) + 2))
done

{{- $nodeIds := list -}}
{{- range $nodeGroup := until ($.Values.clusterSize.numNodeGroups | int) -}}
{{- range $replica := until 3 -}}
{{- $isActive := 0 -}}
{{- if lt $replica ($.Values.clusterSize.activeDataReplicas | int) -}}
  {{- $isActive = 1 -}}
{{- end -}}
{{- $offset := ( mul $nodeGroup 3) -}}
{{- $nodeId := ( add $offset (add $replica 1)) -}}
{{- if eq $isActive 1 -}}
{{- $nodeIds = append $nodeIds $nodeId -}}
{{- end -}}
{{- end -}}
{{- end }}

# Block until every active ndbmtd reports "started". This runs as an init
# container, and staying alive until the dependency is met is the init
# container contract: several consumers are Jobs with backoffLimit=0
# (setup-mysqld, in-place restore), where exiting non-zero is TERMINAL. A
# data node that finished starting a minute after a bounded wait gave up
# used to fail the setup-mysqld Job permanently — nothing re-runs it, the
# mysqlds wait forever on the Job, and the install is bricked. A stuck wait
# surfaces as the pod staying in Init, which is visible and recoverable;
# giving up is not.
echo "Waiting for all active ndbmtds to be started..."
ATTEMPT=0
while true; do
    ATTEMPT=$(( ATTEMPT + 1 ))
    echo "Waiting for data nodes (attempt $ATTEMPT)..."

    # Returns early once the cluster reports started, otherwise bounded so
    # the per-node check below runs and logs progress every couple of
    # minutes. Its exit code is deliberately not the gate: with
    # activeDataReplicas < 3 it can keep timing out on the inactive node
    # slots even when every active node is up.
    /srv/hops/mysql/bin/ndb_waiter -c $MGMD_HOSTNAME --timeout=120

    # check all the ndbmtds in reverse order since stateful sets typically
    # roll restart in the reverse order
    ALL_STARTED=true
{{ range $nodeId := reverse $nodeIds }}
    echo "Check if ndbmtd {{ $nodeId }} is ready"
    STATUS=$(/srv/hops/mysql/bin/ndb_mgm --ndb-connectstring $MGMD_HOSTNAME -e "{{ $nodeId }} status")
    echo $STATUS
    if [[ "$STATUS" != *"started"* ]]; then
        echo "Node {{ $nodeId }} is not started yet"
        ALL_STARTED=false
    fi
{{ end }}
    if [[ "$ALL_STARTED" == "true" ]]; then
        break
    fi
    sleep $(((RANDOM % 2) + 2))
done

echo "Successfully waited for all active ndbmtds to be started"
