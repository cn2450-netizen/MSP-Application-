#!/usr/bin/env bash
# Push a site's monitoring-agent installer to its online Windows machines through MeshCentral and run it.
#   scripts/mesh-deploy-monitoring.sh <customer> <site> [--device NAME] [--yes]
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

cust="${1:?usage: mesh-deploy-monitoring.sh <customer> <site> [--device NAME] [--yes]}"
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
[[ -n "$only" ]] && devices="$(jq -c --arg n "$only" '[.[]|select(.name==$n)]' <<<"$devices")"
count="$(jq length <<<"$devices")"
if [[ "$count" == 0 ]]; then echo "No online devices in '${gname}'${only:+ matching '${only}'}."; exit 0; fi
echo "Online devices in '${gname}':"; jq -r '.[]|"  \(.name)  (\(.osdesc // "?"))"' <<<"$devices"
if [[ "$count" -gt 1 && "$yes" != 1 ]]; then echo "That is ${count} devices: re-run with --yes to deploy to all of them, or --device NAME for one." >&2; exit 1; fi

CT=/tmp/msp-install.ps1          # transient copy inside the container
REMOTE_DIR='C:\Windows\Temp\'
REMOTE_FILE='C:\Windows\Temp\msp-install.ps1'
cleanup_container() { docker compose exec -T meshcentral rm -f -- "$CT" >/dev/null 2>&1 || true; }
trap cleanup_container EXIT

ok=0 failed=0
while read -r dev; do
  id="$(jq -r '._id' <<<"$dev")"; name="$(jq -r '.name' <<<"$dev")"
  echo; echo "== ${name}"
  # Written through a pipe as the container's own unprivileged user (it has no capabilities, so no chown is possible
  # or needed): the file is created owned by that user, mode 600.
  docker compose exec -T meshcentral sh -c "umask 077; cat > ${CT}" < "$installer"
  up="$(mc Upload --id "$id" --file "$CT" --target "$REMOTE_DIR")"
  echo "  upload: $(tr '\n' ' ' <<<"$up" | cut -c1-120)"
  reply="$(timeout 420 docker compose exec -T meshcentral node "$MESH_CTL" RunCommand --id "$id" --reply \
      --run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"${REMOTE_FILE}\"" \
      --url ws://127.0.0.1:4430 --loginuser "$MESH_USER" --loginpass "$MESH_PASS" </dev/null 2>&1 || true)"
  mc RunCommand --id "$id" --run "del /f /q \"${REMOTE_FILE}\"" >/dev/null || true     # remove the installer (holds the site keys)
  cleanup_container
  echo "$reply" | grep -E '^\[MSP Agent\]|WARNING|rror' | sed 's/^/  /' | tail -8
  if grep -q "OK: " <<<"$reply"; then ok=$((ok+1)); echo "  RESULT: installed/updated"
  else failed=$((failed+1)); echo "  RESULT: not confirmed; raw output tail:"; echo "$reply" | tail -6 | sed 's/^/    /'; fi
done < <(jq -c '.[]' <<<"$devices")

echo; echo "Done: ${ok} confirmed, ${failed} not confirmed."
[[ "$failed" == 0 ]]
