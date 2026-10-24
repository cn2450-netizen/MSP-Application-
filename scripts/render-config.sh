#!/usr/bin/env bash
# Rebuilds generated/grafana.env from generated/customers.tsv.
#
# Group convention in authentik -> Grafana org role:
#   msp-admins            -> Admin in every org (+ Grafana server admin)
#   tech-<slug>           -> Editor in that customer's org   (techs: only customers they're assigned)
#   cust-<slug>-users     -> Viewer in that customer's org   (customer's own staff)
set -euo pipefail
cd "$(dirname "$0")/.."

mapping="msp-admins:*:Admin"
while IFS=$'\t' read -r slug _name _created; do
  [[ -z "${slug:-}" ]] && continue
  mapping+=",tech-${slug}:${slug}:Editor,cust-${slug}-users:${slug}:Viewer"
done < generated/customers.tsv

mkdir -p generated
printf 'GF_AUTH_GENERIC_OAUTH_ORG_MAPPING=%s\n' "$mapping" > generated/grafana.env
echo "Rendered generated/grafana.env"
