#!/usr/bin/env bash

# Copyright (c) 2024-2025 Hopsworks AB. All rights reserved.



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

echo_newline "[K8s Entrypoint MySQLd] Running MySQLd as background-process in socket-only mode for initialization"
(
    set -x
    "${CMD[@]}" \
        --log-error-verbosity=3 \
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

function _mysql() {
  command mysql -hlocalhost -uroot --socket="$SOCKET" --protocol=socket --password=$MYSQL_ROOT_PASSWORD "$@"
}

###############
## IMPORTANT ##
###############
## Run this function BEFORE upgrading to RonDB 24.10

## Revoke the problematic SET_USER_ID from users
function _revoke_privilege() {
  echo "Revoking SET_USER_ID privilege"
  grantees=$(_mysql -Nse 'SELECT GRANTEE FROM information_schema.user_privileges WHERE PRIVILEGE_TYPE = "SET_USER_ID"')
  for g in $grantees; do
    echo "Revoking privilege from $g"
    _mysql -se 'REVOKE IF EXISTS "SET_USER_ID" ON *.* FROM '"$g"
    echo "Revoked privilege from $g"
  done
  echo "Finished revoking privilege"
}

###############
## IMPORTANT ##
###############
## Run this function AFTER upgrading to RonDB 24.10

## Run GRANT ALL again to users with ROLE_ADMIN privilege to grant all 24.10 privileges
function _grant_all_privileges() {
  echo "Granting ALL privileges to admin users"
  grantees=$(_mysql -Nse 'SELECT GRANTEE FROM information_schema.user_privileges WHERE PRIVILEGE_TYPE = "ROLE_ADMIN"')
  for g in $grantees; do
    # check if they have already been granted
    # this is a new privilege introduced in 24.10 If they have this privilege it means we have run this job before
    p=$(_mysql -Nse 'SELECT GRANTEE FROM information_schema.user_privileges WHERE PRIVILEGE_TYPE = "SET_ANY_DEFINER" AND GRANTEE = "$g"')
    pt=$(echo $p | tr -d '[:space:]')
    if [ -z "$pt" ]; then
        echo "Granting ALL privileges at $g"
        _mysql -se 'GRANT ALL ON *.* TO '"$g"' WITH GRANT OPTION'
        echo "Granted ALL privileges at $g"
    fi
  done
  echo "Finished granting ALL privileges"
}
