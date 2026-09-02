#!/usr/bin/env bash

# Copyright (c) 2024-2026 Hopsworks AB. All rights reserved.



# Creates/updates the user-supplied MySQL users (mysql.users) on upgrades.
# Spins up a temporary local MySQLd on a spare API slot; since all users are
# created with NDB_STORED_USER, they propagate cluster-wide via NDB.

set -e

echo_newline() { echo; echo "$1"; echo; }

RAW_MYCNF_FILEPATH={{ include "rondb.dataDir" $ }}/my-raw.cnf
MYCNF_FILEPATH=$RONDB_DATA_DIR/my.cnf
cp $RAW_MYCNF_FILEPATH $MYCNF_FILEPATH

# Take a single empty slot
sed -i "/ndb-cluster-connection-pool/c\# ndb-cluster-connection-pool=1" $MYCNF_FILEPATH
sed -i "/ndb-cluster-connection-pool-nodeids/c\# ndb-cluster-connection-pool-nodeids" $MYCNF_FILEPATH
sed -i "/server-id/d" $MYCNF_FILEPATH

{{ include "rondb.initializeMySQLd" . }}

echo_newline "[K8s Entrypoint MySQLd] Running MySQLd as background-process in socket-only mode for user setup"
(
    set -x
    "${CMD[@]}" \
        --log-error-verbosity=3 \
        --skip-networking \
        --daemonize
)

echo_newline "[K8s Entrypoint MySQLd] Pinging MySQLd..."
SOCKET={{ include "rondb.dataDir" $ }}/mysql.sock
attempt=0
max_attempts=30
until mysqladmin -uroot --socket="$SOCKET" ping --silent --connect-timeout=2; do
    echo_newline "[K8s Entrypoint MySQLd] Failed pinging MySQLd on attempt $attempt" && sleep 1
    attempt=$((attempt + 1))
    if [[ $attempt -gt $max_attempts ]]; then
        echo_newline "[K8s Entrypoint MySQLd] Failed pinging MySQLd after $max_attempts attempts" && exit 1
    fi
done

echo_newline "[K8s Entrypoint MySQLd] MySQLd is up and running"

# Defining the client command used by the user-setup fragment below.
# "SET @@SESSION.SQL_LOG_BIN=0;" is required for products like group replication to work properly
function mysql() {
    command mysql \
        -uroot \
        -hlocalhost \
        --password="$MYSQL_ROOT_PASSWORD" \
        --protocol=socket \
        --socket="$SOCKET" \
        --init-command="SET @@SESSION.SQL_LOG_BIN=0;";
}

# --initialize-insecure starts root with an *empty* password; the cluster's
# stored users (GRANT NDB_STORED_USER), including root's real password, are
# applied asynchronously after this mysqld joins the cluster. Wait until root
# authentication with the real password succeeds before running any SQL.
echo_newline "[K8s Entrypoint MySQLd] Waiting for NDB stored users to be applied..."
attempt=0
max_attempts=60
until echo "SELECT 1;" | mysql > /dev/null 2>&1; do
    echo_newline "[K8s Entrypoint MySQLd] Root authentication not ready on attempt $attempt" && sleep 2
    attempt=$((attempt + 1))
    if [[ $attempt -gt $max_attempts ]]; then
        echo_newline "[K8s Entrypoint MySQLd] NDB stored users not applied after $max_attempts attempts" && exit 1
    fi
done
echo_newline "[K8s Entrypoint MySQLd] NDB stored users are applied"

#################################
### SETUP USER-SUPPLIED USERS ###
#################################

{{ include "rondb.mysql.setupUsersShell" . }}

#########################
### STOP LOCAL MYSQLD ###
#########################

# When using a local socket, mysqladmin shutdown will only complete when the
# server is actually down.
echo_newline '[K8s Entrypoint MySQLd] Shutting down MySQLd via mysqladmin...'
mysqladmin -uroot --password="$MYSQL_ROOT_PASSWORD" shutdown --socket="$SOCKET"
echo_newline "[K8s Entrypoint MySQLd] Successfully shut down MySQLd"
