#!/bin/bash
# Script to restore and restart an LXC container on a Proxmox host
# Always restores from the same backup file
# Logs all actions with timestamps

# Ensure full path for cron
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# Configuration
CTID=YOUR_CONTAINER_ID
BACKUP_FILE="/path/to/vzdump-lxc-YOUR_CONTAINER_ID-YOUR_BACKUP_TIMESTAMP.tar.zst" # e.g. "/var/lib/vz/dump/vzdump-lxc-100-2025_01_01-00_00_00.tar.zst"
STORAGE="YOUR_STORAGE_NAME"    # optional, e.g. "NVMe-Mirror"
LOG_FILE="/var/log/lxc-restore.log"

# Timestamp for the log
echo "=== $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$LOG_FILE"
echo "Starting restore for container $CTID" >> "$LOG_FILE"

# Stop container
echo "Stopping container $CTID..." >> "$LOG_FILE"
pct stop "$CTID" >> "$LOG_FILE" 2>&1

# Restore container to specific storage (if provided)
echo "Restoring from $BACKUP_FILE to storage $STORAGE..." >> "$LOG_FILE"
pct restore "$CTID" "$BACKUP_FILE" --force 1 --storage "$STORAGE" >> "$LOG_FILE" 2>&1

# Start container
echo "Starting container $CTID..." >> "$LOG_FILE"
pct start "$CTID" >> "$LOG_FILE" 2>&1

# Finish
echo "Restore completed successfully." >> "$LOG_FILE"
echo "" >> "$LOG_FILE"
