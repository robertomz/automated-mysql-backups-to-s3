#!/bin/bash

set -u

MYSQL_BIN="/usr/bin"
MYSQL_CNF="/etc/mysql-backup/mysql-backup.cnf"
DB_HOST="127.0.0.1"
DB_PORT="3306"

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <s3-uri> <target-database>"
    echo "Example: $0 s3://my-bucket/production/app/app_20260101_010000.sql restore_test"
    exit 1
fi

S3_URI="$1"
TARGET_DB="$2"
RESTORE_FILE="/tmp/${TARGET_DB}_restore_$$.sql"

cleanup() {
    rm -f "$RESTORE_FILE"
}

trap cleanup EXIT

if [ ! -r "$MYSQL_CNF" ]; then
    echo "ERROR: MySQL credentials file is not readable: $MYSQL_CNF"
    exit 1
fi

echo "Downloading backup from S3..."
aws s3 cp "$S3_URI" "$RESTORE_FILE"

if [ $? -ne 0 ] || [ ! -s "$RESTORE_FILE" ]; then
    echo "ERROR: backup download failed or produced an empty file."
    exit 1
fi

echo "Creating target database if needed..."
"$MYSQL_BIN/mysql"     --defaults-extra-file="$MYSQL_CNF"     --host="$DB_HOST"     --port="$DB_PORT"     -e "CREATE DATABASE IF NOT EXISTS \`${TARGET_DB}\`;"

if [ $? -ne 0 ]; then
    echo "ERROR: could not create target database."
    exit 1
fi

echo "Restoring into ${TARGET_DB}..."
"$MYSQL_BIN/mysql"     --defaults-extra-file="$MYSQL_CNF"     --host="$DB_HOST"     --port="$DB_PORT"     "$TARGET_DB" < "$RESTORE_FILE"

if [ $? -ne 0 ]; then
    echo "ERROR: restore failed."
    exit 1
fi

echo "Restore completed successfully."
exit 0
