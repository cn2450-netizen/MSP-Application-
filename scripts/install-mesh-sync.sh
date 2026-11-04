#!/usr/bin/env bash
# Install the timer that runs scripts/mesh-sync-nodes.sh (MeshCentral ids and online state for the console's Connect links).
# Run as root:   sudo scripts/install-mesh-sync.sh [MINUTES]   (default 1)
# Runs as the user who owns this checkout. Needs the limited MeshCentral login: scripts/mesh-autodeploy-account.sh create
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $EUID -eq 0 ]] || { echo "run as root (sudo)" >&2; exit 1; }
every="${1:-1}"
[[ "$every" =~ ^[0-9]{1,3}$ && "$every" -ge 1 ]] || { echo "minutes must be a number" >&2; exit 2; }
app="$(pwd)"; owner="$(stat -c %U "$app/scripts")"

cat > /etc/systemd/system/msp-mesh-sync.service <<UNIT
[Unit]
Description=MSP: copy MeshCentral computer ids and online state to the portal
RequiresMountsFor=/srv/msp
After=docker.service

[Service]
Type=oneshot
User=${owner}
WorkingDirectory=${app}
ExecStart=${app}/scripts/mesh-sync-nodes.sh
Nice=10
PrivateTmp=true
NoNewPrivileges=true
TimeoutStartSec=5min
UNIT

cat > /etc/systemd/system/msp-mesh-sync.timer <<UNIT
[Unit]
Description=Refresh MeshCentral computer state

[Timer]
OnBootSec=2min
OnUnitInactiveSec=${every}min

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now msp-mesh-sync.timer
systemctl list-timers msp-mesh-sync.timer --no-pager | head -3
