#!/usr/bin/env bash
# Install the timer that carries out approved "Replace this computer" requests (scripts/backup-replace-executor.sh). Run as root.
#   sudo scripts/install-backup-replace-executor.sh
# Needs a MeshCentral login token while a request runs (scripts/mesh-token.sh set); without one the request fails with a
# message in the portal and can be retried.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $EUID -eq 0 ]] || { echo "run as root (sudo)" >&2; exit 1; }
app="$(pwd)"
set -a; source .env; set +a
BK="${BACKUP_DIR:-/srv/msp-backups}"

cat > /etc/systemd/system/msp-backup-replace.service <<UNIT
[Unit]
Description=MSP: carry out approved computer replacements
RequiresMountsFor=${BK} /srv/msp
After=msp-backup-nfs.service docker.service

[Service]
Type=oneshot
WorkingDirectory=${app}
ExecStart=${app}/scripts/backup-replace-executor.sh
Nice=10
PrivateTmp=true
ProtectHome=true
NoNewPrivileges=true
TimeoutStartSec=30min
UNIT

cat > /etc/systemd/system/msp-backup-replace.timer <<UNIT
[Unit]
Description=Check for approved computer replacements

[Timer]
OnBootSec=2min
OnUnitInactiveSec=1min
Persistent=true

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now msp-backup-replace.timer
systemctl list-timers msp-backup-replace.timer --no-pager | head -3
