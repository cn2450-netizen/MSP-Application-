#!/usr/bin/env bash
# Reconcile authentik with the customer registry: for every customer in generated/customers.tsv make sure
# tech-<slug> and cust-<slug>-users exist and are allowed into Grafana. Safe to re-run; add-customer.sh
# does this for new customers, this repairs or backfills existing ones.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
source scripts/lib/authentik.sh
ak_login

app="$(ak_req GET core/applications/grafana/ | jq -r '.pk // empty')"
[[ -n "$app" ]] || { echo "Run scripts/setup-authentik.sh first."; exit 1; }
ak_bind_group "$app" "$(ak_group msp-admins)"

while IFS=$'\t' read -r slug _name _created; do
  [[ -z "${slug:-}" ]] && continue
  ak_bind_group "$app" "$(ak_group "tech-${slug}")"
  ak_bind_group "$app" "$(ak_group "cust-${slug}-users")"
  echo "  ok  ${slug}"
done < generated/customers.tsv
echo "Groups allowed into Grafana:"
ak_req GET "policies/bindings/?target=${app}&page_size=500" | jq -r '.results[].group_obj.name' | sort | sed 's/^/  /'
