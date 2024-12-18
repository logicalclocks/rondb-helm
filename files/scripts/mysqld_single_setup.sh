#!/bin/bash

# Copyright (c) 2024-2024 Hopsworks AB. All rights reserved.

set -e

echo_newline() { echo; echo "$1"; echo; }

{{ $maxTotalMySQLds := (include "rondb.maxTotalMySQLds" $ | int) -}}
{{ $serverIdOffset := mul $.Values.globalReplication.clusterNumber $maxTotalMySQLds -}}

###################
# SED MY.CNF FILE #
###################

RAW_MYCNF_FILEPATH={{ include "rondb.dataDir" $ }}/my-raw.cnf
MYCNF_FILEPATH=$RONDB_DATA_DIR/my.cnf
cp $RAW_MYCNF_FILEPATH $MYCNF_FILEPATH

# Take a single empty slot
sed -i "/ndb-cluster-connection-pool/c\# ndb-cluster-connection-pool=1" $MYCNF_FILEPATH
sed -i "/ndb-cluster-connection-pool-nodeids/c\# ndb-cluster-connection-pool-nodeids" $MYCNF_FILEPATH
sed -i "/^[ ]*server-id[ ]*=/c\server-id={{ $serverIdOffset }}" $MYCNF_FILEPATH

##################################
# MOVE OVER RESTORE-BACKUP FILES #
##################################

# In case nothing is restored, create the directory
RESTORE_SCRIPTS_DIR={{ include "rondb.sqlRestoreScriptsDir" . }}
mkdir -p $RESTORE_SCRIPTS_DIR
echo_newline "[K8s Entrypoint MySQLd] Directory for MySQL schemata to *restore*: '$RESTORE_SCRIPTS_DIR'"
(
    set -x
    ls -la $RESTORE_SCRIPTS_DIR
    find "$RESTORE_SCRIPTS_DIR" -type f -name "*.sql"
)

{{ include "rondb.initializeMySQLd" . }}

########################
# INITIALIZE DATABASES #
########################

echo_newline "[K8s Entrypoint MySQLd] Running MySQLd as background-process in socket-only mode for initialization"
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

echo_newline "[K8s Entryoint MySQLd] MySQLd is up and running"

###############################
### SETUP USERS & PASSWORDS ###
###############################

if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
    echo >&2 '[K8s Entrypoint MySQLd] No password option specified for root user.'
    exit 1
fi

# Defining the client command used throughout the script
# Since networking is not permitted for this mysql server, we have to use a socket to connect to it
# "SET @@SESSION.SQL_LOG_BIN=0;" is required for products like group replication to work properly
DUMMY_ROOT_PASSWORD=
function mysql() {
    command mysql \
        -uroot \
        -hlocalhost \
        --password="$DUMMY_ROOT_PASSWORD" \
        --protocol=socket \
        --socket="$SOCKET" \
        --init-command="SET @@SESSION.SQL_LOG_BIN=0;";
}

###########################
### ALTER ROOT PASSWORD ###
###########################

echo_newline '[K8s Entrypoint MySQLd] Changing the root user password'
mysql <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
GRANT NDB_STORED_USER ON *.* TO 'root'@'localhost';
FLUSH PRIVILEGES;
EOF

DUMMY_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD

##########################
### SETUP CLUSTER USER ###
##########################

echo_newline "[K8s Entrypoint MySQLd] Setting up cluster user '${MYSQL_CLUSTER_USER}'"
mysql <<EOF
-- Create user to operate the Helmchart
CREATE USER IF NOT EXISTS '${MYSQL_CLUSTER_USER}'@'%'
    IDENTIFIED BY '${MYSQL_CLUSTER_PASSWORD}';
GRANT NDB_STORED_USER ON *.* TO '${MYSQL_CLUSTER_USER}'@'%';
FLUSH PRIVILEGES;
EOF

################################
### SETUP HELM TEST SCHEMATA ###
################################

HELM_TEST_DB={{ include "rondb.databases.helmTests" $ | quote }}
mysql <<EOF
GRANT ALL PRIVILEGES ON ${HELM_TEST_DB}.* TO '${MYSQL_CLUSTER_USER}'@'%';
FLUSH PRIVILEGES;
EOF

####################################
### SETUP BENCHMARKING DATABASES ###
####################################

# Generally benchmarking databases should be excluded from backups and Global Replication.
# However, they might still be included in some backups. Hence, we use IF NOT EXISTS.

echo_newline "[K8s Entrypoint MySQLd] Initializing benchmarking schemata"

mysql <<EOF
-- Benchmarking table; all other tables will be created by the benchmarks themselves
{{ $databases := include "rondb.databases.benchmarking" . | fromYamlArray -}}
{{ range $databases -}}
CREATE DATABASE IF NOT EXISTS \`{{ . }}\`;
{{ end }}

{{ if $.Values.benchmarking.ycsb.schemata -}}
-- Create table for YCSB
{{ $.Values.benchmarking.ycsb.schemata }}
{{- end }}

-- Grant bench user rights to all bench databases
GRANT ALL PRIVILEGES ON \`dbt%\`.* TO '${MYSQL_CLUSTER_USER}'@'%';
GRANT ALL PRIVILEGES ON \`ycsb%\`.* TO '${MYSQL_CLUSTER_USER}'@'%';
GRANT ALL PRIVILEGES ON \`sysbench%\`.* TO '${MYSQL_CLUSTER_USER}'@'%';
GRANT ALL PRIVILEGES ON \`sbtest%\`.* TO '${MYSQL_CLUSTER_USER}'@'%';
FLUSH PRIVILEGES;
EOF

{{- if .Values.mysql.exporter.enabled }}
#################################
### SETUP MYSQL EXPORTER USER ###
#################################
echo_newline "[K8s Entrypoint MySQLd] Initializing MySQL exporter user {{ .Values.mysql.exporter.username }}"

MYSQL_EXPORTER_USER='{{ .Values.mysql.exporter.username }}'
mysql <<EOF
CREATE USER IF NOT EXISTS '${MYSQL_EXPORTER_USER}'@'%'
    IDENTIFIED BY '${MYSQL_EXPORTER_PASSWORD}'
    WITH MAX_USER_CONNECTIONS {{ .Values.mysql.exporter.maxUserConnections }};
GRANT NDB_STORED_USER ON *.* TO '${MYSQL_EXPORTER_USER}'@'%';
GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO '${MYSQL_EXPORTER_USER}'@'%';
FLUSH PRIVILEGES;
EOF
{{- end }}

#########################################
### SETUP GLOBAL REPLICATION SCHEMATA ###
#########################################

HEARTBEAT_DB={{ include "rondb.databases.heartbeat" . }}
HEARTBEAT_TABLE={{ include "rondb.tables.heartbeat" . }}
mysql <<EOF
CREATE DATABASE IF NOT EXISTS ${HEARTBEAT_DB};
CREATE TABLE IF NOT EXISTS ${HEARTBEAT_DB}.${HEARTBEAT_TABLE} (
    server_id INT NOT NULL PRIMARY KEY,
    counter BIGINT UNSIGNED NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) engine NDB;

{{ $ownServerIds := list -}}
{{ range $i := until $maxTotalMySQLds -}}
{{- $serverId := add $serverIdOffset $i }}
INSERT INTO ${HEARTBEAT_DB}.${HEARTBEAT_TABLE} (server_id, counter) VALUES ({{ $serverId }}, 0);
{{- end }}

GRANT ALL PRIVILEGES ON \`${HEARTBEAT_DB}\`.*
    TO '${MYSQL_CLUSTER_USER}'@'%' ;

GRANT SELECT ON mysql.ndb_binlog_index TO '${MYSQL_CLUSTER_USER}'@'%';
GRANT SELECT ON mysql.ndb_apply_status TO '${MYSQL_CLUSTER_USER}'@'%';

-- Allows us to query "SHOW REPLICA STATUS"
GRANT REPLICATION CLIENT ON *.*
    TO '${MYSQL_CLUSTER_USER}'@'%';

GRANT REPLICATION SLAVE ON *.* TO '${MYSQL_CLUSTER_USER}'@'%';
GRANT REPLICATION_SLAVE_ADMIN, RELOAD ON *.* TO '${MYSQL_CLUSTER_USER}'@'%';

FLUSH PRIVILEGES;
EOF

#################################
### SETUP USER-SUPPLIED USERS ###
#################################

{{- range $.Values.mysql.users }}
MY_PW=${{ include "rondb.mysql.getPasswordEnvVarName" . }}
{{- $mysqlUser := printf "'%s'@'%s'" .username .host }}
echo "CREATE USER IF NOT EXISTS {{ $mysqlUser }} IDENTIFIED BY '${MY_PW}';" | mysql
{{- range .privileges }}
{{- $databaseTable := printf "%s.%s" .database .table }}
mysql <<EOF
GRANT {{ .privileges | join ", " }} 
    ON {{ $databaseTable }}
    TO {{ $mysqlUser }}
{{- if .withGrantOption}}
    WITH GRANT OPTION
{{- end }}
;
GRANT NDB_STORED_USER
    ON {{ $databaseTable }}
    TO {{ $mysqlUser }};
FLUSH PRIVILEGES;
EOF
{{- end }}
{{- end }}


###################################
### RUN SQL SCRIPTS FROM BACKUP ###
###################################

# The users.sql will also contain statements such as "CREATE USER `root`@`localhost`.."
SED_CREATE_TABLE="s/CREATE TABLE( IF NOT EXISTS)? /CREATE TABLE IF NOT EXISTS /g"
SED_CREATE_USER="s/CREATE USER( IF NOT EXISTS)? /CREATE USER IF NOT EXISTS /g"

echo_newline "[K8s Entrypoint MySQLd] Running MySQL restore scripts from '$RESTORE_SCRIPTS_DIR' (if available)"
for f in $(find "$RESTORE_SCRIPTS_DIR" -type f -name "*.sql"); do
    case "$f" in
    *.sql)
        echo_newline "[K8s Entrypoint MySQLd] Running $f"
        cat $f | sed -E "$SED_CREATE_TABLE" | sed -E "$SED_CREATE_USER" | mysql
        ;;
    *) echo_newline "[K8s Entrypoint MySQLd] Ignoring $f" ;;
    esac
done

####################################
### RUN USER-DEFINED SQL SCRIPTS ###
####################################

INIT_SCRIPTS_DIR={{ include "rondb.sqlInitScriptsDir" . }}
echo_newline "[K8s Entrypoint MySQLd] Running user-supplied MySQL init-scripts from '$INIT_SCRIPTS_DIR'"
for f in $INIT_SCRIPTS_DIR/*; do
    case "$f" in
    *.sql)
        echo_newline "[K8s Entrypoint MySQLd] Running $f"
        cat $f | sed -E "$SED_CREATE_TABLE" | sed -E "$SED_CREATE_USER" | mysql
        ;;
    *) echo_newline "[K8s Entrypoint MySQLd] Ignoring $f" ;;
    esac
done

#########################
### STOP LOCAL MYSQLD ###
#########################

# When using a local socket, mysqladmin shutdown will only complete when the
# server is actually down.
echo_newline '[K8s Entrypoint MySQLd] Shutting down MySQLd via mysqladmin...'
mysqladmin -uroot --password="$MYSQL_ROOT_PASSWORD" shutdown --socket="$SOCKET"
echo_newline "[K8s Entrypoint MySQLd] Successfully shut down MySQLd"
