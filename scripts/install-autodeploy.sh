#!/usr/bin/env bash
# Install the timer that runs scripts/monitoring-autodeploy.sh (monitoring agent for any online computer that has the
# MeshCentral agent but no monitoring). Run as root:   sudo scripts/install-autodeploy.sh [MINUTES]   (default 10)
# The service runs as the user who owns this checkout (not root), so generated/ files keep their owner.
# Needs the limited MeshCentral login: scripts/mesh-autodeploy-account.sh create
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $EUID -eq 0 ]] || { echo "run as root (sudo)" >&2; exit 1; }
every="${1:-10}"
[[ "$every" =~ ^[0-9]{1,3}$ && "$every" -ge 1 ]] || { echo "minutes must be a number" >&2; exit 2; }
app="$(pwd)"; owner="$(stat -c %U "$app/scripts")"

cat > /etc/systemd/system/msp-autodeploy.service <<UNIT
[Unit]
Description=MSP: install monitoring on computers that have the remote agent but no monitoring
RequiresMountsFor=/srv/msp
After=docker.service

[Service]
Type=oneshot
User=${owner}
WorkingDirectory=${app}
ExecStart=${app}/scripts/monitoring-autodeploy.sh
Nice=10
PrivateTmp=true
NoNewPrivileges=true
TimeoutStartSec=40min
UNIT

cat > /etc/systemd/system/msp-autodeploy.timer <<UNIT
[Unit]
Description=Check for computers without monitoring

[Timer]
OnBootSec=5min
OnUnitInactiveSec=${every}min
Persistent=true

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now msp-autodeploy.timer
systemctl list-timers msp-autodeploy.timer --no-pager | head -3
