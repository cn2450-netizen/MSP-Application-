#!/usr/bin/env bash
# Give each customer's techs access to that customer's device groups.
#   scripts/mesh-grant.sh [customer]        (default: every customer)
#
# MeshCentral takes its user groups from authentik (OIDC group sync) and refuses to create them by hand, so
# "tech-<customer>" only exists in MeshCentral after someone in that authentik group has signed in once.
# This script is safe to re-run: run it after a tech's first sign-in, and after adding sites.
# Rights granted: manage computers 4 + remote control 8 + agent console 16 + server files 32 + wake 64 + notes 128 = 252.
# Needs a MeshCentral login token: scripts/mesh-token.sh set
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
source scripts/lib/meshcentral.sh
RIGHTS=252

mesh_login || exit 1
only="${1:-}"
pending=0
while IFS=$'\t' read -r c _name _created; do
  [[ -z "${c:-}" ]] && continue
  [[ -n "$only" && "$c" != "$only" ]] && continue
  ugid="$(mesh_usergroup_id "tech-${c}")"
  if [[ -z "$ugid" ]]; then
    echo "  ${c}: MeshCentral has no 'tech-${c}' group yet (it appears after someone in that authentik group first signs in)"
    pending=$((pending+1)); continue
  fi
  while IFS=$'\t' read -r sc ss _sn _sd _sid; do
    [[ "$sc" == "$c" ]] || continue
    gid="$(mesh_group_id "${c} / ${ss}")"
    [[ -n "$gid" ]] || { echo "  ${c}/${ss}: no device group yet (run scripts/mesh-site.sh ${c} ${ss})"; continue; }
    out="$(mc AddToUserGroup --id "$gid" --groupid "$ugid" --rights "$RIGHTS")"
    echo "  tech-${c} -> '${c} / ${ss}': ${out}"
  done < generated/sites.tsv
done < generated/customers.tsv
[[ "$pending" == 0 ]] || echo "(${pending} customer(s) waiting for a first tech sign-in; re-run this script afterwards)"
