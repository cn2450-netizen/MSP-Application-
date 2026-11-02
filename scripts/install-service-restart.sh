#!/usr/bin/env bash
# Install the timer that runs scripts/service-restart-executor.sh (carries out the console restart-service requests).
# Run as root:   sudo scripts/install-service-restart.sh [MINUTES]   (default 1)
# The service runs as the user who owns this checkout (not root), so generated/ files keep their owner.
# Needs the limited MeshCentral login in generated/mesh-autodeploy-token (scripts/mesh-autodeploy-account.sh create).
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $EUID -eq 0 ]] || { echo "run as root (sudo)" >&2; exit 1; }
every="${1:-1}"
[[ "$every" =~ ^[0-9]{1,3}$ && "$every" -ge 1 ]] || { echo "minutes must be a number" >&2; exit 2; }
app="$(pwd)"; owner="$(stat -c %U "$app/scripts")"

cat > /etc/systemd/system/msp-svcrestart.service <<UNIT
[Unit]
Description=MSP: restart Windows services requested in the console
RequiresMountsFor=/srv/msp
After=docker.service

[Service]
Type=oneshot
User=${owner}
WorkingDirectory=${app}
ExecStart=${app}/scripts/service-restart-executor.sh
Nice=10
PrivateTmp=true
NoNewPrivileges=true
TimeoutStartSec=10min
UNIT

cat > /etc/systemd/system/msp-svcrestart.timer <<UNIT
[Unit]
Description=Check for service restart requests

[Timer]
OnBootSec=5min
OnUnitInactiveSec=${every}min
Persistent=true

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now msp-svcrestart.timer
systemctl list-timers msp-svcrestart.timer --no-pager | head -3
