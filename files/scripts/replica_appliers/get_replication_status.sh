#!/bin/bash

# Copyright (c) 2024-2025 Hopsworks AB. All rights reserved.

set -e

REPLICA_STATUS=$(mysql \
    --defaults-file=$RONDB_DATA_DIR/my.cnf \
    --protocol=tcp \
    -hlocalhost \
    -e "SHOW REPLICA STATUS\G")

if [[ -z "$REPLICA_STATUS" ]]; then
    echo "Error: Unable to retrieve replication status." >&2
    exit 1
fi

set +e

# Check if Replica_IO_Running and Replica_SQL_Running are both 'Yes'
REPLICA_IO_RUNNING=$(echo "$REPLICA_STATUS" | grep "Replica_IO_Running:" | awk '{print $2}')
REPLICA_SQL_RUNNING=$(echo "$REPLICA_STATUS" | grep "Replica_SQL_Running:" | awk '{print $2}')

if [[ "$REPLICA_IO_RUNNING" == "Yes" && "$REPLICA_SQL_RUNNING" == "Yes" ]]; then
    echo "Replication is active."
else
    echo "Replica I/O thread running: $REPLICA_IO_RUNNING" >&2
    echo "Replica SQL thread running: $REPLICA_SQL_RUNNING" >&2
    exit 1
fi

LAST_IO_ERROR=$(echo "$REPLICA_STATUS" | grep "Last_IO_Error:" | awk '{print $2}')

if [[ -n "$LAST_IO_ERROR" ]]; then
    echo "Warning: There is an IO error: $LAST_IO_ERROR" >&2
fi

SECONDS_BEHIND_SOURCE=$(echo "$REPLICA_STATUS" | grep "Seconds_Behind_Source:" | awk '{print $2}')
if [[ "$SECONDS_BEHIND_SOURCE" -ne 0 ]]; then
    echo "Warning: Replication is behind source by $SECONDS_BEHIND_SOURCE seconds." >&2
fi

# Additional checks for log position
READ_SOURCE_LOG_POS=$(echo "$REPLICA_STATUS" | grep "Read_Source_Log_Pos:" | awk '{print $2}')
EXEC_SOURCE_LOG_POS=$(echo "$REPLICA_STATUS" | grep "Exec_Source_Log_Pos:" | awk '{print $2}')

if [[ "$READ_SOURCE_LOG_POS" -eq "$EXEC_SOURCE_LOG_POS" ]]; then
    echo "Replication is up and running, but no new transactions have been detected."
elif [[ "$READ_SOURCE_LOG_POS" -gt "$EXEC_SOURCE_LOG_POS" ]]; then
    echo "Replication is progressing."
else
    # This shouldn't happen
    echo "Replication positions are out of sync." >&2
    exit 1
fi
