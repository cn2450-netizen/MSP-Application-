#!/usr/bin/env bash
# Carries out replacement requests that a second person has approved in the portal (run as root, every minute, from
# the msp-backup-replace timer: scripts/install-backup-replace-executor.sh). One request per run.
# The portal never holds backup credentials, so this is where the work happens: it claims an approved request, runs
# scripts/backup-replace-machine.sh, and writes the outcome (a few plain lines, no secrets) back to the request.
set -uo pipefail
cd "$(dirname "$0")/.."
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
psql_portal() { docker compose exec -T postgres psql -U portal -d portal -v ON_ERROR_STOP=1 -X -q -A -t -F $'\t' "$@"; }

exec 9>/run/msp-backup-replace.lock
flock -n 9 || exit 0

# a run that was cut off (host reboot, kill) must not stay "running" for ever
psql_portal -c "UPDATE replacement SET status = 'failed', message = 'interrupted: try again', finished_at = now() WHERE status = 'running' AND decided_at < now() - interval '40 minutes'" >/dev/null

row="$(psql_portal -c "
  UPDATE replacement r SET status = 'running'
   WHERE r.id = (SELECT id FROM replacement WHERE status = 'approved' ORDER BY requested_at LIMIT 1 FOR UPDATE SKIP LOCKED)
  RETURNING r.id, r.new_device, (SELECT customer_slug FROM machine WHERE id = r.machine_id), (SELECT site_slug FROM machine WHERE id = r.machine_id), (SELECT name FROM machine WHERE id = r.machine_id)")"
[[ -n "$row" ]] || exit 0
IFS=$'\t' read -r id dev cust site old <<<"$row"
if ! [[ "$id" =~ ^[0-9a-f-]{36}$ && "$dev" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,28}[A-Za-z0-9])?$ && "$cust" =~ ^[a-z0-9][a-z0-9-]{1,30}$ && "$site" =~ ^[a-z0-9][a-z0-9-]{0,30}$ && "$old" =~ ^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$ ]]; then
  psql_portal -v id="$id" <<<"UPDATE replacement SET status = 'failed', message = 'the request holds an unexpected value', finished_at = now() WHERE id = :'id'" >/dev/null 2>&1
  exit 1
fi

echo "replacing ${cust}/${site}/${old} with ${dev} (request ${id})"
out="$(timeout 1500 scripts/backup-replace-machine.sh "$cust" "$site" "$old" "$dev" 2>&1)"; rc=$?
echo "$out"
msg="$(tail -n 4 <<<"$out" | tr '\n' ' ' | tr -cd '[:print:]' | cut -c1-400)"
if (( rc == 0 )); then st=done; else st=failed; fi
psql_portal -v id="$id" -v st="$st" -v m="$msg" <<<"UPDATE replacement SET status = :'st', message = :'m', finished_at = now() WHERE id = :'id'" >/dev/null
exit $rc
