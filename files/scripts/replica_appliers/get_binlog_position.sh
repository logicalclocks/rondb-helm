#!/bin/bash

TRUE="true"
FALSE="false"

function mysqlLocal() {
    command mysql --defaults-file=$RONDB_DATA_DIR/my.cnf --protocol=tcp -hlocalhost "$@"
}

# TODO: Not sure whether we should always start from binlog.000001
function _getFirstBinlogPosition() {
    local SOURCE_HOST=$1

    function mysqlBinlogServer() {
        mysqlLocal -h$SOURCE_HOST "$@"
    }

    # TODO: Add the format to values.yaml
    # TODO: Figure out why binlog.000001 doesn't work
    DEFAULT_BINLOG_FILE=binlog.000003
    DEFAULT_BINLOG_POSITION=4

    # Get binlog position & file from lowest epoch
    # If there is no data written to the cluster yet, it can happen that the
    # ndb_binlog_index table is empty. In this case, we use a hardcoded value.
    read BINLOG_FILE BINLOG_POSITION < <(mysqlBinlogServer -N -B -e "
SELECT
    IFNULL(
        (
            SELECT SUBSTRING_INDEX(File, '/', -1)
                FROM mysql.ndb_binlog_index
                WHERE epoch = (
                    SELECT MIN(epoch) FROM mysql.ndb_binlog_index
                )
        ),
        '$DEFAULT_BINLOG_FILE'
    ) AS File,
    IFNULL(
        (
            SELECT Position
                FROM mysql.ndb_binlog_index
                WHERE epoch = (
                    SELECT MIN(epoch) FROM mysql.ndb_binlog_index
                )
        ),
        '$DEFAULT_BINLOG_POSITION'
    ) AS Position
FROM dual;
")

    echo "$BINLOG_FILE" "$BINLOG_POSITION"
}

# Beware that this function can be called at any time in a cluster's lifecycle
# I.e. just after a backup has been restored or after data has already been inserted.
function _getLastAppliedEpoch() {
    read LATEST_OWN_EPOCH < <(mysqlLocal -N -B -e "
SELECT MAX(epoch)
    FROM mysql.ndb_apply_status
    WHERE server_id <> 0;
")

    # Even if we have restored a backup, we have now already applied our own
    if [[ "$LATEST_OWN_EPOCH" != "NULL" ]]; then
        echo "$LATEST_OWN_EPOCH" "$FALSE"
        return
    fi

    # A backup may come from a third cluster with a higher epoch than the primary's
    # one. In this case, we need to make sure we check any epoch that we have applied
    # ourselves first.
    read LATEST_RESTORED_EPOCH < <(mysqlLocal -N -B -e "
SELECT MAX(epoch)
    FROM mysql.ndb_apply_status
    WHERE server_id = 0;
")

    if [[ "$LATEST_RESTORED_EPOCH" == "NULL" ]]; then
        echo "$LATEST_RESTORED_EPOCH" "$FALSE"
    else
        echo "$LATEST_RESTORED_EPOCH" "$TRUE"
    fi
    return
}

# This writes binlog_file and binlog_position to the result file
function getBinlogPosition() {
    local SOURCE_HOST=$1
    local RESULT_FILE=$2

    function mysqlBinlogServer() {
        mysqlLocal -h$SOURCE_HOST "$@"
    }

    read -r LATEST_EPOCH IS_RESTORED_EPOCH <<<"$(_getLastAppliedEpoch)"

    # We start from scratch here
    if [[ "$LATEST_EPOCH" == "NULL" ]]; then
        echo "No latest applied epoch available, starting binlog from scratch"
        printf "%s\n" $(_getFirstBinlogPosition $SOURCE_HOST) >$RESULT_FILE
        return
    fi

    echo "Our latest epoch: $LATEST_EPOCH; restored from a backup: $IS_RESTORED_EPOCH"

    # This is easiest; we have applied non-backup-related-epoch(s) from the primary
    # The epoch is an actual epoch from the primary
    if [[ $IS_RESTORED_EPOCH == "$FALSE" ]]; then
        read BINLOG_FILE BINLOG_POSITION < <(mysqlBinlogServer -N -B -e "
SELECT SUBSTRING_INDEX(next_file, '/', -1) as next_file, next_position
    FROM mysql.ndb_binlog_index
    WHERE epoch = $LATEST_EPOCH;
")
        if [[ -z "$BINLOG_FILE" || -z "$BINLOG_POSITION" ]]; then
            echo "The current binlog server does not contain our current epoch" >&2
            return 1
        fi
        echo "$BINLOG_FILE" >$RESULT_FILE
        echo "$BINLOG_POSITION" >>$RESULT_FILE
        return
    fi

    # State: Our latest applied epoch is from a backup
    #        It is therefore also a pseudo-epoch.

    # Check whether remote cluster had restored a backup
    read REMOTE_NUM_RESTORES < <(mysqlBinlogServer -N -B -e "
SELECT COUNT(*)
    FROM mysql.ndb_apply_status
    WHERE server_id = 0;
")
    echo "Number of restores in the primary cluster: $REMOTE_NUM_RESTORES"

    # The primary and secondary have restored the same backup; the epoch is useless
    # since it is from a third cluster. Every cluster will have their own epochs.
    if [[ "$REMOTE_NUM_RESTORES" -gt 0 ]]; then
        printf "%s\n" $(_getFirstBinlogPosition $SOURCE_HOST) >$RESULT_FILE
        return
    fi

    # State: We have restored a backup; the remote has not
    # State: Our backup was HOPEFULLY created by the remote (hard to check this)
    # Issue: Since we have a pseudo-epoch, we cannot use the equals-operator
    # Issue: We don't know whether the remote has applied any epochs after the backup

    # Assumption: Epochs have been applied after the backup
    read BINLOG_FILE BINLOG_POSITION < <(mysqlBinlogServer -N -B -e "
SELECT SUBSTRING_INDEX(File, '/', -1), position
    FROM mysql.ndb_binlog_index
    WHERE epoch > $LATEST_EPOCH
    ORDER BY epoch ASC
    LIMIT 1;
")

    # Assumption was correct
    if [[ -n "$BINLOG_FILE" && -n $BINLOG_POSITION ]]; then
        echo "Epochs have been applied on primary cluster after the backup"
        echo "$BINLOG_FILE" >$RESULT_FILE
        echo "$BINLOG_POSITION" >>$RESULT_FILE
        return
    fi

    # Assumption: We have some pre-backup binlog files.
    #             The binlog files have not been purged since the backup.
    # Action:     We get the PREVIOUS (real) epoch and fetch the NEXT
    #             binlog file and position.
    read BINLOG_FILE BINLOG_POSITION < <(mysqlBinlogServer -N -B -e "
SELECT SUBSTRING_INDEX(next_file, '/', -1),
            next_position
    FROM mysql.ndb_binlog_index
    WHERE epoch < $LATEST_EPOCH
    ORDER BY epoch DESC
    LIMIT 1;
")

    if [[ -n "$BINLOG_FILE" && -n $BINLOG_POSITION ]]; then
        echo "There are some pre-backup binlog files available; they have not been purged"
        echo "$BINLOG_FILE" >$RESULT_FILE
        echo "$BINLOG_POSITION" >>$RESULT_FILE
        return
    fi

    echo "Failed to determine binlog position" >&2
    cat <<EOF
LATEST_EPOCH:           $LATEST_EPOCH
IS_RESTORED_EPOCH:      $IS_RESTORED_EPOCH
IS_RESTORED_EPOCH:      $IS_RESTORED_EPOCH
REMOTE_NUM_RESTORES:    $REMOTE_NUM_RESTORES
EOF
    return 1
}
