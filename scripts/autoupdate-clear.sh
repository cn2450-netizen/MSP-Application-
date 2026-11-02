#!/usr/bin/env bash
# Clear the "needs attention" flag (and the attempt counters) on a computer the auto-updater gave up on, so it is tried
# again. Fix the cause first (antivirus blocking the installer, the MeshCentral agent offline, no disk space ...).
#   scripts/autoupdate-clear.sh <company-slug> <computer-name>
#   scripts/autoupdate-clear.sh --list          computers that are flagged now
set -euo pipefail
cd "$(dirname "$0")/.."
psql_portal() { docker compose exec -T postgres psql -U portal -d portal -v ON_ERROR_STOP=1 -X -q -A -t -F '  ' "$@"; }
if [[ "${1:-}" == "--list" ]]; then
  psql_portal -c "SELECT customer_slug, host, failures, to_char(flagged_at, 'YYYY-MM-DD HH24:MI'), last_result FROM agent_update WHERE flagged ORDER BY flagged_at"
  exit 0
fi
cust="${1:?usage: autoupdate-clear.sh <company-slug> <computer-name>  |  --list}"; host="${2:?computer name required}"
[[ "$cust" =~ ^[a-z0-9][a-z0-9-]{1,30}$ && "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,62}[A-Za-z0-9])?$ ]] || { echo "invalid name" >&2; exit 2; }
host="${host,,}"
psql_portal -c "DELETE FROM agent_update WHERE customer_slug = '${cust}' AND host = '${host}' RETURNING host" | grep -q . && echo "Cleared ${cust}/${host}: it will be tried again on the next run." || echo "Nothing to clear for ${cust}/${host}."
