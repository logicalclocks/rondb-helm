set -e

echo_newline() { echo; echo "$1"; echo; }

###################
# SED MY.CNF FILE #
###################

RAW_MYCNF_FILEPATH={{ include "rondb.dataDir" $ }}/my-raw.cnf
MYCNF_FILEPATH=$RONDB_DATA_DIR/my.cnf
cp $RAW_MYCNF_FILEPATH $MYCNF_FILEPATH

# Take a single empty slot
sed -i "/ndb-cluster-connection-pool/c\# ndb-cluster-connection-pool=1" $MYCNF_FILEPATH
sed -i "/ndb-cluster-connection-pool-nodeids/c\# ndb-cluster-connection-pool-nodeids" $MYCNF_FILEPATH

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
function mysql() { command mysql -uroot -hlocalhost --password="$DUMMY_ROOT_PASSWORD" --protocol=socket --socket="$SOCKET" --init-command="SET @@SESSION.SQL_LOG_BIN=0;"; }

echo_newline '[K8s Entrypoint MySQLd] Changing the root user password'
mysql <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
GRANT NDB_STORED_USER ON *.* TO 'root'@'localhost';
FLUSH PRIVILEGES;
EOF

DUMMY_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD

####################################
### SETUP BENCHMARKING DATABASES ###
####################################

# Benchmarking table; all other tables will be created by the benchmakrs themselves
mysql <<EOF
CREATE DATABASE IF NOT EXISTS \`dbt2\`;
CREATE DATABASE IF NOT EXISTS \`ycsb\`;
EOF

# shellcheck disable=SC2153
if [ "$MYSQL_BENCH_USER" ]; then
    echo_newline "[K8s Entrypoint MySQLd] Initializing benchmarking user $MYSQL_BENCH_USER"

        mysql <<EOF
CREATE USER IF NOT EXISTS '${MYSQL_BENCH_USER}'@'%' IDENTIFIED BY '${MYSQL_BENCH_PASSWORD}';

-- Grant MYSQL_BENCH_USER rights to all benchmarking databases
GRANT NDB_STORED_USER ON *.* TO '${MYSQL_BENCH_USER}'@'%';
GRANT ALL PRIVILEGES ON \`sysbench%\`.* TO '${MYSQL_BENCH_USER}'@'%';
GRANT ALL PRIVILEGES ON \`dbt%\`.* TO '${MYSQL_BENCH_USER}'@'%';
GRANT ALL PRIVILEGES ON \`sbtest%\`.* TO '${MYSQL_BENCH_USER}'@'%';
GRANT ALL PRIVILEGES ON \`ycsb%\`.* TO '${MYSQL_BENCH_USER}'@'%';
EOF
else
    echo_newline '[K8s Entrypoint MySQLd] Not creating benchmark user. MYSQL_BENCH_USER and MYSQL_BENCH_PASSWORD must be specified to do so.'
fi

#################################
### SETUP USER-SUPPLIED USERS ###
#################################

{{- range $.Values.mysql.users }}
MY_PW=${{ include "rondb.mysql.getPasswordEnvVarName" . }}
mysql <<EOF
{{- $username := .username }}
{{- $host := .host }}
CREATE USER IF NOT EXISTS '{{ $username }}'@'{{ $host }}' IDENTIFIED BY '${MY_PW}';
{{- range .privileges }}
{{- $database := .database }}
{{- range $tableName, $privileges := .tables }}
GRANT {{ $privileges | join ", " }} ON {{ $database }}.{{ $tableName }} TO '{{ $username }}'@'{{ $host }}';
GRANT NDB_STORED_USER ON {{ $database }}.{{ $tableName }} TO '{{ $username }}'@'{{ $host }}';
FLUSH PRIVILEGES;
{{- end }}
{{- end }}
EOF
{{- end }}

{{- if .Values.mysql.exporter.enabled }}
####################################
### SETUP MYSQL EXPORTER USER ###
####################################
echo_newline "[K8s Entrypoint MySQLd] Initializing mysql exporter user {{ .Values.mysql.exporter.username }}"
mysql <<EOF
CREATE USER IF NOT EXISTS '{{ .Values.mysql.exporter.username }}'@'%' IDENTIFIED BY '${MYSQL_EXPORTER_PASSWORD}' WITH MAX_USER_CONNECTIONS {{ .Values.mysql.exporter.maxUserConnections }};
GRANT NDB_STORED_USER ON *.* TO '{{ .Values.mysql.exporter.username }}'@'%';
GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO '{{ .Values.mysql.exporter.username }}'@'%';
EOF
{{- end }}

###################################
### RUN SQL SCRIPTS FROM BACKUP ###
###################################

# TODO: Move sedding logic in backup(?)

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
