#!/usr/bin/env bash
# Add a site (location) to an existing customer. Each site gets its OWN write-only credentials, so one
# location's key can be revoked without touching the others:
#   Influx : a write-only token for the customer's bucket, named "agent-write <customer>/<site>"
#   Loki   : a push key mapped to the customer's tenant (same tenant, so one customer = one data set)
# Then builds that site's one-file Windows installer.
#
# usage: scripts/add-site.sh <customer> <site> ["Site display name"]
# Credentials: generated/credentials/<customer>/<site>.txt (mode 600)
# Installer:   generated/agents/<customer>/<site>/install-agent-<customer>-<site>.ps1
set -euo pipefail
cd "$(dirname "$0")/.."

cust="${1:?usage: add-site.sh <customer> <site> [\"Site display name\"]}"
site="${2:?site slug required (a-z 0-9 -)}"
site_name="${3:-$site}"

[[ "$cust" =~ ^[a-z0-9][a-z0-9-]{1,30}$ ]] || { echo "invalid customer slug"; exit 1; }
[[ "$site" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || { echo "site must be 1-31 chars of a-z 0-9 -"; exit 1; }
[[ "$site_name" != *$'\t'* && "$site_name" != *$'\n'* ]] || { echo "site name cannot contain tabs or newlines"; exit 1; }
command -v jq >/dev/null || { echo "jq is required"; exit 1; }

touch generated/sites.tsv
awk -F'\t' -v c="$cust" '$1==c{f=1} END{exit !f}' generated/customers.tsv || { echo "unknown customer '${cust}' (see generated/customers.tsv)"; exit 1; }
awk -F'\t' -v c="$cust" -v s="$site" '$1==c && $2==s{f=1} END{exit f}' generated/sites.tsv || { echo "site '${site}' already exists for '${cust}'"; exit 1; }

set -a; source .env; set +a
INFLUX_TOKEN="$(cat secrets/influx_admin_token)"
influx_raw() { docker compose exec -T -e INFLUX_TOKEN="$INFLUX_TOKEN" influxdb influx "$@"; }

bucket_id="$(influx_raw bucket list --org msp --json </dev/null | jq -r --arg n "cust_${cust}" '.[]|select(.name==$n)|.id')"
[[ -n "$bucket_id" ]] || { echo "bucket cust_${cust} not found in InfluxDB"; exit 1; }

write_auth="" loki_key=""
rollback() {
  local rc=$?
  trap - ERR
  echo "FAILED (exit ${rc}) - rolling back site '${site}' for '${cust}'" >&2
  if [[ -n "$loki_key" ]]; then
    sed -i "/${loki_key}/d" generated/gateway/loki.map
    docker compose exec -T gateway nginx -s reload >/dev/null 2>&1 || true
  fi
  if [[ -n "$write_auth" ]]; then influx_raw auth delete --id "$write_auth" >/dev/null 2>&1 || true; fi
  exit "$rc"
}
trap rollback ERR

echo "[1/3] Influx write-only token"
out="$(influx_raw auth create --org msp --json --write-bucket "$bucket_id" --description "agent-write ${cust}/${site}" </dev/null)"
write_auth="$(jq -r '.id' <<<"$out")"; write_token="$(jq -r '.token' <<<"$out")"

echo "[2/3] Loki push key"
loki_key="$(openssl rand -hex 32)"
printf '"Bearer %s" "%s";   # site=%s\n' "$loki_key" "$cust" "$site" >> generated/gateway/loki.map
docker compose exec -T gateway nginx -s reload </dev/null >/dev/null 2>&1
live=0
for _ in $(seq 1 24); do   # reload returns before the new workers take over; wait until the key is accepted (max ~6 s)
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://${BIND_ADDR}:${GATEWAY_PORT}/loki/api/v1/push"     -H "Authorization: Bearer ${loki_key}" -H 'Content-Type: application/json' -d '{"streams":[]}')"
  if [[ "$code" != "401" ]]; then live=1; break; fi
  sleep 0.25
done
[[ "$live" == 1 ]] || { echo "the gateway did not start accepting the new key within 6 s"; false; }

echo "[3/3] Registry, credentials, installer"
mkdir -p "generated/credentials/${cust}"
cred="generated/credentials/${cust}/${site}.txt"
( umask 077; cat > "$cred" <<EOF
customer:        ${cust}
site:            ${site} (${site_name})
ingest url:      https://${INGEST_HOST}
influx bucket:   cust_${cust}
influx WRITE id: ${write_auth}
influx WRITE tk: ${write_token}
loki push key:   ${loki_key}
EOF
)
printf '%s\t%s\t%s\t%s\t%s\n' "$cust" "$site" "$site_name" "$(date -u +%FT%TZ)" "$write_auth" >> generated/sites.tsv
trap - ERR
scripts/build-agent-installer.sh "$cust" "$site" || echo "WARNING: could not build the installer; run scripts/build-agent-installer.sh ${cust} ${site} to retry" >&2
echo
echo "Site '${site}' added to '${cust}'. Credentials: ${cred} (mode 600)"
