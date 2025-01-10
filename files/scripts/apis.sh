#!/bin/bash

# Copyright (c) 2024-2025 Hopsworks AB. All rights reserved.

until nslookup $MGMD_HOSTNAME; do
    echo "Waiting for $MGMD_HOSTNAME to be resolvable..."
    sleep $(((RANDOM % 2) + 2))
done

until nslookup $MYSQLD_SERVICE_HOSTNAME; do
    echo "Waiting for $MYSQLD_SERVICE_HOSTNAME to be resolvable..."
    sleep $(((RANDOM % 2) + 2))
done

while true; do
    mysql \
        -h $MYSQLD_SERVICE_HOSTNAME \
        --protocol=tcp \
        --port=3306 \
        --connect-timeout=2 \
        --user=$MYSQL_CLUSTER_USER \
        -p"$MYSQL_CLUSTER_PASSWORD" \
        -e "SELECT 1;"

    if [ $? -eq 0 ]; then
        echo "Successfully connected to MySQL server"
        break
    fi
    echo "MySQL query failed, retrying in a bit..."
    sleep 2
done
