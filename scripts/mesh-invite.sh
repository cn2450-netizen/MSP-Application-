#!/usr/bin/env bash
# Print an agent invitation link for a site's device group, for a person to open on the machine to enrol it
# (MeshCentral shows an install page; no file to hand over).
#   scripts/mesh-invite.sh <customer> <site> [hours]       default 24 hours; 0 = never expires (avoid)
# Anyone with the link can enrol a machine into that customer's group until it expires: send it privately
# and keep the lifetime short. Needs a MeshCentral login token: scripts/mesh-token.sh set
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
source scripts/lib/meshcentral.sh

cust="${1:?usage: mesh-invite.sh <customer> <site> [hours]}"; site="${2:?site required}"; hours="${3:-24}"
[[ "$hours" =~ ^[0-9]+$ ]] || { echo "hours must be a number" >&2; exit 2; }
[[ "$hours" == 0 ]] && echo "WARNING: a link that never expires stays a standing way to enrol machines into this customer." >&2

mesh_login || exit 1
gid="$(mesh_group_id "${cust} / ${site}")"
[[ -n "$gid" ]] || { echo "no device group '${cust} / ${site}': run scripts/mesh-site.sh ${cust} ${site}" >&2; exit 1; }
out="$(mc GenerateInviteLink --id "$gid" --hours "$hours")"
url="$(grep -oE 'https?://[^[:space:]]+' <<<"$out" | head -1 || true)"
[[ -n "$url" ]] || { echo "could not generate an invite link: ${out}" >&2; exit 1; }
# meshctrl builds the link from the address it connected to (127.0.0.1); point it at the public name instead.
url="$(sed -E "s#^https?://[^/]+#https://${MESH_HOST}#" <<<"$url")"
echo "Invitation for '${cust} / ${site}' (valid ${hours}h; send it privately):"
echo "  ${url}"
