# Proxmox LXC Restore

A simple Bash script to automatically restore and restart an LXC container on a Proxmox host.  
The script restores from a fixed backup file, optionally to a specified storage (e.g. a ZFS pool), and logs all actions with timestamps.

---

## Features
- Restores a container from the same backup file every run  
- Optional target storage (e.g. ZFS pool such as `NVMe-Mirror`)  
- Stops and restarts the container automatically  
- Logs all actions with timestamps to `/var/log/lxc-restore.log`  
- Cron-friendly for daily automation  

---

## Example Use Case
Useful for sandbox or test environments (for example, restoring a Moodle sandbox each night) where you want a clean state daily.

---

## Usage

### 1. Copy the script
Save the script as:
```
/root/proxmox-lxc-restore.sh
```

### 2. Edit configuration
Open the script and adjust:
```bash
CTID=YOUR_CONTAINER_ID
BACKUP_FILE="/path/to/vzdump-lxc-YOUR_CONTAINER_ID-YOUR_BACKUP_TIMESTAMP.tar.zst"
STORAGE="YOUR_STORAGE_NAME"   # optional, e.g. "NVMe-Mirror"
LOG_FILE="/var/log/lxc-restore.log"
```

### 3. Make executable
```bash
chmod +x /root/proxmox-lxc-restore.sh
```

### 4. Run manually
```bash
/root/proxmox-lxc-restore.sh
```

### 5. Schedule with cron
```bash
crontab -e
```

To run nightly at 04:00 paste the following into crontab:
```
0 4 * * * /root/proxmox-lxc-restore.sh
```

---

## Log Output
Each run appends to `/var/log/lxc-restore.log`, for example:
```
=== 2025-10-15 04:00:01 ===
Starting restore for container 100
Stopping container 100...
Restoring from /mnt/pve/backup/dump/vzdump-lxc-100-2025_01_01-00_00_00.tar.zst to storage NVMe-Mirror...
Starting container 100...
Restore completed successfully.
```

---

## Notes
- The `--force 1` option ensures existing containers with the same ID are replaced.
- The script is safe to run unattended but should only be used in non-production environments where automatic overwrite is acceptable.
- Designed for Proxmox VE 9.x environments.

---

## License
MIT License — free to use, modify, and share.
