#!/usr/bin/env bash
# Install the monitoring agent on any online computer that has the MeshCentral agent but has never reported monitoring
# data, so a newly enrolled computer does not stay invisible. Run every few minutes by the msp-autodeploy timer
# (scripts/install-autodeploy.sh); also fine by hand:   scripts/monitoring-autodeploy.sh [--dry-run]
#
# Per site group "<customer> / <site>": online Mesh devices MINUS computers seen in that customer's InfluxDB bucket in the
# last 7 days (a computer that once reported already has the agent: a stopped one is a health problem, not an install job).
# Retries back off (1 h, 6 h, then daily) so a computer that blocks the installer (antivirus) is not hammered, and
# generated/autodeploy-skip.txt lists computer names (one per line, case-insensitive) that must never be touched.
#
# Credentials: its OWN limited MeshCentral account's login token, in generated/mesh-autodeploy-token (line 1 user,
# line 2 password; set with scripts/mesh-autodeploy-token.sh set). It is separate from the token you create by hand.
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
dry=0; [[ "${1:-}" == --dry-run ]] && dry=1

TOKEN=generated/mesh-autodeploy-token
STATE=generated/autodeploy-state.tsv      # computer<TAB>customer<TAB>site<TAB>last_try_epoch<TAB>failures
SKIP=generated/autodeploy-skip.txt
[[ -s "$TOKEN" ]] || { echo "no auto-deploy token (generated/mesh-autodeploy-token): nothing done" >&2; exit 0; }
export MESH_TOKEN_USER="$(sed -n 1p "$TOKEN")" MESH_TOKEN_PASS="$(sed -n 2p "$TOKEN")"
source scripts/lib/meshcentral.sh
lock=/run/user/$(id -u)/msp-autodeploy.lock; [[ -w "${lock%/*}" ]] || lock=/tmp/msp-autodeploy.lock
exec 9>"$lock"          # (a redirect on exec itself would silence stderr for the rest of the script)
flock -n 9 || exit 0
mesh_login || { echo "the auto-deploy token was rejected or expired: renew it with scripts/mesh-autodeploy-token.sh set" >&2; exit 1; }
touch "$STATE" "$SKIP"

# computers that have reported monitoring data in the last 7 days, lower-cased, for one customer
reporting() {
  docker compose exec -T influxdb sh -c 'influx query --org msp --token "$(cat /run/secrets/influx_admin_token)" --raw -f /dev/stdin' <<FLUX 2>/dev/null \
    | awk -F, '{ gsub(/\r/, "") } $1=="" && $2=="" && $3 ~ /^[0-9]+$/ && $4!="" {print tolower($4)}'
from(bucket: "cust_${1}") |> range(start: -7d)
  |> filter(fn: (r) => r._measurement == "cpu" and r._field == "usage_idle" and r.cpu == "cpu-total")
  |> last() |> keep(columns: ["host"]) |> group()
FLUX
}
backoff() { case "$1" in 0) echo 0;; 1) echo 3600;; 2) echo 21600;; *) echo 86400;; esac; }   # seconds to wait after N failures

now=$(date +%s); deployed=0
while IFS=$'\t' read -r cust site _rest; do
  [[ "$cust" =~ ^[a-z0-9][a-z0-9-]{1,30}$ && "$site" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || continue
  gname="${cust} / ${site}"
  online="$(mc ListDevices --group "$gname" --json 2>/dev/null | jq -r '.[]|select(((.conn // 0) % 2) == 1)|"\(.name)	\(.rname // .name)"' 2>/dev/null)" || continue
  [[ -n "$online" ]] || continue
  known="$(reporting "$cust")"
  todo=()
  while IFS=$'	' read -r name rname; do                                   # name = what MeshCentral shows, rname = the computer's own name
    [[ -z "$name" ]] && continue
    lname="${name,,}"
    grep -qixF -- "${rname,,}" <<<"$known" && continue                   # already reporting (monitoring reports the computer's own name)
    grep -qixF -- "$name" "$SKIP" && continue                            # told never to touch
    grep -qixF -- "$rname" "$SKIP" && continue
    [[ "$name" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,62}[A-Za-z0-9])?$ ]] || continue
    row="$(awk -F'\t' -v n="$lname" -v c="$cust" '$1==n && $2==c{print}' "$STATE")"
    last="$(cut -f4 <<<"$row")"; fails="$(cut -f5 <<<"$row")"
    if [[ -n "$last" ]] && (( now - last < $(backoff "${fails:-0}") )); then continue; fi
    todo+=("$name")
  done <<<"$online"
  (( ${#todo[@]} )) || continue
  echo "${gname}: no monitoring on: ${todo[*]}"
  (( dry )) && continue
  names="$(IFS=,; echo "${todo[*]}")"
  out="$(timeout 1500 scripts/mesh-deploy-monitoring.sh "$cust" "$site" --device "$names" --yes 2>&1)"
  for name in "${todo[@]}"; do
    lname="${name,,}"
    # the deploy script prints "== NAME" then a RESULT line for each device
    if awk -v n="== ${name}" '$0==n{f=1;next} /^== /{f=0} f && /RESULT: installed\/updated/{ok=1} END{exit !ok}' <<<"$out"; then fails=0; deployed=$((deployed+1)); echo "  ${name}: installed"
    else fails=$(( $(awk -F'\t' -v n="$lname" -v c="$cust" '$1==n && $2==c{print $5}' "$STATE" | head -1) + 1 )); echo "  ${name}: not confirmed (attempt ${fails})"; fi
    grep -v -P "^\Q${lname}\E\t\Q${cust}\E\t" "$STATE" > "$STATE.new" 2>/dev/null; mv "$STATE.new" "$STATE"
    printf '%s\t%s\t%s\t%s\t%s\n' "$lname" "$cust" "$site" "$now" "$fails" >> "$STATE"
  done
done < generated/sites.tsv
echo "auto-deploy done: ${deployed} installed"
scripts/mesh-power-plan.sh || true     # same cadence, own lock and company list (generated/power-plan-companies.txt)
exit 0
