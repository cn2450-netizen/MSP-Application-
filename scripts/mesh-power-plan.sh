#!/usr/bin/env bash
# Set the High performance power plan with sleep and hibernate off (display timeout untouched) on the Windows DESKTOPS of
# the companies listed in generated/power-plan-companies.txt (one slug per line; empty or missing = nothing done), the next
# time each one is online in MeshCentral. Run every 10 minutes at the end of monitoring-autodeploy.sh; fine by hand too:
#   scripts/mesh-power-plan.sh [--dry-run]
# Skipped on purpose: servers (Windows Server) and anything with a battery (a laptop kept awake on battery is a harm).
# Each computer is done ONCE and then recorded in generated/power-plan-state.tsv (computer, company, when, attempts); after 3
# failed attempts it is left alone until someone looks (delete its line to try again). Changes are read back before they are
# counted as done. Group policy that forces another plan will make the read-back fail, and that is reported, not hidden.
# Credentials: the limited automation account (generated/mesh-autodeploy-token).
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
dry=0; [[ "${1:-}" == --dry-run ]] && dry=1
TOKEN=generated/mesh-autodeploy-token; COMPANIES=generated/power-plan-companies.txt; STATE=generated/power-plan-state.tsv
MAX_TRIES=3; PAUSE=1800
[[ -s "$TOKEN" && -s "$COMPANIES" ]] || exit 0
export MESH_TOKEN_USER="$(sed -n 1p "$TOKEN")" MESH_TOKEN_PASS="$(sed -n 2p "$TOKEN")"
source scripts/lib/meshcentral.sh
lock=/run/user/$(id -u)/msp-powerplan.lock; [[ -w "${lock%/*}" ]] || lock=/tmp/msp-powerplan.lock
exec 9>"$lock"
flock -n 9 || exit 0
mesh_login 2>/dev/null || { echo "power plan: the automation login was refused" >&2; exit 1; }
touch "$STATE"

ps='$ErrorActionPreference = "Stop"
try {
  $os = Get-CimInstance Win32_OperatingSystem
  if ($os.ProductType -ne 1) { Write-Output "MSP-POWER|skip|a server"; return }
  if (Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue) { Write-Output "MSP-POWER|skip|has a battery (laptop)"; return }
  $hp = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
  if (-not ((powercfg /list) -match $hp)) { powercfg /duplicatescheme $hp $hp | Out-Null }
  powercfg /setactive $hp
  powercfg /change standby-timeout-ac 0; powercfg /change standby-timeout-dc 0
  powercfg /change hibernate-timeout-ac 0; powercfg /change hibernate-timeout-dc 0
  $active = (powercfg /getactivescheme) -join " "
  $q = (powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE) -join " "
  $ac = [regex]::Match($q, "Current AC Power Setting Index:\s*(0x[0-9a-fA-F]+)").Groups[1].Value
  $dc = [regex]::Match($q, "Current DC Power Setting Index:\s*(0x[0-9a-fA-F]+)").Groups[1].Value
  if (($active -match $hp) -and ([Convert]::ToInt32($ac, 16) -eq 0) -and ([Convert]::ToInt32($dc, 16) -eq 0)) { Write-Output "MSP-POWER|ok|High performance, sleep never" }
  else { Write-Output ("MSP-POWER|fail|read-back differs: " + $active + " sleep ac=" + $ac + " dc=" + $dc) }
} catch { Write-Output ("MSP-POWER|fail|" + $_.Exception.Message) }'

# sent encoded: a multi-line script does not survive the command line
enc="$(printf '%s' "$ps" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)"
now=$(date +%s)
while IFS= read -r cust; do
  [[ "$cust" =~ ^[a-z0-9][a-z0-9-]{1,30}$ ]] || continue
  while IFS=$'\t' read -r gname; do
    [[ -n "$gname" ]] || continue
    mc ListDevices --group "$gname" --json 2>/dev/null | jq -r '.[]|select(((.conn // 0) % 2) == 1)|[._id, (.rname // .name)]|@tsv' | while IFS=$'\t' read -r dev name; do
      lname="${name,,}"
      [[ "$lname" =~ ^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$ ]] || continue
      row="$(awk -F'\t' -v n="$lname" -v c="$cust" '$1==n && $2==c{print}' "$STATE")"
      [[ "$(cut -f3 <<<"$row")" == done || "$(cut -f3 <<<"$row")" == skipped ]] && continue
      tries="$(cut -f4 <<<"$row")"; tries="${tries:-0}"; last="$(cut -f5 <<<"$row")"; last="${last:-0}"
      (( tries >= MAX_TRIES )) && continue
      (( now - last < PAUSE )) && continue
      if (( dry )); then echo "would set power plan: ${cust}/${name}"; continue; fi
      reply="$(timeout 120 docker compose exec -T meshcentral node "$MESH_CTL" RunCommand --id "$dev" --reply --run "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ${enc}" \
        --url ws://127.0.0.1:4430 --loginuser "$MESH_USER" --loginpass "$MESH_PASS" </dev/null 2>&1 | tr -d '\r' || true)"
      [[ -n "${POWER_DEBUG:-}" ]] && echo "${reply}" | tail -5
      res="$(grep -E '^MSP-POWER\|' <<<"$reply" | tail -1)"
      state="$(cut -d'|' -f2 <<<"$res")"; text="$(cut -d'|' -f3- <<<"$res" | tr -cd '[:print:]' | cut -c1-200)"
      case "$state" in
        ok) st=done; echo "power plan ${cust}/${name}: ${text}";;
        skip) st=skipped; echo "power plan ${cust}/${name}: skipped (${text})";;
        "") st=try; echo "power plan ${cust}/${name}: no answer (it may have gone offline); will try again";;      # not a failure: does not use up an attempt
        *) st=try; tries=$((tries+1)); echo "power plan ${cust}/${name}: not done (attempt ${tries}) ${text}";;
      esac
      grep -v -P "^\Q${lname}\E\t\Q${cust}\E\t" "$STATE" > "$STATE.new" 2>/dev/null; mv "$STATE.new" "$STATE"
      printf '%s\t%s\t%s\t%s\t%s\n' "$lname" "$cust" "$st" "$tries" "$now" >> "$STATE"
    done
  done < <(mc ListDeviceGroups --json 2>/dev/null | jq -r --arg p "${cust} / " '.[]|select(.name|startswith($p))|.name')
done < "$COMPANIES"
exit 0
