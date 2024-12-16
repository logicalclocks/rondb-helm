#!/bin/bash

# Copyright (c) 2024-2024 Hopsworks AB. All rights reserved.

until nslookup $MGMD_HOSTNAME; do
    echo "Waiting for $MGMD_HOSTNAME to be resolvable..."
    sleep $(((RANDOM % 2) + 2))
done

# Wait until data node is ready
until ./docker/rondb_standalone/healthcheck.sh $MGMD_HOSTNAME:1186 1; do
    echo "Dependency healthcheck of ndbmtd failed. Retrying in a bit"
    sleep $(((RANDOM % 2) + 2))
done

echo "Successfully waited for an ndbmtd to be ready"
