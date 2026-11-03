#!/usr/bin/env bash
# Run BitLocker management on one PC through MeshCentral and save any recovery keys it reports (encrypted) in the portal.
#   scripts/bitlocker-run.sh <customer> <computer> <drive-letter> enable|escrow
# Used by scripts/bitlocker-executor.sh for portal requests; also fine by hand. Needs the automation account's login
# (generated/mesh-autodeploy-token) or a MeshCentral login token (scripts/mesh-token.sh set), and the portal database. Prints a one-line outcome; recovery keys are never printed or logged.
# Exit: 0 ok, 1 the PC reported a problem, 3 not possible right now (computer off / no Mesh token: the worker retries later).
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
source scripts/lib/meshcentral.sh

cust="${1:?usage: bitlocker-run.sh <customer> <computer> <drive-letter> enable|escrow}"
host="${2:?computer required}"; vol="${3:?drive letter required}"; action="${4:?enable|escrow}"
[[ "$cust" =~ ^[a-z0-9][a-z0-9-]{1,30}$ ]] || { echo "invalid customer"; exit 2; }
[[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,62}[A-Za-z0-9])?$ ]] || { echo "invalid computer name"; exit 2; }
[[ "$vol" =~ ^[A-Za-z]$ ]] || { echo "invalid drive letter"; exit 2; }
[[ "$action" == enable || "$action" == escrow ]] || { echo "action must be enable or escrow"; exit 2; }
vol="${vol^^}"; hostl="${host,,}"
mode=Enable; [[ "$action" == escrow ]] && mode=Escrow
keyfile=secrets/bitlocker_escrow_key
[[ -s "$keyfile" ]] || { echo "missing $keyfile: run scripts/init-secrets.sh"; exit 1; }
pass="$(cat "$keyfile")"
[[ "$pass" =~ ^[0-9a-f]+$ ]] || { echo "unexpected characters in $keyfile"; exit 1; }

# Signs in as the limited automation account (generated/mesh-autodeploy-token, rights: scripts/mesh-autodeploy-account.sh);
# a hand-made token (scripts/mesh-token.sh set) is only the fallback when that login is missing or refused.
if [[ -s generated/mesh-autodeploy-token ]]; then
  MESH_TOKEN_USER="$(sed -n 1p generated/mesh-autodeploy-token)" MESH_TOKEN_PASS="$(sed -n 2p generated/mesh-autodeploy-token)"
  export MESH_TOKEN_USER MESH_TOKEN_PASS
fi
mesh_login 2>/dev/null || { unset MESH_TOKEN_USER MESH_TOKEN_PASS; mesh_login 2>/dev/null; } || { echo "MeshCentral login missing or expired: scripts/mesh-autodeploy-account.sh status, or create a login token (My Account -> Create login token) and run scripts/mesh-token.sh set, then try again"; exit 3; }

# the device: online, in any of this customer's device groups ("<customer> / <site>"), matched by computer name
id=""
while IFS= read -r g; do
  [[ -z "$g" ]] && continue
  id="$(mc ListDevices --group "$g" --json | jq -r --arg n "$hostl" '[.[]|select(((.conn // 0) % 2) == 1 and ((.name|ascii_downcase)==$n))]|.[0]._id // empty' 2>/dev/null)"
  [[ -n "$id" ]] && break
done < <(mc ListDeviceGroups --json | jq -r --arg p "${cust} / " '.[]|select(.name|startswith($p))|.name')
[[ -n "$id" ]] || { echo "${host} is not online in MeshCentral (device groups '${cust} / ...'): it must be switched on and connected"; exit 3; }

CT=/tmp/msp-bitlocker.ps1
REMOTE_DIR='C:\Windows\Temp\'
REMOTE_FILE='C:\Windows\Temp\msp-bitlocker.ps1'
cleanup_container() { docker compose exec -T meshcentral rm -f -- "$CT" </dev/null >/dev/null 2>&1 || true; }
trap cleanup_container EXIT

docker compose exec -T meshcentral sh -c "umask 077; cat > ${CT}" < agent/windows/bitlocker-manage.ps1
mc Upload --id "$id" --file "$CT" --target "$REMOTE_DIR" >/dev/null
reply="$(timeout 600 docker compose exec -T meshcentral node "$MESH_CTL" RunCommand --id "$id" --reply \
    --run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"${REMOTE_FILE}\" -Volume ${vol} -Mode ${mode}" \
    --url ws://127.0.0.1:4430 --loginuser "$MESH_USER" --loginpass "$MESH_PASS" </dev/null 2>&1 | tr -d '\r' || true)"
mc RunCommand --id "$id" --run "del /f /q \"${REMOTE_FILE}\"" >/dev/null || true
cleanup_container

result="$(grep -E '^MSP-BL-RESULT\|' <<<"$reply" | tail -1 || true)"
if [[ -z "$result" ]]; then echo "no answer from ${host} (it may have gone offline): try again"; exit 1; fi
state="$(cut -d'|' -f2 <<<"$result")"; text="$(cut -d'|' -f3- <<<"$result")"

# save the keys: validated, then encrypted by Postgres. The SQL goes in on stdin, so no key appears on a command line.
saved=0
while IFS='|' read -r _ kv pid rp; do
  [[ "$kv" == "$vol" && "$pid" =~ ^\{[0-9A-Fa-f-]{36}\}$ && "$rp" =~ ^([0-9]{6}-){7}[0-9]{6}$ ]] || continue
  if docker compose exec -T postgres psql -U portal -d portal -v ON_ERROR_STOP=1 -X -q >/dev/null <<SQL
INSERT INTO bitlocker_key(customer_slug, host, volume, protector_id, recovery_enc)
VALUES ('${cust}', '${hostl}', '${vol}', '${pid}', pgp_sym_encrypt('${rp}', '${pass}'))
ON CONFLICT (customer_slug, host, volume, protector_id) DO UPDATE SET recovery_enc = EXCLUDED.recovery_enc, collected_at = now();
SQL
  then saved=$((saved+1)); fi
done < <(grep -E '^MSP-BL-KEY\|' <<<"$reply")

if [[ "$state" == ok ]]; then
  if (( saved == 0 )); then echo "${text} (no recovery key could be saved)"; exit 1; fi
  echo "${text} Saved ${saved} recovery key(s)."; exit 0
fi
echo "${text:-the computer reported an error}"; exit 1
