#!/bin/bash

# Copyright (c) 2024-2024 Hopsworks AB. All rights reserved.

set -e

BACKUP_DIR=$1
echo "Using backup directory: $BACKUP_DIR"

mkdir -p $BACKUP_DIR

MYSQL_AUTH="--user=root \
            -p${MYSQL_ROOT_PASSWORD}"

####################
### BACKUP USERS ###
####################

## WHY BACKUP USERS?
#
# By default, ndb_restore does not support restoring users.
# One could activate it - however, if one wants to overwrite user passwords,
# it can be helpful to restore users after one has initialized new user
# passwords.

# Excluding the users is not absolutely necessary, since we sed IF NOT EXISTS
# into the restore SQL files.

# Backup users; match all database names
mysqlpump \
    $MYSQL_AUTH \
    --exclude-databases=% \
    --exclude-users=root,mysql.sys,mysql.session,mysql.infoschema \
    --users \
    >$BACKUP_DIR/users.sql

########################
### BACKUP DATABASES ###
########################

{{ $databases := (include "rondb.databases.benchmarking" $) | fromYamlArray -}}
HELM_DATABASES=({{ join " " $databases }})

# Get all databases
BACKUP_BLACKLIST_DATABASES=('mysql' 'information_schema' 'performance_schema' 'sys' 'ndbinfo' 'users')
BACKUP_BLACKLIST_DATABASES+=("${HELM_DATABASES[@]}")
blacklist_sql="'$(
    IFS=','
    echo "${BACKUP_BLACKLIST_DATABASES[*]}" | sed "s/,/', '/g"
)'"
QUERY="SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN ($blacklist_sql)"
NON_BLACKLISTED_DATABASES=$(mysql $MYSQL_AUTH -NBe "$QUERY")
echo "Databases to back up: $NON_BLACKLISTED_DATABASES"

# mysqldump creates a logical backup: it reproduces table structure and data,
# without copying the actual data files.
mysqldump \
    $MYSQL_AUTH \
    --no-data \
    --skip-add-drop-table \
    --triggers \
    --routines \
    --events \
    --databases $NON_BLACKLISTED_DATABASES \
    >$BACKUP_DIR/databases.sql
