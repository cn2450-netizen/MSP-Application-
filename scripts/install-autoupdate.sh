#!/usr/bin/env bash
# Install the timer that runs scripts/monitoring-autoupdate.sh (re-installs the monitoring agent on online computers whose
# agent is behind the repository revision, with limits and a manual-attention flag). Run as root:   sudo scripts/install-autoupdate.sh [MINUTES]   (default 10)
# The service runs as the user who owns this checkout (not root), so generated/ files keep their owner.
# Needs its own MeshCentral login token in generated/mesh-autoupdate-token, and the companies to update in
# generated/autoupdate-companies.txt (one slug per line).
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $EUID -eq 0 ]] || { echo "run as root (sudo)" >&2; exit 1; }
every="${1:-10}"
[[ "$every" =~ ^[0-9]{1,3}$ && "$every" -ge 1 ]] || { echo "minutes must be a number" >&2; exit 2; }
app="$(pwd)"; owner="$(stat -c %U "$app/scripts")"

cat > /etc/systemd/system/msp-autoupdate.service <<UNIT
[Unit]
Description=MSP: update the monitoring agent on computers that are behind
RequiresMountsFor=/srv/msp
After=docker.service

[Service]
Type=oneshot
User=${owner}
WorkingDirectory=${app}
ExecStart=${app}/scripts/monitoring-autoupdate.sh
Nice=10
PrivateTmp=true
NoNewPrivileges=true
TimeoutStartSec=50min
UNIT

cat > /etc/systemd/system/msp-autoupdate.timer <<UNIT
[Unit]
Description=Check for monitoring agents that need updating

[Timer]
OnBootSec=5min
OnUnitInactiveSec=${every}min
Persistent=true

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now msp-autoupdate.timer
systemctl list-timers msp-autoupdate.timer --no-pager | head -3
