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
# Defaults below can be overridden in three ways (highest precedence first):
#   1. CLI flags:  --ctid 100 --backup /path/to.tar.zst --storage NVMe --log-file /var/log/x.log
#   2. Env vars:   CTID, BACKUP_FILE, STORAGE, LOG_FILE
#   3. Edit these defaults directly (existing behaviour).
: "${CTID:=YOUR_CONTAINER_ID}"
: "${BACKUP_FILE:=/path/to/vzdump-lxc-YOUR_CONTAINER_ID-YOUR_BACKUP_TIMESTAMP.tar.zst}"
: "${STORAGE:=YOUR_STORAGE_NAME}"
: "${LOG_FILE:=/var/log/lxc-restore.log}"

usage() {
    cat <<EOF
Usage: $0 [--ctid CTID] [--backup PATH] [--storage NAME] [--log-file PATH]

Each option may also be supplied via the corresponding environment variable
(CTID, BACKUP_FILE, STORAGE, LOG_FILE) or by editing the defaults at the top
of the script.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --ctid)        CTID="$2"; shift 2 ;;
        --backup)      BACKUP_FILE="$2"; shift 2 ;;
        --storage)     STORAGE="$2"; shift 2 ;;
        --log-file)    LOG_FILE="$2"; shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# Refuse to run with the placeholder defaults still in place.
if [ "$CTID" = "YOUR_CONTAINER_ID" ] || [ -z "$CTID" ]; then
    echo "ERROR: CTID is not configured. Pass --ctid, set \$CTID, or edit the script." >&2
    exit 2
fi
if [ "$BACKUP_FILE" = "/path/to/vzdump-lxc-YOUR_CONTAINER_ID-YOUR_BACKUP_TIMESTAMP.tar.zst" ]; then
    echo "ERROR: BACKUP_FILE is not configured. Pass --backup, set \$BACKUP_FILE, or edit the script." >&2
    exit 2
fi
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

# Pre-flight: verify the backup archive is structurally valid by listing
# its contents. A corrupted .tar.zst (or truncated download) catches here
# before we destroy the running container.
echo "Verifying backup archive integrity..." >> "$LOG_FILE"
case "$BACKUP_FILE" in
    *.tar.zst|*.tar.gz|*.tar.lzo|*.tar)
        if ! tar -tf "$BACKUP_FILE" >/dev/null 2>>"$LOG_FILE"; then
            echo "ERROR: Backup archive '$BACKUP_FILE' is unreadable or corrupted. Aborting." >> "$LOG_FILE"
            exit 1
        fi
        ;;
    *)
        echo "Skipping integrity check: unrecognised archive extension." >> "$LOG_FILE"
        ;;
esac

# Pre-flight: make sure there is roughly enough free space on the backup
# filesystem to extract the archive. We require the dump directory to
# have at least 2x the compressed size free, which is conservative for
# typical compression ratios. This is a heuristic; pct restore will still
# do its own checks against the target storage.
backup_dir=$(dirname -- "$BACKUP_FILE")
backup_bytes=$(stat -c '%s' "$BACKUP_FILE" 2>/dev/null || echo 0)
required_bytes=$((backup_bytes * 2))
free_kib=$(df -P -k "$backup_dir" | awk 'NR==2 {print $4}')
free_bytes=$((free_kib * 1024))
if [ "$free_bytes" -lt "$required_bytes" ]; then
    echo "ERROR: Only ${free_bytes} bytes free on $backup_dir but ~${required_bytes} needed (2x backup size). Aborting." >> "$LOG_FILE"
    exit 1
fi

# Stop container
echo "Stopping container $CTID..." >> "$LOG_FILE"
if ! pct stop "$CTID" >> "$LOG_FILE" 2>&1; then
    echo "ERROR: pct stop failed for $CTID. Aborting." >> "$LOG_FILE"
    exit 1
fi

# Confirm the container is actually stopped before doing a destructive
# --force restore. `pct status` prints something like "status: stopped".
ct_status=$(pct status "$CTID" 2>>"$LOG_FILE" | awk '{print $2}')
if [ "$ct_status" != "stopped" ]; then
    echo "ERROR: Container $CTID is in state '$ct_status' after pct stop; refusing to --force restore." >> "$LOG_FILE"
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
