#!/usr/bin/env bash
# Push the backup agent to a site's online Windows machines through MeshCentral and run its installer.
#   scripts/mesh-deploy-backup.sh <customer> <site> [--device NAME] [--register] [--paths 'D:\Data;E:\Shares'] [--run-now] [--yes]
#
# Each machine has its OWN installer (own login, own repository, own encryption password), named after its computer name:
# generated/agents/<customer>/<site>/backup/install-backup-<name>.ps1. By default a machine must already be registered
# (scripts/backup-add-machine.sh); --register does that and builds the installer for any online device that has none.
# Same push mechanics as mesh-deploy-monitoring.sh: upload to C:\Windows\Temp, run as SYSTEM, report, delete from the
# device and from the MeshCentral container (the installer holds that machine's backup passwords).
# Machines that are not registered are skipped (backup is opt-in per machine); naming one with --device that is not
# registered is an error. More than one device needs --yes (or pick one with --device). --run-now starts the first backup straight away.
# Re-running upgrades an existing install. Needs a MeshCentral login token: scripts/mesh-token.sh set
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
source scripts/lib/meshcentral.sh

cust="${1:?usage: mesh-deploy-backup.sh <customer> <site> [--device NAME] [--register] [--paths 'D:\Data;E:\Shares'] [--run-now] [--yes]}"
site="${2:?site required}"; shift 2
only="" yes=0 register=0 runnow="" paths=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) only="${2:?--device needs a name}"; shift 2;;
    --paths) paths="${2:?--paths needs a value}"; shift 2;;
    --register) register=1; shift;;
    --run-now) runnow=" -RunNow"; shift;;
    --yes) yes=1; shift;;
    *) echo "unknown option $1" >&2; exit 2;;
  esac
done
[[ "$cust" =~ ^[a-z0-9][a-z0-9-]{1,30}$ && "$site" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || { echo "invalid customer or site name" >&2; exit 2; }

mesh_login || exit 1
gname="${cust} / ${site}"
[[ -n "$(mesh_group_id "$gname")" ]] || { echo "no device group '${gname}': run scripts/mesh-site.sh ${cust} ${site}" >&2; exit 1; }

devices="$(mc ListDevices --group "$gname" --json | jq -c '[.[]|select(((.conn // 0) % 2) == 1)]' 2>/dev/null || echo '[]')"
[[ -n "$only" ]] && devices="$(jq -c --arg n "$only" '[.[]|select((.name|ascii_downcase)==($n|ascii_downcase))]' <<<"$devices")"
count="$(jq length <<<"$devices")"
if [[ "$count" == 0 ]]; then echo "No online devices in '${gname}'${only:+ matching '${only}'}."; exit 0; fi
echo "Online devices in '${gname}':"; jq -r '.[]|"  \(.name)  (\(.osdesc // "?"))"' <<<"$devices"
if [[ "$count" -gt 1 && "$yes" != 1 ]]; then echo "That is ${count} devices: re-run with --yes to deploy to all of them, or --device NAME for one." >&2; exit 1; fi

CT=/tmp/msp-backup-install.ps1   # transient copy inside the container
REMOTE_DIR='C:\Windows\Temp\'
REMOTE_FILE='C:\Windows\Temp\msp-backup-install.ps1'
cleanup_container() { docker compose exec -T meshcentral rm -f -- "$CT" >/dev/null 2>&1 || true; }
trap cleanup_container EXIT

ok=0 failed=0 skipped=0
while read -r dev; do
  id="$(jq -r '._id' <<<"$dev")"; name="$(jq -r '.name' <<<"$dev")"
  host="$(tr 'A-Z_' 'a-z-' <<<"$name")"
  echo; echo "== ${name}"
  installer="generated/agents/${cust}/${site}/backup/install-backup-${host}.ps1"
  if [[ "$register" == 1 ]]; then
    if ! awk -F'\t' -v c="$cust" -v s="$site" -v h="$host" '$1==c && $2==s && $3==h{f=1} END{exit !f}' generated/backup/machines.tsv 2>/dev/null; then
      scripts/backup-add-machine.sh "$cust" "$site" "$host" >/dev/null || { echo "  could not register ${host}"; failed=$((failed+1)); continue; }
      echo "  registered ${host} for backup"
    fi
    scripts/build-backup-installer.sh "$cust" "$site" "$host" ${paths:+--paths "$paths"} >/dev/null || { echo "  could not build the installer"; failed=$((failed+1)); continue; }
  fi
  if [[ ! -f "$installer" ]]; then
    if [[ -n "$only" ]]; then   # asked for this machine by name: not being able to back it up is an error
      echo "  NOT REGISTERED for backup: use --register, or scripts/backup-add-machine.sh ${cust} ${site} ${host} then scripts/build-backup-installer.sh"; failed=$((failed+1))
    else
      echo "  skipped: not registered for backup (normal: only registered machines are backed up; --register to include it)"; skipped=$((skipped+1))
    fi
    continue
  fi

  docker compose exec -T meshcentral sh -c "umask 077; cat > ${CT}" < "$installer"
  up="$(mc Upload --id "$id" --file "$CT" --target "$REMOTE_DIR")"
  echo "  upload: $(tr '\n' ' ' <<<"$up" | cut -c1-120)"
  reply="$(timeout 600 docker compose exec -T meshcentral node "$MESH_CTL" RunCommand --id "$id" --reply \
      --run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"${REMOTE_FILE}\"${runnow}" \
      --url ws://127.0.0.1:4430 --loginuser "$MESH_USER" --loginpass "$MESH_PASS" </dev/null 2>&1 || true)"
  mc RunCommand --id "$id" --run "del /f /q \"${REMOTE_FILE}\"" >/dev/null || true     # remove the installer (holds backup passwords)
  cleanup_container
  echo "$reply" | grep -E '^\[MSP Backup\]|WARNING|rror|refus' | sed 's/^/  /' | tail -8
  if grep -q "OK: '" <<<"$reply"; then ok=$((ok+1)); echo "  RESULT: backup installed/updated"
  else failed=$((failed+1)); echo "  RESULT: not confirmed; raw output tail:"; echo "$reply" | tail -6 | sed 's/^/    /'; fi
done < <(jq -c '.[]' <<<"$devices")

echo; echo "Done: ${ok} confirmed, ${failed} not confirmed, ${skipped} skipped."
[[ "$failed" == 0 ]]
