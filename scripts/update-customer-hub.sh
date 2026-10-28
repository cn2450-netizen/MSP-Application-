#!/usr/bin/env bash
# Build the "Customers" picker: a Grafana dashboard with one tile per customer, each linking to that customer's
# Windows Overview, set as the home page of the default org (id 1, renamed "MSP Overview"). Only people in that org
# (msp-admins) see it; customers and per-customer technicians only ever belong to their own org.
# It holds links only: no data source, so it can read nothing about any customer.
# Re-run any time (add-customer.sh and offboard-customer.sh do it for you):  scripts/update-customer-hub.sh
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
command -v jq >/dev/null || { echo "jq is required"; exit 1; }
GF_URL="http://${BIND_ADDR}:${GRAFANA_PORT}"
GF_AUTH="msp-admin:$(cat secrets/grafana_admin_password)"
HUB_ORG=1
gf() { curl -fsS -u "$GF_AUTH" -H 'Content-Type: application/json' -H "X-Grafana-Org-Id: ${HUB_ORG}" "$@"; }

panels='[]'; i=0
while IFS=$'\t' read -r slug name _created; do
  [[ -z "${slug:-}" ]] && continue
  org_id="$(curl -fsS -u "$GF_AUTH" "$GF_URL/api/orgs/name/${slug}" 2>/dev/null | jq -r '.id // empty')" || true
  [[ -n "$org_id" ]] || { echo "  skipped ${slug}: no Grafana org"; continue; }
  panels="$(jq -c --arg t "$name" --arg slug "$slug" --argjson org "$org_id" --argjson i "$i" '. + [{
      id: ($i + 1), type: "text", title: $t,
      gridPos: {x: (($i % 3) * 8), y: (($i / 3 | floor) * 4), w: 8, h: 4},
      options: {mode: "markdown", content: ("### [Open dashboard →](/d/windows-overview/windows-overview?orgId=" + ($org|tostring) + ")\n\n`" + $slug + "`")}
    }]' <<<"$panels")"
  i=$((i+1))
done < <(sort -t$'\t' -k2 generated/customers.tsv)

dash="$(jq -n --argjson p "$panels" '{dashboard: {uid: "msp-customers", title: "Customers", tags: ["msp"],
  schemaVersion: 39, version: 1, panels: $p, time: {from: "now-6h", to: "now"}}, overwrite: true}')"
gf -X PUT "$GF_URL/api/orgs/${HUB_ORG}" -d '{"name":"MSP Overview"}' >/dev/null
gf -X POST "$GF_URL/api/dashboards/db" -d "$dash" >/dev/null
gf -X PUT "$GF_URL/api/org/preferences" -d '{"homeDashboardUID":"msp-customers"}' >/dev/null
echo "Customers picker updated: ${i} customer tile(s), set as the home page of the 'MSP Overview' org."
