# proxmox-lxc-restore
This script automates the daily restoration of an LXC container (for example, a Moodle sandbox) on a Proxmox host. It stops the container, restores it from a predefined backup, restarts it, and logs all actions with timestamps. Ideal for scheduled resets via cron.
