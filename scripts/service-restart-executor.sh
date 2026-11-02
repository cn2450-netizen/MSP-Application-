#!/usr/bin/env bash
# Carries out "restart this service" requests made in the console, one per run, through MeshCentral. Run every minute by
# the msp-svcrestart timer (scripts/install-service-restart.sh); fine by hand too.
# A request for a computer that is off waits and is retried every 5 minutes for up to a day.
# Credentials: the limited MeshCentral account in generated/mesh-autodeploy-token (scripts/mesh-autodeploy-account.sh).
# Never restartable: the monitoring agent's own service (MSPAgent), whatever the console sent.
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
TOKEN=generated/mesh-autodeploy-token
[[ -s "$TOKEN" ]] || { echo "no MeshCentral token ($TOKEN): nothing done" >&2; exit 0; }
export MESH_TOKEN_USER="$(sed -n 1p "$TOKEN")" MESH_TOKEN_PASS="$(sed -n 2p "$TOKEN")"
source scripts/lib/meshcentral.sh
psql_portal() { docker compose exec -T postgres psql -U portal -d portal -v ON_ERROR_STOP=1 -X -q -A -t -F $'\t' "$@"; }
lock=/run/user/$(id -u)/msp-svcrestart.lock; [[ -w "${lock%/*}" ]] || lock=/tmp/msp-svcrestart.lock
exec 9>"$lock"
flock -n 9 || exit 0

# a run that was cut off must not stay "running" for ever
psql_portal -c "UPDATE service_restart SET status = 'failed', message = 'interrupted: try again', finished_at = now() WHERE status = 'running' AND COALESCE(last_try, requested_at) < now() - interval '15 minutes'" >/dev/null

row="$(psql_portal -c "
  UPDATE service_restart r SET status = 'running', last_try = now()
   WHERE r.id = (SELECT id FROM service_restart WHERE status = 'pending' AND (last_try IS NULL OR last_try < now() - interval '5 minutes')
                  ORDER BY last_try NULLS FIRST, requested_at LIMIT 1 FOR UPDATE SKIP LOCKED)
  RETURNING r.id, r.customer_slug, r.host, r.service_name")"
[[ -n "$row" ]] || exit 0
IFS=$'\t' read -r id cust host svc <<<"$row"
fail() { psql_portal -v id="$id" -v m="$1" <<<"UPDATE service_restart SET status = 'failed', message = :'m', finished_at = now() WHERE id = :'id'" >/dev/null; echo "restart ${cust}/${host} ${svc}: $1"; exit 1; }
svc_re='^[A-Za-z0-9 ._()$#+/:@-]{1,120}$'      # the monitoring data names services by display name; anything stranger is refused
if ! [[ "$id" =~ ^[0-9a-f-]{36}$ && "$cust" =~ ^[a-z0-9][a-z0-9-]{1,30}$ && "$host" =~ ^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$ && "$svc" =~ $svc_re ]]; then fail "the request holds an unexpected value"; fi
[[ "${svc,,}" == mspagent || "${svc,,}" == "msp monitoring agent" ]] && fail "the monitoring agent's own service is never restarted from here"

wait_again() {   # computer off: keep the request, retry later, give up after a day
  psql_portal -v id="$id" -v m="Waiting: $1" <<<"UPDATE service_restart SET status = CASE WHEN requested_at < now() - interval '1 day' THEN 'failed' ELSE 'pending' END, message = CASE WHEN requested_at < now() - interval '1 day' THEN 'Gave up after a day. ' || :'m' ELSE :'m' END, finished_at = CASE WHEN requested_at < now() - interval '1 day' THEN now() END WHERE id = :'id'" >/dev/null
  echo "restart ${cust}/${host} ${svc}: waiting ($1)"; exit 0
}
mesh_login 2>/dev/null || wait_again "the MeshCentral login is not working; it will be retried"

dev=""
while IFS= read -r g; do
  [[ -z "$g" ]] && continue
  dev="$(mc ListDevices --group "$g" --json | jq -r --arg n "$host" '[.[]|select(((.conn // 0) % 2) == 1 and (((.rname // .name)|ascii_downcase)==$n or (.name|ascii_downcase)==$n))]|.[0]._id // empty' 2>/dev/null)"
  [[ -n "$dev" ]] && break
done < <(mc ListDeviceGroups --json | jq -r --arg p "${cust} / " '.[]|select(.name|startswith($p))|.name')
[[ -n "$dev" ]] || wait_again "${host} is not online in MeshCentral"

# PowerShell single quotes around the name (validated above), cmd double quotes around the whole command
# The name may be the short service name or the display name, so look it up by either.
ps="try { \$sv = Get-Service | Where-Object { \$_.Name -eq '${svc}' -or \$_.DisplayName -eq '${svc}' } | Select-Object -First 1; if (-not \$sv) { throw 'service not found' }; if (\$sv.Name -eq 'MSPAgent') { throw 'the monitoring agent is never restarted from here' }; Restart-Service -InputObject \$sv -Force -ErrorAction Stop; \$sv.Refresh(); Write-Output ('MSP-SVC-RESULT|ok|' + \$sv.Status) } catch { Write-Output ('MSP-SVC-RESULT|fail|' + \$_.Exception.Message) }"
reply="$(timeout 240 docker compose exec -T meshcentral node "$MESH_CTL" RunCommand --id "$dev" --reply \
  --run "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \"${ps}\"" \
  --url ws://127.0.0.1:4430 --loginuser "$MESH_USER" --loginpass "$MESH_PASS" </dev/null 2>&1 | tr -d '\r' || true)"
result="$(grep -E '^MSP-SVC-RESULT\|' <<<"$reply" | tail -1)"
grep -qi "access denied" <<<"$reply" && wait_again "the MeshCentral account is not allowed to run commands yet (scripts/mesh-autodeploy-account.sh grant)"
[[ -n "$result" ]] || wait_again "no answer from ${host} (it may have gone offline)"
state="$(cut -d'|' -f2 <<<"$result")"; text="$(cut -d'|' -f3- <<<"$result" | tr -cd '[:print:]' | cut -c1-300)"
if [[ "$state" == ok && "${text,,}" == running ]]; then
  psql_portal -v id="$id" <<<"UPDATE service_restart SET status = 'done', message = 'Restarted; it is running.', finished_at = now() WHERE id = :'id'" >/dev/null
  echo "restart ${cust}/${host} ${svc}: done"; exit 0
fi
fail "${text:-the computer reported an error}"
