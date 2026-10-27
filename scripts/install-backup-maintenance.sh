#!/usr/bin/env bash
# Install the daily backup-maintenance timer (prune, integrity check, restore test: scripts/backup-maintain.sh). Run as root.
#   sudo scripts/install-backup-maintenance.sh [HH:MM]      default 10:00 (agents back up 01:00-05:00; the NAS snapshots at 06:00)
# A failed run leaves the service in the "failed" state: systemctl status msp-backup-maintain / journalctl -u msp-backup-maintain
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $EUID -eq 0 ]] || { echo "run as root (sudo)" >&2; exit 1; }
when="${1:-10:00}"
[[ "$when" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "time must be HH:MM" >&2; exit 2; }
app="$(pwd)"
set -a; source .env; set +a
BK="${BACKUP_DIR:-/srv/msp-backups}"

cat > /etc/systemd/system/msp-backup-maintain.service <<UNIT
[Unit]
Description=MSP backup maintenance (prune, integrity check, restore test)
RequiresMountsFor=${BK} /srv/msp
After=msp-backup-nfs.service docker.service

[Service]
Type=oneshot
WorkingDirectory=${app}
ExecStart=${app}/scripts/backup-maintain.sh
Nice=10
IOSchedulingClass=idle
PrivateTmp=true
ProtectHome=true
NoNewPrivileges=true
TimeoutStartSec=6h
UNIT

cat > /etc/systemd/system/msp-backup-maintain.timer <<UNIT
[Unit]
Description=Daily MSP backup maintenance

[Timer]
OnCalendar=*-*-* ${when}:00
Persistent=true

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now msp-backup-maintain.timer
systemctl list-timers msp-backup-maintain.timer --no-pager | head -3
