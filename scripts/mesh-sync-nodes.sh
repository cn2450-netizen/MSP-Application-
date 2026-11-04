#!/usr/bin/env bash
# Copy each computer's MeshCentral id into the portal database (table mesh_node) so the console's Remote access page can
# open a session straight on that computer. Read-only against MeshCentral; safe to re-run. Called by monitoring-autodeploy.sh.
#   scripts/mesh-sync-nodes.sh
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
TOKEN=generated/mesh-autodeploy-token
[[ -s "$TOKEN" ]] || exit 0
export MESH_TOKEN_USER="$(sed -n 1p "$TOKEN")" MESH_TOKEN_PASS="$(sed -n 2p "$TOKEN")"
source scripts/lib/meshcentral.sh
mesh_login 2>/dev/null || { echo "mesh node sync: the automation login was refused" >&2; exit 1; }

sql=""
while IFS=$'\t' read -r cust site _rest; do
  [[ "$cust" =~ ^[a-z0-9][a-z0-9-]{1,30}$ && "$site" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || continue
  # one row per name MeshCentral knows the computer by (its display name and its real name)
  rows="$(mc ListDevices --group "${cust} / ${site}" --json 2>/dev/null </dev/null | jq -r '.[] | select(._id | test("^node//[A-Za-z0-9@$_-]+$")) | (._id as $i | [.name, .rname] | map(select(. != null)) | unique[] | ascii_downcase | select(test("^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$")) | "\($i)\t\(.)")' 2>/dev/null)" || continue
  while IFS=$'\t' read -r id host; do
    [[ -z "$id" || -z "$host" ]] && continue
    sql+="INSERT INTO mesh_node (customer_slug, host, node_id) VALUES ('${cust}', '${host}', '${id}') ON CONFLICT (customer_slug, host) DO UPDATE SET node_id = EXCLUDED.node_id, updated_at = now();"$'\n'
  done <<<"$rows"
done < generated/sites.tsv
[[ -n "$sql" ]] || exit 0
printf '%s' "$sql" | docker compose exec -T postgres psql -U portal -d portal -v ON_ERROR_STOP=1 -X -q >/dev/null || { echo "mesh node sync: could not write the table (is the portal migrated?)" >&2; exit 1; }
echo "mesh node ids synced"
