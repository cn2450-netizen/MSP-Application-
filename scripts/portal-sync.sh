#!/usr/bin/env bash
# Copy the customer and site registry into the portal database so customers/sites with no machines yet still exist there.
# Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")/.."
while IFS=$'\t' read -r slug name _created; do
  [[ -z "${slug:-}" ]] && continue
  docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -qtA -U msp_admin -d portal -v c="$slug" -v n="$name" <<'SQL' >/dev/null
INSERT INTO customer(slug, name) VALUES (:'c', :'n') ON CONFLICT (slug) DO UPDATE SET name = EXCLUDED.name;
SQL
done < generated/customers.tsv
while IFS=$'\t' read -r cust site _rest; do
  [[ -z "${cust:-}" ]] && continue
  docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -qtA -U msp_admin -d portal -v c="$cust" -v s="$site" <<'SQL' >/dev/null
INSERT INTO site(customer_slug, slug) VALUES (:'c', :'s') ON CONFLICT DO NOTHING;
SQL
done < generated/sites.tsv
echo "portal registry synced"
