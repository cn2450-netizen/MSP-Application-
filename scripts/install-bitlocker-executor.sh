#!/usr/bin/env bash
# Install the timer that carries out BitLocker requests from the portal (scripts/bitlocker-executor.sh). Run as root.
#   sudo scripts/install-bitlocker-executor.sh
# Needs a MeshCentral login token while a request runs (scripts/mesh-token.sh set); without one the request fails with a
# message in the portal and can be retried.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $EUID -eq 0 ]] || { echo "run as root (sudo)" >&2; exit 1; }
app="$(pwd)"

cat > /etc/systemd/system/msp-bitlocker.service <<UNIT
[Unit]
Description=MSP: carry out BitLocker requests from the portal
RequiresMountsFor=/srv/msp
After=docker.service

[Service]
Type=oneshot
WorkingDirectory=${app}
ExecStart=${app}/scripts/bitlocker-executor.sh
Nice=10
PrivateTmp=true
ProtectHome=true
NoNewPrivileges=true
TimeoutStartSec=20min
UNIT

cat > /etc/systemd/system/msp-bitlocker.timer <<UNIT
[Unit]
Description=Check for BitLocker requests

[Timer]
OnBootSec=2min
OnUnitInactiveSec=1min
Persistent=true

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now msp-bitlocker.timer
systemctl list-timers msp-bitlocker.timer --no-pager | head -3
