#!/usr/bin/env bash
# End a customer relationship in two deliberate steps.
#
#   scripts/offboard-customer.sh <slug>                          report only: shows everything that exists for the customer
#   scripts/offboard-customer.sh <slug> --suspend                cut ALL access, keep ALL data
#   scripts/offboard-customer.sh <slug> --purge --confirm <slug> PERMANENTLY delete the data too
#
# --suspend (reversible except for the revoked agent keys):
#   - every site's monitoring keys are revoked and its MeshCentral device group removed (needs a Mesh login token)
#   - every backup machine loses its server login (the encrypted repositories stay on the NAS)
#   - portal: the customer's computers are retired and their agent tokens erased
#   - authentik: tech-<slug> and cust-<slug>-users are deleted, so nobody can reach Grafana, the portal or Mesh for them
#   Use this when the contract ends and the data must be kept for a retention period.
#
# --purge (does --suspend first, then irreversibly removes):
#   - the backup repositories and their credential files, the portal's catalog and job history for the customer
#   - the InfluxDB bucket, the Grafana org, the Loki tenant (a delete request; the compactor removes it within hours)
#   Audit rows stay (that is the record that it happened). Backups taken to the cold tier, if one exists, are NOT touched here.
#
# Every run appends to generated/offboard-audit.log.
set -euo pipefail
cd "$(dirname "$0")/.."

slug="${1:?usage: offboard-customer.sh <slug> [--suspend | --purge --confirm <slug>]}"; shift || true
mode=report confirm=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --suspend) mode=suspend; shift;;
    --purge) mode=purge; shift;;
    --confirm) confirm="${2:?--confirm needs the customer slug}"; shift 2;;
    *) echo "unknown option $1" >&2; exit 2;;
  esac
done
[[ "$slug" =~ ^[a-z0-9][a-z0-9-]{1,30}$ ]] || { echo "invalid customer slug" >&2; exit 2; }
if [[ "$mode" == purge && "$confirm" != "$slug" ]]; then
  echo "--purge deletes data permanently: add  --confirm ${slug}  to proceed" >&2; exit 2
fi
grep -q "^${slug}"$'\t' generated/customers.tsv 2>/dev/null || echo "note: '${slug}' is not in generated/customers.tsv (already suspended or partly removed?) - continuing with what is left"

set -a; source .env; set +a
# Run with sudo, the helper scripts replace the registries with new root-owned files, which the normal-user scripts
# (add-customer, add-site, backup-add-machine, the tests) then cannot update. Hand them back to the owner of .env on exit.
fix_owner() { if [[ $EUID -eq 0 ]]; then chown --reference=.env generated/customers.tsv generated/sites.tsv generated/backup/machines.tsv generated/restic/htpasswd generated/offboard-audit.log 2>/dev/null || true; fi; }
trap fix_owner EXIT
BK="${BACKUP_DIR:-/srv/msp-backups}"
INFLUX_TOKEN="$(cat secrets/influx_admin_token)"
GF_AUTH="msp-admin:$(cat secrets/grafana_admin_password)"
GF_URL="http://${BIND_ADDR}:${GRAFANA_PORT}"
influx_raw() { docker compose exec -T -e INFLUX_TOKEN="$INFLUX_TOKEN" influxdb influx "$@" </dev/null; }
# SQL comes in on stdin: psql does not substitute :'c' inside -c strings
pq() { docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -qtA -U msp_admin -d portal -v c="$slug" <<<"$1"; }
audit() { mkdir -p generated; printf '%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "${SUDO_USER:-$USER}" "$slug" "$1" >> generated/offboard-audit.log; }

sites="$(awk -F'\t' -v c="$slug" '$1==c{print $2}' generated/sites.tsv 2>/dev/null || true)"
machines="$(awk -F'\t' -v c="$slug" '$1==c{print $2"\t"$3"\t"$4}' generated/backup/machines.tsv 2>/dev/null || true)"
repos="$(find "$BK" -maxdepth 1 -type d -name "${slug}-*" 2>/dev/null | sort || true)"
pcount="$(pq "SELECT count(*) FROM machine WHERE customer_slug=:'c'" 2>/dev/null || echo '?')"

echo "== ${slug} =="
echo "sites:            ${sites:-none}" | tr '\n' ' '; echo
echo "backup machines:  $(cut -f2 <<<"$machines" | tr '\n' ' ')"
if [[ -n "$repos" ]]; then
  echo "repositories on the NAS:"
  while read -r r; do [[ -n "$r" ]] && printf '   %s  %s\n' "$(du -sh "$r" 2>/dev/null | cut -f1)" "$(basename "$r")"; done <<<"$repos"
fi
echo "portal computers: ${pcount}"
echo "influx bucket:    cust_${slug}"
if [[ "$mode" == report ]]; then
  echo
  echo "Nothing changed. Next:  scripts/offboard-customer.sh ${slug} --suspend   (cut access, keep data)"
  exit 0
fi

echo
echo "-- suspend: cutting access"
audit "${mode} started"

# 1. backup logins (data kept here; --purge deletes it below)
while IFS=$'\t' read -r s h _; do
  [[ -n "$h" ]] || continue
  echo "backup machine ${s}/${h}"
  scripts/backup-remove-machine.sh "$slug" "$s" "$h" || echo "  (could not remove ${s}/${h}; see above)" >&2
done <<<"$machines"

# 2. monitoring keys + Mesh device groups
for s in $sites; do
  scripts/revoke-site.sh "$slug" "$s" --remove-mesh-group || echo "  (could not fully revoke site ${s}; see above)" >&2
done

# 3. portal: retire the computers and erase their tokens
pq "UPDATE machine SET retired=true, token_hash=NULL, backup_enabled=false WHERE customer_slug=:'c'" >/dev/null
pq "UPDATE replacement SET status='cancelled', finished_at=now() WHERE status IN ('pending','approved') AND machine_id IN (SELECT id FROM machine WHERE customer_slug=:'c')" >/dev/null
pq "DELETE FROM session WHERE groups::text LIKE '%' || :'c' || '%'" >/dev/null || true
echo "portal: computers retired, tokens erased, this customer's sessions ended"

# 4. authentik groups (nobody of this customer can sign in to anything any more)
source scripts/lib/authentik.sh
ak_login
for g in "tech-${slug}" "cust-${slug}-users"; do
  gp="$(ak_req GET "core/groups/?name=${g}" | jq -r '.results[0].pk // empty')"
  if [[ -n "$gp" ]]; then ak_req DELETE "core/groups/${gp}/" >/dev/null; echo "authentik: group ${g} deleted"; fi
done
audit "suspended"

if [[ "$mode" == suspend ]]; then
  echo
  echo "Suspended. All access is cut; the data is untouched (backups on the NAS, InfluxDB, Loki, Grafana org)."
  echo "Keep it for your retention period, then:  scripts/offboard-customer.sh ${slug} --purge --confirm ${slug}"
  exit 0
fi

echo
echo "-- purge: PERMANENT deletion"
# 5. backup repositories
for r in $repos; do
  name="$(basename "$r")"; [[ "$name" == "${slug}-"* ]] || continue
  mountpoint -q "$BK" && [[ -f "$BK/.msp-backup-root" ]] || { echo "NAS share not mounted: repositories NOT deleted" >&2; break; }
  size="$(du -sh "$r" | cut -f1)"; rm -rf -- "${BK:?}/${name:?}"; echo "NAS: deleted ${name} (${size})"
done
rm -rf -- "generated/backup/credentials/${slug:?}" "generated/credentials/${slug:?}" "generated/agents/${slug:?}"

# 6. portal data (catalog, jobs, schedules cascade from the customer row; audit rows are kept)
pq "DELETE FROM customer WHERE slug=:'c'" >/dev/null
echo "portal: customer, computers, catalog, jobs and schedules deleted (audit kept)"

# 7. metrics, dashboards, logs
bid="$(influx_raw bucket list --org msp --name "cust_${slug}" --json 2>/dev/null | jq -r '.[0].id // empty')"
if [[ -n "$bid" ]]; then
  influx_raw auth list --org msp --json | jq -r --arg d "grafana-read ${slug}" '.[]|select(.description==$d)|.id' | while read -r a; do influx_raw auth delete --id "$a" >/dev/null; done
  influx_raw bucket delete --id "$bid" >/dev/null && echo "influx: bucket cust_${slug} deleted"
fi
gid="$(curl -fsS -u "$GF_AUTH" "$GF_URL/api/orgs/name/${slug}" 2>/dev/null | jq -r '.id // empty' || true)"
if [[ -n "$gid" ]]; then curl -fsS -u "$GF_AUTH" -X DELETE "$GF_URL/api/orgs/${gid}" >/dev/null && echo "grafana: org ${slug} deleted"; fi
# Loki wants RFC3339 times; the selector must name at least one label (every agent line carries "site")
if resp="$(docker compose exec -T gateway curl -fsS -X POST -H "X-Scope-OrgID: ${slug}" -G      --data-urlencode 'query={site=~".+"}' --data-urlencode 'start=2000-01-01T00:00:00Z'      --data-urlencode "end=$(date -u +%FT%TZ)" http://loki:3100/loki/api/v1/delete </dev/null 2>&1)"; then
  echo "loki: delete request filed for tenant ${slug} (the compactor removes the data within a few hours)"
else
  echo "loki: could NOT file the delete request (${resp}); the tenant's logs expire on their own after the retention period" >&2
fi
awk -F'\t' -v c="$slug" '$1!=c' generated/customers.tsv > generated/customers.tsv.new && mv generated/customers.tsv.new generated/customers.tsv
scripts/render-config.sh >/dev/null && docker compose up -d grafana >/dev/null 2>&1 && echo "grafana: org mapping reloaded"
sleep 8; scripts/update-customer-hub.sh || echo "  (the customer picker was not updated; run scripts/update-customer-hub.sh)"
audit "purged"
echo
echo "Purged. A line was added to generated/offboard-audit.log. Remember the customer's vault entries (repo passwords) and any off-site copies."
