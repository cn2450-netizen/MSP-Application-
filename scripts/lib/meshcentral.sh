#!/usr/bin/env bash
# Helpers for driving MeshCentral from scripts on the Docker host. Source this file (cwd = repo root, .env loaded).
#
# AUTH MODEL: there is deliberately no standing admin credential. A person signs in (SSO + MFA), creates a
# short-lived "login token" under My Account -> Create login token, and hands it to scripts via
# scripts/mesh-token.sh (or MESH_TOKEN_USER / MESH_TOKEN_PASS). The token expires on its own and can be revoked.
#
# meshctrl runs INSIDE the container against ws://127.0.0.1:4430 (TLS is terminated by NPM, so wss:// does not work).

MESH_CTL=/opt/meshcentral/meshcentral/meshctrl
MESH_TOKEN_FILE=generated/mesh-token
MESH_CONSENT_DEFAULT=71      # 7 = notify the user for desktop/terminal/files, 64 = on-screen toolbar while connected
MESH_USER="" MESH_PASS=""

mesh_login() {
  if [[ -n "${MESH_TOKEN_USER:-}" && -n "${MESH_TOKEN_PASS:-}" ]]; then
    MESH_USER="$MESH_TOKEN_USER"; MESH_PASS="$MESH_TOKEN_PASS"
  elif [[ -s "$MESH_TOKEN_FILE" ]]; then
    MESH_USER="$(sed -n 1p "$MESH_TOKEN_FILE")"; MESH_PASS="$(sed -n 2p "$MESH_TOKEN_FILE")"
  else
    echo "No MeshCentral login token. In MeshCentral: My Account -> Create login token (expiry 1-2 hours)," >&2
    echo "then give it to scripts/mesh-token.sh set (it reads the username and password from stdin)." >&2
    return 1
  fi
  local out; out="$(mc UserInfo | head -3)"
  if [[ "$out" == *"Invalid login"* || -z "$out" ]]; then
    echo "The MeshCentral login token was rejected (expired, revoked or mistyped). Create a new one." >&2
    return 1
  fi
  MESH_WHO="$(sed -n 's/^name: *//p' <<<"$out" | head -1)"
}

# mc <meshctrl args...>  -> runs meshctrl in the container, authenticated with the token
mc() {
  docker compose exec -T meshcentral node "$MESH_CTL" "$@" \
    --url ws://127.0.0.1:4430 --loginuser "$MESH_USER" --loginpass "$MESH_PASS" </dev/null 2>&1
}

mesh_group_id()      { mc ListDeviceGroups --json | jq -r --arg n "$1" '.[]|select(.name==$n)|._id' | head -1; }
mesh_usergroup_id()  { mc ListUserGroups --json | jq -r --arg n "$1" '.[]|select(.name==$n)|._id' | head -1; }

# mesh_http_get <path-and-query> <output-file>   (the same request meshctrl makes, but over plain HTTP)
mesh_http_get() {
  local auth="x-meshauth: $(printf %s "$MESH_USER" | base64 -w0),$(printf %s "$MESH_PASS" | base64 -w0)"
  curl -sS -m 180 -o "$2" -w '%{http_code}' -H "$auth" -H "Host: ${MESH_HOST}" -H "X-Forwarded-Proto: https" \
    "http://${BIND_ADDR}:${MESH_PORT}$1"
}
