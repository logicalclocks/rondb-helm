#!/bin/bash

# Copyright (c) 2024-2025 Hopsworks AB. All rights reserved.

until nslookup $MGMD_HOSTNAME; do
    echo "Waiting for $MGMD_HOSTNAME to be resolvable..."
    sleep $(((RANDOM % 2) + 2))
done

echo "trying to connect to the management node.."
until /srv/hops/mysql/bin/ndb_mgm --ndb-connectstring $MGMD_HOSTNAME -e "show"; do
    echo "Waiting for $MGMD_HOSTNAME to be ready..."
    sleep $(((RANDOM % 2) + 2))
done

# check all the ndbmtds in reverse order since stateful sets typically roll restart in the reverse order
echo "Waiting for all ndbmtds to be ready..."
for i in $(seq 0 5);
do
    echo "waiting for all ndbmtds retry $(( i + 1 )) out 6 retries"
    /srv/hops/mysql/bin/ndb_waiter -c $MGMD_HOSTNAME  --timeout=$(( 120 * (2 ** i) ))
    sleep $((2 ** i))
done

echo "Make sure that all ndbmtds are ready..."

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
{{- end -}}

{{ range $nodeId := reverse $nodeIds }}
echo "Check if ndbmtd {{ $nodeId }} is ready"
STATUS=$(/srv/hops/mysql/bin/ndb_mgm --ndb-connectstring $MGMD_HOSTNAME -e "{{ $nodeId }} status")
echo $STATUS
if [[ "$STATUS" != *"started"* ]]; then
    echo "Node {{ $nodeId }} is not ready, exiting..."
    exit 1
fi
sleep $(((RANDOM % 2) + 2))
{{ end }}

echo "Successfully waited for an ndbmtd to be ready"
