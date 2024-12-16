# Copyright (c) 2024-2024 Hopsworks AB. All rights reserved.

import argparse
import os
import pymysql

{{- $database := include "rondb.databases.helmTests" . }}

def generate_data(hostname, user, password, sql_scripts_dir):
    connection = pymysql.connect(
        host=hostname,
        user=user,
        password=password,
        # From https://stackoverflow.com/a/55617654/9068781
        ssl={"fake_flag_to_enable_tls": True}
    )
    with connection:
        print(f"Connected to MySQL server at {hostname}")
        with connection.cursor() as cursor:
            cursor.execute("DROP DATABASE IF EXISTS {{ $database }}")
            cursor.execute("CREATE DATABASE {{ $database }}")
            cursor.execute("USE {{ $database }}")
            create_tables(connection, cursor, sql_scripts_dir)
            insert_data(connection, cursor)
            modify_some_data(connection, cursor)
    print("Successfully generated data")


# Create tables for SQL files in directory
def create_tables(connection, cursor, sql_scripts_dir):
    sql_files = os.listdir(sql_scripts_dir)
    sql_files = [f for f in sql_files if f.endswith(".sql")]

    def sort_numerically(file_name):
        # Extract the numerical part from the file name (assuming format 't<number>.sql')
        num_part = file_name.split('.')[0][1:]  # Remove the 't' prefix and the '.sql' suffix
        return int(num_part)

    # Lower table numbers reference higher tables numbers via foreign keys
    #   --> We need to create tables with higher order numbers first
    # TODO: Turn this around (data verification needs to be adjusted as well though)
    sorted_sql_files = sorted(sql_files, key=sort_numerically, reverse=True)
    for filename in sorted_sql_files:
        file_path = os.path.join(sql_scripts_dir, filename)
        if os.path.isfile(file_path):
            with open(file_path, "r") as file:
                sql = file.read()
                commit_query(connection, cursor, sql)


# Create 10 rows in each table
def insert_data(connection, cursor):
    str_suffix = "a" * 480
    for i in range(1, 11):
        sql = (f'INSERT INTO t7 VALUES({i}, {i}, NOW(), "t7_{i}_{str_suffix}");')
        commit_query(connection, cursor, sql)

        sql = (f'INSERT INTO t6 VALUES({i}, {i}, NOW(), "t6_{i}_{str_suffix}");')
        commit_query(connection, cursor, sql)

        sql = (f'INSERT INTO t5 VALUES({i}, {i}, NOW(), "t5_{i}_{str_suffix}");')
        commit_query(connection, cursor, sql)

        sql = f'INSERT INTO t4 VALUES({i}, {i}, "t4_char_{i}", {i}, NOW(), "t4_{i}_{str_suffix}");'
        commit_query(connection, cursor, sql)

        sql = f'INSERT INTO t3 VALUES({i}, {i}, NOW(), "t3_{i}_{str_suffix}", {i});'
        commit_query(connection, cursor, sql)

        sql = f'INSERT INTO t2 VALUES({i}, {i}, NOW(), "t2_{i}_{str_suffix}", {i}, {i});'
        commit_query(connection, cursor, sql)

        sql = f'INSERT INTO t1 VALUES({i}, NOW(), "t1_{i}_{str_suffix}", {i}, {i}, {i}, "t4_char_{i}", {i});'
        commit_query(connection, cursor, sql)


def modify_some_data(connection, cursor):
    # Delete several rows from each table
    for i in range(7, 0, -1):
        delete_sql = f"DELETE FROM t{i} WHERE id = {i};"
        commit_query(connection, cursor, delete_sql)

    for i in range(8, 11):
        # Update VARCHAR column of table t1
        update_sql = f'UPDATE t1 SET str = "{"x" * 460}" where id = {i};'
        commit_query(connection, cursor, update_sql)


################################
## RUN AFTER RESTORING BACKUP ##
################################


def verify_data(hostname, user, password):
    connection = pymysql.connect(
        host=hostname,
        user=user,
        password=password,
        # From https://stackoverflow.com/a/55617654/9068781
        ssl={"fake_flag_to_enable_tls": True}
    )
    with connection:
        with connection.cursor() as cursor:
            cursor.execute("USE {{ $database }}")
            try:
                verify_num_rows(cursor)
                verify_t1(cursor)
            except pymysql.Error as e:
                e.add_note(f"Failed verifying data using {connection}")
                raise
    print("Successfully verified data")


def verify_num_rows(cursor):
    for i in range(1, 8):
        sql = f"SELECT COUNT(*) FROM t{i}"
        cursor.execute(sql)
        result = cursor.fetchone()
        if i >= 4:
            assert result[0] == 9, f"table t{i} has wrong number of rows; expected 9, got {result[0]}"
        elif i == 3:
            assert result[0] == 8, f"table t{i} has wrong number of rows; expected 8, got {result[0]}"
        elif i == 2:
            assert result[0] == 7, f"table t{i} has wrong number of rows; expected 7, got {result[0]}"
        elif i == 1:
            assert result[0] == 3, f"table t{i} has wrong number of rows; expected 3, got {result[0]}"


def verify_t1(cursor):
    sql = "SELECT str FROM t1"
    cursor.execute(sql)
    for _ in range(3):
        result = cursor.fetchone()
        assert result[0] == "x" * 460, "Row 'str' in t1 has not been updated properly"


def commit_query(connection, cursor, sql):
    try:
        cursor.execute(sql)
        connection.commit()
    except pymysql.Error as e:
        connection.rollback()
        connection.close()
        e.add_note(f"Failed running query: {sql}")
        raise

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Run specific functions with database credentials.")
    parser.add_argument('--mysql-hostname', required=True, help='Database hostname')
    parser.add_argument('--mysql-user', required=True, help='MySQL username')
    parser.add_argument('--mysql-password', required=True, help='MySQL password')
    parser.add_argument('--sql-scripts-dir', required=True, help='Directory with MySQL scripts')
    parser.add_argument('--run', choices=['generate-data', 'verify-data'], required=True, help='Function to run')

    args = parser.parse_args()

    print(f"Connecting to database at '{args.mysql_hostname}' with username '{args.mysql_user}'")

    if args.run == 'generate-data':
        generate_data(args.mysql_hostname, args.mysql_user, args.mysql_password, args.sql_scripts_dir)
    elif args.run == 'verify-data':
        verify_data(args.mysql_hostname, args.mysql_user, args.mysql_password)
