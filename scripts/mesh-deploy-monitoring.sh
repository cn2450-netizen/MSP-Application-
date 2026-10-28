#!/usr/bin/env bash
# Push a site's monitoring-agent installer to its online Windows machines through MeshCentral and run it.
#   scripts/mesh-deploy-monitoring.sh <customer> <site> [--device NAME[,NAME...]] [--yes]
#
# For each online device in the group "<customer> / <site>" it: uploads the installer to C:\Windows\Temp,
# runs it (the MeshCentral agent runs as SYSTEM, so it has the rights), reports the installer's result,
# and deletes the file from the device and from the MeshCentral container. The installer holds that site's
# write-only keys, so it is copied into the container only for the duration of each push.
# More than one device needs --yes (or pick one with --device). Re-running upgrades an existing agent.
# Needs a MeshCentral login token: scripts/mesh-token.sh set
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
source scripts/lib/meshcentral.sh

cust="${1:?usage: mesh-deploy-monitoring.sh <customer> <site> [--device NAME[,NAME...]] [--yes]}"
site="${2:?site required}"; shift 2
only="" yes=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) only="${2:?--device needs a name}"; shift 2;;
    --yes) yes=1; shift;;
    *) echo "unknown option $1" >&2; exit 2;;
  esac
done
[[ "$cust" =~ ^[a-z0-9][a-z0-9-]{1,30}$ && "$site" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || { echo "invalid customer or site name" >&2; exit 2; }
installer="generated/agents/${cust}/${site}/install-agent-${cust}-${site}.ps1"
[[ -f "$installer" ]] || { echo "no installer at ${installer}: scripts/add-site.sh ${cust} ${site} builds it" >&2; exit 1; }

mesh_login || exit 1
gname="${cust} / ${site}"
[[ -n "$(mesh_group_id "$gname")" ]] || { echo "no device group '${gname}': run scripts/mesh-site.sh ${cust} ${site}" >&2; exit 1; }

devices="$(mc ListDevices --group "$gname" --json | jq -c '[.[]|select(((.conn // 0) % 2) == 1)]' 2>/dev/null || echo '[]')"
[[ -n "$only" ]] && devices="$(jq -c --arg n "$only" '[.[]|select(.name as $x | ($n|split(",")|index($x)) != null)]' <<<"$devices")"
count="$(jq length <<<"$devices")"
if [[ "$count" == 0 ]]; then echo "No online devices in '${gname}'${only:+ matching '${only}'}."; exit 0; fi
echo "Online devices in '${gname}':"; jq -r '.[]|"  \(.name)  (\(.osdesc // "?"))"' <<<"$devices"
if [[ "$count" -gt 1 && "$yes" != 1 ]]; then echo "That is ${count} devices: re-run with --yes to deploy to all of them, or --device NAME for one." >&2; exit 1; fi

REMOTE_DIR='C:\Windows\Temp\'
REMOTE_FILE='C:\Windows\Temp\msp-install.ps1'
MAXPAR="${MSP_DEPLOY_PARALLEL:-4}"      # devices installed at the same time (each one downloads the agent from the vendor)
tmpd="$(mktemp -d)"
cleanup() { docker compose exec -T meshcentral sh -c 'rm -rf /tmp/d-*' >/dev/null 2>&1 || true; rm -rf -- "$tmpd"; }
trap cleanup EXIT

# One device: its output goes to its own log so parallel runs do not interleave. Every path ends in a RESULT line.
deploy_one() {   # deploy_one <device-json> <logfile>
  local dev="$1" log="$2" id name dir ct up reply
  id="$(jq -r '._id' <<<"$dev")"; name="$(jq -r '.name' <<<"$dev")"
  dir="/tmp/d-$(tr -c 'A-Za-z0-9' '_' <<<"$id" | cut -c1-40)"; ct="${dir}/msp-install.ps1"
  {
    echo; echo "== ${name}"
    # Written through a pipe as the container's own unprivileged user (no capabilities, so no chown is possible or
    # needed): the file is created owned by that user, mode 600.
    docker compose exec -T meshcentral sh -c "umask 077; mkdir -p ${dir}; cat > ${ct}" < "$installer"
    up="$(mc Upload --id "$id" --file "$ct" --target "$REMOTE_DIR")"
    echo "  upload: $(tr '
' ' ' <<<"$up" | cut -c1-120)"
    reply="$(timeout 420 docker compose exec -T meshcentral node "$MESH_CTL" RunCommand --id "$id" --reply         --run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"${REMOTE_FILE}\""         --url ws://127.0.0.1:4430 --loginuser "$MESH_USER" --loginpass "$MESH_PASS" </dev/null 2>&1 || true)"
    mc RunCommand --id "$id" --run "del /f /q \"${REMOTE_FILE}\"" >/dev/null || true     # remove the installer (holds the site keys)
    docker compose exec -T meshcentral rm -rf -- "$dir" >/dev/null 2>&1 || true
    { grep -E '^\[MSP Agent\]|WARNING|rror' <<<"$reply" | sed 's/^/  /' | tail -8; } || true
    if grep -q "OK: " <<<"$reply"; then echo "  RESULT: installed/updated"
    else echo "  RESULT: not confirmed; raw output tail:"; { tail -6 <<<"$reply" | sed 's/^/    /'; } || true; fi
  } >"$log" 2>&1
}

n=0
while read -r dev; do
  while [[ "$(jobs -rp | wc -l)" -ge "$MAXPAR" ]]; do sleep 2; done
  n=$((n+1)); deploy_one "$dev" "${tmpd}/$(printf '%03d' "$n").log" </dev/null &   # </dev/null: a background job must not read the device list
done < <(jq -c '.[]' <<<"$devices")
wait
cat "$tmpd"/*.log
ok="$(cat "$tmpd"/*.log | grep -c 'RESULT: installed')" || true
failed=$((count - ok))
echo; echo "Done: ${ok} confirmed, ${failed} not confirmed."
[[ "$failed" == 0 ]]
