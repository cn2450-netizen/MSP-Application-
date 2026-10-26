#!/usr/bin/env bash
# Onboard a customer with isolated data in every layer:
#   Influx  : bucket cust_<slug> + a read-only token (used by Grafana only)
#   Loki    : tenant <slug> (created implicitly by the first push)
#   Grafana : org <slug>, datasources bound to that bucket/tenant only, starter dashboard
#   authentik: groups tech-<slug> and cust-<slug>-users, allowed into Grafana
# then adds a first site called "main" (scripts/add-site.sh), which creates the agent credentials and installer.
# Add more locations later with:  scripts/add-site.sh <slug> <site> "Site name"
#
# usage: scripts/add-customer.sh <slug> "<Display Name>" [retention-days]
set -euo pipefail
cd "$(dirname "$0")/.."

slug="${1:?usage: add-customer.sh <slug> \"<Display Name>\" [retention-days]}"
name="${2:?display name required}"
days="${3:-90}"

[[ "$slug" =~ ^[a-z0-9][a-z0-9-]{1,30}$ ]] || { echo "slug must be 2-31 chars of a-z 0-9 -"; exit 1; }
[[ "$days" =~ ^[0-9]+$ ]] || { echo "retention must be a number of days"; exit 1; }
[[ "$name" != *$'\t'* && "$name" != *$'\n'* ]] || { echo "name cannot contain tabs or newlines"; exit 1; }
grep -q "^${slug}"$'\t' generated/customers.tsv && { echo "customer '${slug}' already exists"; exit 1; }
command -v jq >/dev/null || { echo "jq is required"; exit 1; }

set -a; source .env; set +a
INFLUX_TOKEN="$(cat secrets/influx_admin_token)"
GF_AUTH="msp-admin:$(cat secrets/grafana_admin_password)"
GF_URL="http://${BIND_ADDR}:${GRAFANA_PORT}"

source scripts/lib/authentik.sh
ak_login
grafana_app="$(ak_req GET core/applications/grafana/ 2>/dev/null | jq -r '.pk // empty')"
[[ -n "$grafana_app" ]] || { echo "Run scripts/setup-authentik.sh first: the Grafana application is not in authentik yet."; exit 1; }
influx_raw() { docker compose exec -T -e INFLUX_TOKEN="$INFLUX_TOKEN" influxdb influx "$@"; }
influx() { influx_raw "$@" --org msp --json; }

# If any step fails, undo what was already created so a re-run starts clean.
bucket_id="" read_auth="" org_id="" groups_made=0 registered=0
rollback() {
  local rc=$?
  trap - ERR
  echo "FAILED (exit ${rc}) - rolling back partial setup for '${slug}'" >&2
  if [[ -f generated/sites.tsv ]]; then   # sites added so far (the add-site step cleans up its own failures)
    for s in $(awk -F'\t' -v c="$slug" '$1==c{print $2}' generated/sites.tsv); do scripts/revoke-site.sh "$slug" "$s" >/dev/null 2>&1 || true; done
  fi
  if [[ "$registered" == 1 ]]; then
    awk -F'\t' -v c="$slug" '$1!=c' generated/customers.tsv > generated/customers.tsv.new && mv generated/customers.tsv.new generated/customers.tsv
    scripts/render-config.sh >/dev/null 2>&1 || true
    docker compose up -d grafana >/dev/null 2>&1 || true   # drop the rolled-back org from Grafana's running org mapping
  fi
  if [[ "$groups_made" == 1 ]]; then
    for g in "tech-${slug}" "cust-${slug}-users"; do
      gp="$(ak_req GET "core/groups/?name=${g}" 2>/dev/null | jq -r '.results[0].pk // empty' || true)"
      if [[ -n "$gp" ]]; then ak_req DELETE "core/groups/${gp}/" >/dev/null 2>&1 || true; fi
    done
  fi
  if [[ -n "$org_id" ]]; then curl -fsS -u "$GF_AUTH" -X DELETE "$GF_URL/api/orgs/$org_id" >/dev/null 2>&1 || true; fi
  if [[ -n "$read_auth" ]]; then influx_raw auth delete --id "$read_auth" >/dev/null 2>&1 || true; fi
  if [[ -n "$bucket_id" ]]; then influx_raw bucket delete --id "$bucket_id" >/dev/null 2>&1 || true; fi
  exit "$rc"
}
trap rollback ERR

echo "[1/5] Influx bucket + Grafana read token"
bucket_id="$(influx bucket create --name "cust_${slug}" --retention "${days}d" | jq -r '.id')"
out="$(influx auth create --read-bucket "$bucket_id" --description "grafana-read ${slug}")"
read_auth="$(jq -r '.id' <<<"$out")"; read_token="$(jq -r '.token' <<<"$out")"

echo "[2/5] Grafana org + datasources"
gf() { curl -fsS -u "$GF_AUTH" -H 'Content-Type: application/json' "$@"; }
org_id="$(gf -X POST "$GF_URL/api/orgs" -d "$(jq -n --arg n "$slug" '{name:$n}')" | jq -r '.orgId')"

gf -X POST "$GF_URL/api/datasources" -H "X-Grafana-Org-Id: $org_id" -d "$(jq -n \
  --arg b "cust_${slug}" --arg t "$read_token" \
  '{name:"Metrics",uid:"influx",type:"influxdb",access:"proxy",url:"http://influxdb:8086",isDefault:true,
    jsonData:{version:"Flux",organization:"msp",defaultBucket:$b},secureJsonData:{token:$t}}')" >/dev/null

gf -X POST "$GF_URL/api/datasources" -H "X-Grafana-Org-Id: $org_id" -d "$(jq -n \
  --arg s "$slug" \
  '{name:"Logs",uid:"loki",type:"loki",access:"proxy",url:"http://loki:3100",
    jsonData:{httpHeaderName1:"X-Scope-OrgID"},secureJsonData:{httpHeaderValue1:$s}}')" >/dev/null

echo "[3/5] Starter dashboard"
gf -X POST "$GF_URL/api/dashboards/db" -H "X-Grafana-Org-Id: $org_id" \
  -d "$(jq -n --slurpfile d dashboards/windows-overview.json '{dashboard:$d[0],overwrite:true}')" >/dev/null

echo "[4/5] authentik groups + Grafana access"
groups_made=1
tech_grp="$(ak_group "tech-${slug}")"
cust_grp="$(ak_group "cust-${slug}-users")"
ak_bind_group "$grafana_app" "$tech_grp"
ak_bind_group "$grafana_app" "$cust_grp"
mesh_app="$(ak_req GET core/applications/meshcentral/ 2>/dev/null | jq -r '.pk // empty' || true)"
if [[ -n "$mesh_app" ]]; then ak_bind_group "$mesh_app" "$tech_grp"; fi   # remote access is for staff only

echo "[5/5] Registry + Grafana org mapping"
printf '%s\t%s\t%s\n' "$slug" "$name" "$(date -u +%FT%TZ)" >> generated/customers.tsv
registered=1
scripts/render-config.sh
docker compose up -d grafana   # recreates the container so the new org mapping is loaded

echo
echo "First site: main"
scripts/add-site.sh "$slug" main "Main site"

trap - ERR
echo
echo "Customer '${slug}' is ready. authentik groups to fill (already allowed into Grafana):"
echo "  tech-${slug}          your techs for this customer"
echo "  cust-${slug}-users    the customer's own staff"
