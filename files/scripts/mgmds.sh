#!/bin/bash

# Copyright (c) 2024-2024 Hopsworks AB. All rights reserved.

# The configuration database is a binary representation of the cluster's configuration.
# It is essentially the config.ini including all changes that were applied via the
# management client (ndb_mgm).

INITIAL_ARG=
CONFIG_DB_DIR={{ include "rondb.dataDir" $ }}/mgmd
FOUND_FILES=$(find "$CONFIG_DB_DIR" -type f -name "*config.bin.*")
NUM_FOUND=$(echo "$FOUND_FILES" | grep -c .)
if [ "$NUM_FOUND" -lt 1 ]; then
    echo "No configuration database available. Doing an initial start."
    INITIAL_ARG="--initial"

    BASE_DIR={{ include "rondb.dataDir" $ }}
    RONDB_VOLUME=${BASE_DIR}/default_storage
    for dir in log mgmd
    do
        rm -rf ${BASE_DIR}/${dir}
        mkdir -p ${RONDB_VOLUME}/${dir}
        ln -s ${RONDB_VOLUME}/${dir} ${BASE_DIR}/${dir}
    done

else
    echo "A configuration database was found. Not running an initial start."
fi

ndb_mgmd $INITIAL_ARG \
    --nodaemon \
    --ndb-nodeid=65 \
    -f "$RONDB_DATA_DIR/config.ini" \
    --configdir="$CONFIG_DB_DIR"
