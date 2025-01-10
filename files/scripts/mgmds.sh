#!/bin/bash

# Copyright (c) 2024-2025 Hopsworks AB. All rights reserved.

# The configuration database is a binary representation of the cluster's configuration.
# It is essentially the config.ini including all changes that were applied via the
# management client (ndb_mgm).

# We're always doing an initial start so that changes in the config.ini are applied
# Even if the main container starts, it will have the newest config.ini mounted to it.
ndb_mgmd --initial \
    --nodaemon \
    --ndb-nodeid=65 \
    -f "$RONDB_DATA_DIR/config.ini" \
    --configdir="{{ include "rondb.dataDir" $ }}/mgmd"
