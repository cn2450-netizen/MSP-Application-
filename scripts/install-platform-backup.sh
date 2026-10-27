#!/usr/bin/env bash
# Install the daily PLATFORM backup timer (scripts/backup-platform.sh). Run as root, after  backup-platform.sh --init.
#   sudo scripts/install-platform-backup.sh [HH:MM]      default 03:30 (maintenance runs 10:00; the NAS snapshots at 06:00)
# A failed run leaves the service in the "failed" state: systemctl status msp-platform-backup / journalctl -u msp-platform-backup
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $EUID -eq 0 ]] || { echo "run as root (sudo)" >&2; exit 1; }
when="${1:-03:30}"
[[ "$when" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "time must be HH:MM" >&2; exit 2; }
app="$(pwd)"
set -a; source .env; set +a
BK="${BACKUP_DIR:-/srv/msp-backups}"

cat > /etc/systemd/system/msp-platform-backup.service <<UNIT
[Unit]
Description=MSP platform backup (databases, secrets, config)
RequiresMountsFor=${BK} /srv/msp
After=msp-backup-nfs.service docker.service

[Service]
Type=oneshot
WorkingDirectory=${app}
ExecStart=${app}/scripts/backup-platform.sh
Nice=10
IOSchedulingClass=idle
PrivateTmp=true
ProtectHome=true
NoNewPrivileges=true
TimeoutStartSec=3h
UNIT

cat > /etc/systemd/system/msp-platform-backup.timer <<UNIT
[Unit]
Description=Daily MSP platform backup

[Timer]
OnCalendar=*-*-* ${when}:00
Persistent=true

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now msp-platform-backup.timer
systemctl list-timers msp-platform-backup.timer --no-pager | head -3
