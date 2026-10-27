#!/usr/bin/env bash
# Install the timer that keeps the portal's backup catalog current (scripts/backup-catalog.sh). Run as root.
#   sudo scripts/install-backup-catalog.sh [MINUTES]      default every 5 minutes
# A run with nothing new costs one cheap "restic snapshots" call per machine. systemctl status msp-backup-catalog
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $EUID -eq 0 ]] || { echo "run as root (sudo)" >&2; exit 1; }
every="${1:-5}"
[[ "$every" =~ ^[0-9]{1,3}$ && "$every" -ge 1 ]] || { echo "minutes must be a number" >&2; exit 2; }
app="$(pwd)"
set -a; source .env; set +a
BK="${BACKUP_DIR:-/srv/msp-backups}"

cat > /etc/systemd/system/msp-backup-catalog.service <<UNIT
[Unit]
Description=MSP backup catalog (what each backup contains, for the portal)
RequiresMountsFor=${BK} /srv/msp
After=msp-backup-nfs.service docker.service

[Service]
Type=oneshot
WorkingDirectory=${app}
ExecStart=${app}/scripts/backup-catalog.sh
Nice=10
IOSchedulingClass=idle
PrivateTmp=true
ProtectHome=true
NoNewPrivileges=true
TimeoutStartSec=4h
UNIT

cat > /etc/systemd/system/msp-backup-catalog.timer <<UNIT
[Unit]
Description=Keep the MSP backup catalog current

[Timer]
OnBootSec=3min
OnUnitInactiveSec=${every}min
Persistent=true

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now msp-backup-catalog.timer
systemctl list-timers msp-backup-catalog.timer --no-pager | head -3
