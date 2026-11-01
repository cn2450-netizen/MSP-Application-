#!/usr/bin/env bash
# Create the portal's READ-ONLY InfluxDB token (secrets/portal_influx_token) so the Computers page can read the
# monitoring data directly. It can read every bucket in the org (including customers added later) and write nothing.
# Safe to re-run: an existing token file is kept.
set -euo pipefail
cd "$(dirname "$0")/.."
f=secrets/portal_influx_token
if [[ -s "$f" ]]; then echo "keep   $f"; exit 0; fi
tok="$(docker compose exec -T influxdb sh -c 'influx auth create --org msp --read-buckets --description "portal (read-only)" --json --token "$(cat /run/secrets/influx_admin_token)"' | jq -r '.token')"
[[ -n "$tok" && "$tok" != null ]] || { echo "could not create the token" >&2; exit 1; }
( umask 077; printf '%s\n' "$tok" > "$f" ); chmod 644 "$f"      # 644 like the other secrets: Docker bind-mounts it for the portal's user
echo "create $f"
