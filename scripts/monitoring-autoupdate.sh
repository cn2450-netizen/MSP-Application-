#!/usr/bin/env bash
# Keep the monitoring agent up to date: re-install it on any online computer whose agent is behind the revision in
# agent/windows/agentinfo.ps1. A computer that was off over the weekend is updated within one run of it coming online.
# Run every few minutes by the msp-autoupdate timer (scripts/install-autoupdate.sh); also fine by hand:
#   scripts/monitoring-autoupdate.sh [--dry-run]
#
# Which computers: online in MeshCentral, in a company listed in generated/autoupdate-companies.txt (one slug per line;
# an empty or missing file updates nothing), reporting monitoring data in the last 7 days (computers with no monitoring
# are scripts/monitoring-autodeploy.sh's job), and reporting an older revision than the repository or none at all.
# generated/autodeploy-skip.txt (computer names, one per line) is honoured here as well.
#
# Fail-safes, per computer:
#   - at least PAUSE seconds between attempts (30 minutes);
#   - at most MAX_PER_DAY attempts a day (3), however they ended;
#   - after FLAG_AFTER failures in a row (3), or three attempts in a day that left it still behind, the computer is FLAGGED
#     and nothing more is tried on it until someone looks: scripts/autoupdate-clear.sh <company> <computer>.
# And per run: at most MAX_PER_RUN computers (3), with PAUSE_BETWEEN seconds between them.
# The flag shows in the console (Computers list and the computer's page); state lives in the agent_update table.
#
# Credentials: its OWN MeshCentral login token, generated/mesh-autoupdate-token (line 1 user, line 2 password), used by
# nothing else. Not the token you create by hand.
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
dry=0; [[ "${1:-}" == --dry-run ]] && dry=1

PAUSE=1800 MAX_PER_DAY=3 FLAG_AFTER=3 MAX_PER_RUN=3 PAUSE_BETWEEN=60
TOKEN=generated/mesh-autoupdate-token
COMPANIES=generated/autoupdate-companies.txt
SKIP=generated/autodeploy-skip.txt
[[ -s "$TOKEN" ]] || { echo "no auto-update token ($TOKEN): nothing done" >&2; exit 0; }
[[ -s "$COMPANIES" ]] || { echo "no companies in $COMPANIES: nothing to update" >&2; exit 0; }
touch "$SKIP"
export MESH_TOKEN_USER="$(sed -n 1p "$TOKEN")" MESH_TOKEN_PASS="$(sed -n 2p "$TOKEN")"
source scripts/lib/meshcentral.sh
lock=/run/user/$(id -u)/msp-autoupdate.lock; [[ -w "${lock%/*}" ]] || lock=/tmp/msp-autoupdate.lock
exec 9>"$lock"          # (a redirect on exec itself would silence stderr for the rest of the script)
flock -n 9 || exit 0
mesh_login || { echo "the auto-update token was rejected or expired: make a new one and replace $TOKEN" >&2; exit 1; }

target="$(sed -n "s/.*rev=\([0-9][0-9]*\)i.*/\1/p" agent/windows/agentinfo.ps1 | head -1)"
[[ "$target" =~ ^[0-9]+$ ]] || { echo "cannot read the revision from agent/windows/agentinfo.ps1" >&2; exit 1; }

psql_portal() { docker compose exec -T postgres psql -U portal -d portal -v ON_ERROR_STOP=1 -X -q -A -t -F $'\t' "$@"; }
influx() { docker compose exec -T influxdb sh -c 'influx query --org msp --token "$(cat /run/secrets/influx_admin_token)" --raw -f /dev/stdin' 2>/dev/null | awk -F, '{ gsub(/\r/, "") } $1=="" && $2=="" && $3 ~ /^[0-9]+$/'; }

# "host<TAB>revision" for every computer that reports monitoring data (revision 0 when it reports none)
fleet_revs() {
  local c="$1" reporting revs
  reporting="$(influx <<FLUX | awk -F, '{print tolower($4)}'
from(bucket: "cust_${c}") |> range(start: -7d)
  |> filter(fn: (r) => r._measurement == "cpu" and r._field == "usage_idle" and r.cpu == "cpu-total")
  |> last() |> keep(columns: ["host"]) |> group()
FLUX
)"
  revs="$(influx <<FLUX | awk -F, '{print tolower($4) "\t" $5}'
from(bucket: "cust_${c}") |> range(start: -30d)
  |> filter(fn: (r) => r._measurement == "agent_info" and r._field == "rev")
  |> group(columns: ["host"]) |> last() |> keep(columns: ["host", "_value"]) |> group()
FLUX
)"
  while IFS= read -r h; do
    [[ -z "$h" ]] && continue
    r="$(awk -F'\t' -v h="$h" '$1==h{print $2; exit}' <<<"$revs")"
    printf '%s\t%s\n' "$h" "${r:-0}"
  done <<<"$reporting"
}

now=$(date +%s); today=$(date +%F); done_this_run=0; updated=0
while IFS=$'\t' read -r cust site _rest; do
  [[ "$cust" =~ ^[a-z0-9][a-z0-9-]{1,30}$ && "$site" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || continue
  grep -qixF -- "$cust" "$COMPANIES" || continue
  gname="${cust} / ${site}"
  online="$(mc ListDevices --group "$gname" --json 2>/dev/null | jq -r '.[]|select(((.conn // 0) % 2) == 1)|"\(.name)	\(.rname // .name)"' 2>/dev/null)" || continue
  [[ -n "$online" ]] || continue
  revs="$(fleet_revs "$cust")"
  flaggedhosts="$(psql_portal -c "SELECT host FROM agent_update WHERE customer_slug = '${cust}' AND flagged")"
  while IFS=$'\t' read -r name rname; do
    [[ -z "$name" ]] && continue
    (( done_this_run >= MAX_PER_RUN )) && break
    [[ "$name" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,62}[A-Za-z0-9])?$ ]] || continue
    grep -qixF -- "$name" "$SKIP" && continue
    grep -qixF -- "$rname" "$SKIP" && continue
    host="${rname,,}"
    rev="$(awk -F'\t' -v h="$host" '$1==h{print $2; exit}' <<<"$revs")"
    [[ -z "$rev" ]] && continue                              # not reporting monitoring at all: not ours to update
    if (( rev >= target )); then                             # up to date; a leftover flag from before is cleared
      grep -qxF -- "$host" <<<"$flaggedhosts" && { (( dry )) || psql_portal -c "DELETE FROM agent_update WHERE customer_slug = '${cust}' AND host = '${host}'" >/dev/null; }
      continue
    fi
    # this computer's record: day, attempts today, failures in a row, last try (epoch), flagged
    row="$(psql_portal -c "SELECT attempt_day, attempts_today, failures, COALESCE(extract(epoch from last_try)::bigint, 0), flagged FROM agent_update WHERE customer_slug = '${cust}' AND host = '${host}'")"
    IFS=$'\t' read -r aday atts fails last flagged <<<"$row"
    atts="${atts:-0}"; fails="${fails:-0}"; last="${last:-0}"; flagged="${flagged:-f}"
    [[ "${aday:-}" == "$today" ]] || atts=0                   # a new day starts the count again
    [[ "$flagged" == t ]] && continue                         # needs a person
    if (( atts >= MAX_PER_DAY )); then                        # three tries today and it is still behind: stop and flag
      echo "  ${name}: ${atts} attempts today and still behind -> flagged for manual attention"
      (( dry )) || psql_portal -c "INSERT INTO agent_update (customer_slug, host, attempt_day, attempts_today, failures, flagged, flagged_at, last_result) VALUES ('${cust}', '${host}', '${today}', ${atts}, ${fails}, true, now(), 'still behind after ${atts} attempts today') ON CONFLICT (customer_slug, host) DO UPDATE SET flagged = true, flagged_at = now(), last_result = EXCLUDED.last_result" >/dev/null
      continue
    fi
    (( now - last < PAUSE )) && continue                      # too soon after the last attempt
    echo "${gname}: ${name} is on revision ${rev}, repository is ${target}"
    (( dry )) && continue
    (( done_this_run > 0 )) && sleep "$PAUSE_BETWEEN"
    done_this_run=$((done_this_run + 1))
    out="$(timeout 900 scripts/mesh-deploy-monitoring.sh "$cust" "$site" --device "$name" 2>&1)"
    atts=$((atts + 1))
    if awk -v n="== ${name}" '$0==n{f=1;next} /^== /{f=0} f && /RESULT: installed\/updated/{ok=1} END{exit !ok}' <<<"$out"; then
      updated=$((updated + 1)); echo "  ${name}: installed (attempt ${atts} today)"
      psql_portal -c "INSERT INTO agent_update (customer_slug, host, attempt_day, attempts_today, failures, last_try, last_result, flagged) VALUES ('${cust}', '${host}', '${today}', ${atts}, 0, now(), 'installed, waiting to report revision ${target}', false) ON CONFLICT (customer_slug, host) DO UPDATE SET attempt_day = '${today}', attempts_today = ${atts}, failures = 0, last_try = now(), last_result = EXCLUDED.last_result, flagged = false" >/dev/null
    else
      fails=$((fails + 1)); why="$(grep -m1 -iE 'error|fail|reject|not confirmed|offline' <<<"$out" | tr -d "'\\\\" | cut -c1-150)"
      isflag=false; (( fails >= FLAG_AFTER )) && isflag=true
      echo "  ${name}: NOT confirmed (failure ${fails} in a row, attempt ${atts} today)${why:+: ${why}}$([[ $isflag == true ]] && echo ' -> flagged for manual attention')"
      psql_portal -c "INSERT INTO agent_update (customer_slug, host, attempt_day, attempts_today, failures, last_try, last_result, flagged, flagged_at) VALUES ('${cust}', '${host}', '${today}', ${atts}, ${fails}, now(), 'failed: ${why:-not confirmed}', ${isflag}, CASE WHEN ${isflag} THEN now() END) ON CONFLICT (customer_slug, host) DO UPDATE SET attempt_day = '${today}', attempts_today = ${atts}, failures = ${fails}, last_try = now(), last_result = EXCLUDED.last_result, flagged = ${isflag}, flagged_at = CASE WHEN ${isflag} AND NOT agent_update.flagged THEN now() ELSE agent_update.flagged_at END" >/dev/null
    fi
  done <<<"$online"
done < generated/sites.tsv
echo "auto-update done: ${updated} updated (repository revision ${target})"
exit 0
