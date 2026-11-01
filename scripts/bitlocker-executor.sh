#!/usr/bin/env bash
# Carries out BitLocker requests made in the portal (run as root, every minute, from the msp-bitlocker timer:
# scripts/install-bitlocker-executor.sh). One request per run: claims it, runs scripts/bitlocker-run.sh, writes the
# outcome (a short plain message, never a key) back to the request.
set -uo pipefail
cd "$(dirname "$0")/.."
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
psql_portal() { docker compose exec -T postgres psql -U portal -d portal -v ON_ERROR_STOP=1 -X -q -A -t -F $'\t' "$@"; }

exec 9>/run/msp-bitlocker.lock
flock -n 9 || exit 0

# a run that was cut off (host reboot, kill) must not stay "running" for ever
psql_portal -c "UPDATE bitlocker_request SET status = 'failed', message = 'interrupted: try again', finished_at = now() WHERE status = 'running' AND requested_at < now() - interval '40 minutes'" >/dev/null

row="$(psql_portal -c "
  UPDATE bitlocker_request r SET status = 'running'
   WHERE r.id = (SELECT id FROM bitlocker_request WHERE status = 'pending' ORDER BY requested_at LIMIT 1 FOR UPDATE SKIP LOCKED)
  RETURNING r.id, r.customer_slug, r.host, r.volume, r.action")"
[[ -n "$row" ]] || exit 0
IFS=$'\t' read -r id cust host vol action <<<"$row"
if ! [[ "$id" =~ ^[0-9a-f-]{36}$ && "$cust" =~ ^[a-z0-9][a-z0-9-]{1,30}$ && "$host" =~ ^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$ && "$vol" =~ ^[A-Z]$ && "$action" =~ ^(enable|escrow)$ ]]; then
  psql_portal -v id="$id" <<<"UPDATE bitlocker_request SET status = 'failed', message = 'the request holds an unexpected value', finished_at = now() WHERE id = :'id'" >/dev/null 2>&1
  exit 1
fi

echo "bitlocker ${action} ${cust}/${host} ${vol}: (request ${id})"
out="$(timeout 900 scripts/bitlocker-run.sh "$cust" "$host" "$vol" "$action" 2>&1)"; rc=$?
echo "$out"
msg="$(tail -n 3 <<<"$out" | tr '\n' ' ' | tr -cd '[:print:]' | cut -c1-400)"
if (( rc == 0 )); then st=done; else st=failed; fi
psql_portal -v id="$id" -v st="$st" -v m="$msg" <<<"UPDATE bitlocker_request SET status = :'st', message = :'m', finished_at = now() WHERE id = :'id'" >/dev/null
exit $rc
