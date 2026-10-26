#!/usr/bin/env bash
# Onboard a customer with isolated data in every layer:
#   Influx  : bucket cust_<slug> + a write-only token (agents) + a read-only token (Grafana)
#   Loki    : tenant <slug>, with a random push key registered in the gateway
#   Grafana : org <slug>, datasources bound to that bucket/tenant only, starter dashboard
#
# usage: scripts/add-customer.sh <slug> "<Display Name>" [retention-days]
# Credentials are written to generated/credentials/<slug>.txt (mode 600), never printed.
set -euo pipefail
cd "$(dirname "$0")/.."

slug="${1:?usage: add-customer.sh <slug> \"<Display Name>\" [retention-days]}"
name="${2:?display name required}"
days="${3:-90}"

[[ "$slug" =~ ^[a-z0-9][a-z0-9-]{1,30}$ ]] || { echo "slug must be 2-31 chars of a-z 0-9 -"; exit 1; }
[[ "$days" =~ ^[0-9]+$ ]] || { echo "retention must be a number of days"; exit 1; }
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
bucket_id="" write_auth="" read_auth="" loki_key="" org_id="" groups_made=0
rollback() {
  local rc=$?
  trap - ERR
  echo "FAILED (exit ${rc}) — rolling back partial setup for '${slug}'" >&2
  if [[ "$groups_made" == 1 ]]; then
    for g in "tech-${slug}" "cust-${slug}-users"; do
      gp="$(ak_req GET "core/groups/?name=${g}" 2>/dev/null | jq -r '.results[0].pk // empty' || true)"
      if [[ -n "$gp" ]]; then ak_req DELETE "core/groups/${gp}/" >/dev/null 2>&1 || true; fi
    done
  fi
  if [[ -n "$org_id" ]]; then curl -fsS -u "$GF_AUTH" -X DELETE "$GF_URL/api/orgs/$org_id" >/dev/null 2>&1 || true; fi
  if [[ -n "$loki_key" ]]; then
    sed -i "/${loki_key}/d" generated/gateway/loki.map
    docker compose exec -T gateway nginx -s reload >/dev/null 2>&1 || true
  fi
  for a in "$write_auth" "$read_auth"; do
    if [[ -n "$a" ]]; then influx_raw auth delete --id "$a" >/dev/null 2>&1 || true; fi
  done
  if [[ -n "$bucket_id" ]]; then influx_raw bucket delete --id "$bucket_id" >/dev/null 2>&1 || true; fi
  exit "$rc"
}
trap rollback ERR

echo "[1/6] Influx bucket + tokens"
bucket_id="$(influx bucket create --name "cust_${slug}" --retention "${days}d" | jq -r '.id')"
out="$(influx auth create --write-bucket "$bucket_id" --description "agent-write ${slug}")"
write_auth="$(jq -r '.id' <<<"$out")"; write_token="$(jq -r '.token' <<<"$out")"
out="$(influx auth create --read-bucket "$bucket_id" --description "grafana-read ${slug}")"
read_auth="$(jq -r '.id' <<<"$out")"; read_token="$(jq -r '.token' <<<"$out")"

echo "[2/6] Loki tenant key + gateway map"
loki_key="$(openssl rand -hex 32)"
printf '"Bearer %s" "%s";\n' "$loki_key" "$slug" >> generated/gateway/loki.map
docker compose exec -T gateway nginx -s reload

echo "[3/6] Grafana org + datasources"
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

echo "[4/6] Starter dashboard"
gf -X POST "$GF_URL/api/dashboards/db" -H "X-Grafana-Org-Id: $org_id" \
  -d "$(jq -n --slurpfile d dashboards/windows-overview.json '{dashboard:$d[0],overwrite:true}')" >/dev/null

echo "[5/6] authentik groups + Grafana access"
groups_made=1
tech_grp="$(ak_group "tech-${slug}")"
cust_grp="$(ak_group "cust-${slug}-users")"
ak_bind_group "$grafana_app" "$tech_grp"
ak_bind_group "$grafana_app" "$cust_grp"

echo "[6/6] Registry + Grafana org mapping"
printf '%s\t%s\t%s\n' "$slug" "$name" "$(date -u +%FT%TZ)" >> generated/customers.tsv
scripts/render-config.sh
docker compose up -d grafana   # recreates the container so the new org mapping is loaded

mkdir -p generated/credentials
cred="generated/credentials/${slug}.txt"
( umask 077; cat > "$cred" <<EOF
customer:        ${name} (${slug})
ingest url:      https://${INGEST_HOST}
influx org:      msp
influx bucket:   cust_${slug}
influx WRITE tk: ${write_token}
loki push key:   ${loki_key}

authentik groups (already created and allowed into Grafana):
  tech-${slug}          add your techs for this customer
  cust-${slug}-users    add the customer's own staff
EOF
)
echo
echo "Done. Agent credentials: $cred  (mode 600 — deliver securely, then delete or vault it)"
scripts/build-agent-installer.sh "$slug" || echo "WARNING: could not build the Windows installer; run scripts/build-agent-installer.sh ${slug} to retry" >&2
