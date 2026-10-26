#!/usr/bin/env bash
# Revoke one site's agent credentials (lost location, leaked key, decommissioned office).
# Agents using this site's keys are refused from the next request; the customer's other sites are untouched
# and the data already collected stays. Re-run add-site.sh to issue fresh keys (agents must be reinstalled).
#
# usage: scripts/revoke-site.sh <customer> <site>
set -euo pipefail
cd "$(dirname "$0")/.."

cust="${1:?usage: revoke-site.sh <customer> <site>}"
site="${2:?site required}"
[[ "$cust" =~ ^[a-z0-9][a-z0-9-]{1,30}$ && "$site" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || { echo "invalid name"; exit 1; }

row="$(awk -F'\t' -v c="$cust" -v s="$site" '$1==c && $2==s' generated/sites.tsv)"
[[ -n "$row" ]] || { echo "no such site '${site}' for '${cust}'"; exit 1; }
auth_id="$(cut -f5 <<<"$row")"
cred="generated/credentials/${cust}/${site}.txt"
loki_key=""
[[ -f "$cred" ]] && loki_key="$(sed -n 's/^loki push key:[[:space:]]*//p' "$cred")"

set -a; source .env; set +a
INFLUX_TOKEN="$(cat secrets/influx_admin_token)"
influx_raw() { docker compose exec -T -e INFLUX_TOKEN="$INFLUX_TOKEN" influxdb influx "$@"; }

echo "Revoking ${cust}/${site}"
[[ -n "$auth_id" ]] && { influx_raw auth delete --id "$auth_id" </dev/null >/dev/null && echo "  Influx write token deleted"; }
if [[ -n "$loki_key" ]]; then
  sed -i "/${loki_key}/d" generated/gateway/loki.map
  docker compose exec -T gateway nginx -s reload </dev/null >/dev/null 2>&1
  echo "  Loki push key removed from the gateway config; waiting for the gateway to start refusing it..."
  confirmed=0
  for _ in $(seq 1 24); do   # `nginx -s reload` returns before the new workers take over, so poll (max ~6 s)
    code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://${BIND_ADDR}:${GATEWAY_PORT}/loki/api/v1/push"       -H "Authorization: Bearer ${loki_key}" -H 'Content-Type: application/json' -d '{"streams":[]}')"
    if [[ "$code" == "401" ]]; then confirmed=1; break; fi
    sleep 0.25
  done
  if [[ "$confirmed" == 1 ]]; then echo "  confirmed: the gateway now answers 401 for that key"
  else echo "  WARNING: the gateway still accepted the key after 6 s. Check: docker compose logs gateway" >&2; fi
fi
awk -F'\t' -v c="$cust" -v s="$site" '!($1==c && $2==s)' generated/sites.tsv > generated/sites.tsv.new && mv generated/sites.tsv.new generated/sites.tsv
rm -f "$cred"
rm -rf "generated/agents/${cust:?}/${site:?}"
echo "Done. The site's installer and credential file were deleted."
