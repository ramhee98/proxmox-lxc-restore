#!/bin/bash
# Script to restore and restart an LXC container on a Proxmox host
# Always restores from the same backup file
# Logs all actions with timestamps

# Ensure full path for cron
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# Abort on any failed command in a pipeline so partial restores can't go
# undetected (the previous version logged failures and kept going).
set -o pipefail

# When this script is run from cron the only thing the operator typically
# sees is whatever lands on stderr (cron emails it). Print a clear summary
# there on any non-zero exit so failures surface immediately instead of
# being buried in the log file.
on_failure() {
    local exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        echo "lxc-restore FAILED (exit $exit_code) for CTID=${CTID:-?}; see ${LOG_FILE:-/var/log/lxc-restore.log}" >&2
    fi
}
trap on_failure EXIT

# Configuration
CTID=YOUR_CONTAINER_ID
BACKUP_FILE="/path/to/vzdump-lxc-YOUR_CONTAINER_ID-YOUR_BACKUP_TIMESTAMP.tar.zst" # e.g. "/var/lib/vz/dump/vzdump-lxc-100-2025_01_01-00_00_00.tar.zst"
STORAGE="YOUR_STORAGE_NAME"    # optional, e.g. "NVMe-Mirror"
LOG_FILE="/var/log/lxc-restore.log"
LOG_MAX_BYTES=$((10 * 1024 * 1024))   # 10 MB
LOG_KEEP_BACKUPS=5                     # how many .log.N files to keep

# Lightweight built-in log rotation: when the log exceeds LOG_MAX_BYTES,
# shift .4 → .5, .3 → .4, ... and start a fresh log. Avoids relying on a
# system logrotate config (the script may run on hosts without one).
rotate_log_if_needed() {
    [ -f "$LOG_FILE" ] || return 0
    local size
    size=$(stat -c '%s' "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$size" -gt "$LOG_MAX_BYTES" ]; then
        local i
        for ((i=LOG_KEEP_BACKUPS-1; i>=1; i--)); do
            [ -f "${LOG_FILE}.${i}" ] && mv -f "${LOG_FILE}.${i}" "${LOG_FILE}.$((i+1))"
        done
        mv -f "$LOG_FILE" "${LOG_FILE}.1"
        : > "$LOG_FILE"
    fi
}
rotate_log_if_needed

# Timestamp for the log
echo "=== $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$LOG_FILE"
echo "Starting restore for container $CTID" >> "$LOG_FILE"

# Verify the backup file is actually present and readable before doing
# anything destructive (stopping the container).
if [ ! -f "$BACKUP_FILE" ]; then
    echo "ERROR: Backup file '$BACKUP_FILE' not found. Aborting." >> "$LOG_FILE"
    exit 1
fi
if [ ! -r "$BACKUP_FILE" ]; then
    echo "ERROR: Backup file '$BACKUP_FILE' exists but is not readable. Aborting." >> "$LOG_FILE"
    exit 1
fi

# Stop container
echo "Stopping container $CTID..." >> "$LOG_FILE"
if ! pct stop "$CTID" >> "$LOG_FILE" 2>&1; then
    echo "ERROR: pct stop failed for $CTID. Aborting." >> "$LOG_FILE"
    exit 1
fi

# Restore container to specific storage (if provided)
echo "Restoring from $BACKUP_FILE to storage $STORAGE..." >> "$LOG_FILE"
if ! pct restore "$CTID" "$BACKUP_FILE" --force 1 --storage "$STORAGE" >> "$LOG_FILE" 2>&1; then
    echo "ERROR: pct restore failed for $CTID from $BACKUP_FILE. Aborting." >> "$LOG_FILE"
    exit 1
fi

# Start container
echo "Starting container $CTID..." >> "$LOG_FILE"
if ! pct start "$CTID" >> "$LOG_FILE" 2>&1; then
    echo "ERROR: pct start failed for $CTID after restore." >> "$LOG_FILE"
    exit 1
fi

# Finish
echo "Restore completed successfully." >> "$LOG_FILE"
echo "" >> "$LOG_FILE"
