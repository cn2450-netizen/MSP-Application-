#!/usr/bin/env bash
# READ-ONLY BitLocker diagnosis of one PC through MeshCentral: TPM, Secure Boot, WinRE, BitLocker policy, state.
#   scripts/bitlocker-diagnose.sh <customer> <computer>
# Runs agent/windows/bitlocker-diagnose.ps1 as SYSTEM and prints the report; the script is deleted afterwards.
# Needs a MeshCentral login token (scripts/mesh-token.sh set). Changes nothing on the PC; shows no recovery keys.
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
source scripts/lib/meshcentral.sh

cust="${1:?usage: bitlocker-diagnose.sh <customer> <computer>}"; host="${2:?computer required}"
[[ "$cust" =~ ^[a-z0-9][a-z0-9-]{1,30}$ ]] || { echo "invalid customer"; exit 2; }
[[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,62}[A-Za-z0-9])?$ ]] || { echo "invalid computer name"; exit 2; }
hostl="${host,,}"
mesh_login || exit 1

id=""
while IFS= read -r g; do
  [[ -z "$g" ]] && continue
  id="$(mc ListDevices --group "$g" --json | jq -r --arg n "$hostl" '[.[]|select(((.conn // 0) % 2) == 1 and ((.name|ascii_downcase)==$n))]|.[0]._id // empty' 2>/dev/null)"
  [[ -n "$id" ]] && break
done < <(mc ListDeviceGroups --json | jq -r --arg p "${cust} / " '.[]|select(.name|startswith($p))|.name')
[[ -n "$id" ]] || { echo "${host} is not online in MeshCentral (device groups '${cust} / ...')"; exit 1; }

CT=/tmp/msp-bitlocker-diagnose.ps1
REMOTE_FILE='C:\Windows\Temp\msp-bitlocker-diagnose.ps1'
cleanup_container() { docker compose exec -T meshcentral rm -f -- "$CT" </dev/null >/dev/null 2>&1 || true; }
trap cleanup_container EXIT
docker compose exec -T meshcentral sh -c "umask 077; cat > ${CT}" < agent/windows/bitlocker-diagnose.ps1
mc Upload --id "$id" --file "$CT" --target 'C:\Windows\Temp\' >/dev/null
timeout 300 docker compose exec -T meshcentral node "$MESH_CTL" RunCommand --id "$id" --reply \
    --run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"${REMOTE_FILE}\"" \
    --url ws://127.0.0.1:4430 --loginuser "$MESH_USER" --loginpass "$MESH_PASS" </dev/null 2>&1 | tr -d '\r'
mc RunCommand --id "$id" --run "del /f /q \"${REMOTE_FILE}\"" >/dev/null || true
