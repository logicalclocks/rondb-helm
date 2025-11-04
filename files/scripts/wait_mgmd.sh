#!/bin/bash

# Copyright (c) 2024-2025 Hopsworks AB. All rights reserved.

until nslookup $MGMD_HOSTNAME; do
    echo "Waiting for $MGMD_HOSTNAME to be resolvable..."
    sleep $(((RANDOM % 2) + 2))
done

echo "Trying to connect to the management node.."
until /srv/hops/mysql/bin/ndb_mgm --ndb-connectstring $MGMD_HOSTNAME -e "show"; do
    echo "Waiting for $MGMD_HOSTNAME to be ready..."
    sleep $(((RANDOM % 2) + 2))
done