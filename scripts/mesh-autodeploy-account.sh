#!/usr/bin/env bash
# The limited MeshCentral account that scripts/monitoring-autodeploy.sh signs in with (a LOCAL account with a long
# random password: SSO users cannot sign in unattended).
#   scripts/mesh-autodeploy-account.sh create   make the account, store its login in generated/mesh-autodeploy-token (mode 600)
#   scripts/mesh-autodeploy-account.sh grant    give it rights on every "<customer> / <site>" device group (run after adding sites)
#   scripts/mesh-autodeploy-account.sh status   does the stored login work, and where does it have rights
#   scripts/mesh-autodeploy-account.sh remove   delete the account and the stored login (revokes it at once)
# create/grant/remove need YOUR short-lived login token (scripts/mesh-token.sh set). The account is NOT a site admin and
# has no user-management rights: only 4 manage computers + 8 remote control + 16 agent console + 32 server files +
# 64 wake + 128 notes + 131072 remote commands = 131324 on customer device groups. (Remote commands are what the installer
# push and the service restart run through; without them MeshCentral answers "Access denied".)
# The password reaches MeshCentral once, as a meshctrl argument on this host (visible to local root for a moment).
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
NAME=svc-autodeploy
FILE=generated/mesh-autodeploy-token
RIGHTS=131324      # 252 + 131072 (remote commands): RunCommand answers "Access denied" without it
source scripts/lib/meshcentral.sh
cmd="${1:-}"

grant() {
  local n=0
  while IFS=$'\t' read -r c s _rest; do
    [[ -z "${c:-}" ]] && continue
    gid="$(mesh_group_id "${c} / ${s}")"
    [[ -n "$gid" ]] || { echo "  ${c}/${s}: no device group yet"; continue; }
    out="$(mc AddUserToDeviceGroup --id "$gid" --userid "user//${NAME}" --rights "$RIGHTS")"
    echo "  '${c} / ${s}': ${out}"; n=$((n+1))
  done < generated/sites.tsv
  echo "rights set on ${n} device group(s)"
}

case "$cmd" in
  create)
    mesh_login || exit 1
    [[ ! -s "$FILE" ]] || { echo "an auto-deploy login already exists ($FILE): use 'remove' first to start over" >&2; exit 1; }
    pw="$(openssl rand -base64 48 | tr -dc 'A-HJ-NP-Za-km-z2-9' | head -c 40)"
    out="$(mc AddUser --user "$NAME" --pass "$pw" --realname "Monitoring auto-deploy (automation)")"
    echo "AddUser: ${out}"
    grep -qi "ok\|added\|success" <<<"$out" || { echo "MeshCentral did not accept the account" >&2; exit 1; }
    ( umask 077; printf '%s\n%s\n' "$NAME" "$pw" > "$FILE" )
    echo "login stored in ${FILE}"
    grant ;;
  grant)
    mesh_login || exit 1
    grant ;;
  status)
    [[ -s "$FILE" ]] || { echo "no stored auto-deploy login"; exit 1; }
    MESH_TOKEN_USER="$(sed -n 1p "$FILE")" MESH_TOKEN_PASS="$(sed -n 2p "$FILE")"
    mesh_login && echo "stored login works (signed in as ${MESH_WHO})"
    mc ListDeviceGroups --json | jq -r '.[]|.name' | sed 's/^/  can see: /' ;;
  remove)
    mesh_login || exit 1
    out="$(mc RemoveUser --userid "user//${NAME}" 2>&1 || true)"; echo "RemoveUser: ${out}"
    [[ -f "$FILE" ]] && shred -u "$FILE" && echo "stored login deleted" ;;
  *) echo "usage: scripts/mesh-autodeploy-account.sh create|grant|status|remove" >&2; exit 2 ;;
esac
