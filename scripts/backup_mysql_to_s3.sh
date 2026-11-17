#!/bin/bash

set -u

MYSQL_BIN="/usr/bin"
MYSQL_CNF="/etc/mysql-backup/mysql-backup.cnf"

DB_HOST="127.0.0.1"
DB_PORT="3306"
DB_NAME="example_database"

S3_BUCKET="YOUR_BACKUP_BUCKET"
S3_PREFIX="production/${DB_NAME}"

BACKUP_DIR="/var/backups/mysql"
LOG_DIR="/var/log/mysql-backup"

TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
DUMP_FILE="${BACKUP_DIR}/${DB_NAME}_${TIMESTAMP}.sql"
LOG_FILE="${LOG_DIR}/backup.log"
S3_URI="s3://${S3_BUCKET}/${S3_PREFIX}/$(basename "$DUMP_FILE")"

mkdir -p "$BACKUP_DIR" "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

cleanup() {
    if [ -f "$DUMP_FILE" ]; then
        rm -f "$DUMP_FILE"
    fi
}

trap cleanup EXIT

log "============================================================"
log "Starting MySQL backup"
log "Database: $DB_NAME"
log "Source: $DB_HOST:$DB_PORT"
log "Destination: s3://$S3_BUCKET/$S3_PREFIX/"
log "============================================================"

if [ ! -r "$MYSQL_CNF" ]; then
    log "ERROR: MySQL credentials file is not readable: $MYSQL_CNF"
    exit 1
fi

log "Generating dump..."

"$MYSQL_BIN/mysqldump" \
    --defaults-extra-file="$MYSQL_CNF" \
    --host="$DB_HOST" \
    --port="$DB_PORT" \
    --single-transaction \
    --quick \
    --skip-lock-tables \
    --routines \
    --triggers \
    --events \
    "$DB_NAME" \
    > "$DUMP_FILE" \
    2>> "$LOG_FILE"

DUMP_EXIT=$?

if [ "$DUMP_EXIT" -ne 0 ]; then
    log "ERROR: mysqldump returned exit code $DUMP_EXIT."
    log "Review the log before retrying."
    exit 1
fi

if [ ! -s "$DUMP_FILE" ]; then
    log "ERROR: dump file is empty."
    exit 1
fi

DUMP_SIZE=$(du -h "$DUMP_FILE" | awk '{print $1}')
log "Dump generated successfully: $DUMP_SIZE"

log "Uploading backup to S3..."

aws s3 cp "$DUMP_FILE" "$S3_URI" >> "$LOG_FILE" 2>&1
UPLOAD_EXIT=$?

if [ "$UPLOAD_EXIT" -ne 0 ]; then
    log "ERROR: S3 upload failed with exit code $UPLOAD_EXIT."
    exit 1
fi

log "Verifying object in S3..."

aws s3api head-object \
    --bucket "$S3_BUCKET" \
    --key "${S3_PREFIX}/$(basename "$DUMP_FILE")" \
    >> "$LOG_FILE" 2>&1

VERIFY_EXIT=$?

if [ "$VERIFY_EXIT" -ne 0 ]; then
    log "ERROR: upload command succeeded, but S3 object verification failed."
    exit 1
fi

log "Backup uploaded and verified successfully."
log "S3 object: $S3_URI"
log "Temporary dump will now be removed."
log "Backup completed successfully."

exit 0
