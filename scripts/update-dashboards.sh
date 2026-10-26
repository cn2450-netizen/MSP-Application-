#!/usr/bin/env bash
# Re-import dashboards/windows-overview.json into every customer's Grafana org (add-customer.sh only imports it
# once, at onboarding). Run after editing the dashboard:  python dashboards/build_windows_overview.py && scripts/update-dashboards.sh
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
command -v jq >/dev/null || { echo "jq is required"; exit 1; }
GF_URL="http://${BIND_ADDR}:${GRAFANA_PORT}"
GF_AUTH="msp-admin:$(cat secrets/grafana_admin_password)"

while IFS=$'\t' read -r slug _name _created; do
  [[ -z "${slug:-}" ]] && continue
  org_id="$(curl -fsS -u "$GF_AUTH" "$GF_URL/api/orgs/name/${slug}" | jq -r '.id')"
  curl -fsS -u "$GF_AUTH" -H 'Content-Type: application/json' -H "X-Grafana-Org-Id: ${org_id}" \
    -X POST "$GF_URL/api/dashboards/db" \
    -d "$(jq -n --slurpfile d dashboards/windows-overview.json '{dashboard:$d[0],overwrite:true}')" >/dev/null
  echo "  updated ${slug} (org ${org_id})"
done < generated/customers.tsv
