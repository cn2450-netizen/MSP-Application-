#!/usr/bin/env bash
# Hold a short-lived MeshCentral login token for the other mesh-*.sh scripts.
#   scripts/mesh-token.sh set      reads the token's username (line 1) and password (line 2) from stdin
#   scripts/mesh-token.sh check    verifies it still works
#   scripts/mesh-token.sh clear    securely deletes it
# The token is stored in generated/mesh-token (mode 600; parent dir 700). It expires by itself; clear it when done.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
source scripts/lib/meshcentral.sh

case "${1:-}" in
  set)
    IFS= read -r user || true; IFS= read -r pass || true      # two separate `head -n1` calls would lose line 2 to the first one's buffering
    user="${user%$'\r'}"; pass="${pass%$'\r'}"
    [[ "$user" == "~t:"* && -n "$pass" ]] || { echo "expected 2 lines: the token username (starts with ~t:) and its password" >&2; exit 1; }
    ( umask 077; printf '%s\n%s\n' "$user" "$pass" > "$MESH_TOKEN_FILE" )
    if mesh_login; then echo "Token stored and valid (signed in as ${MESH_WHO})."
    else shred -u "$MESH_TOKEN_FILE"; echo "Token rejected and discarded." >&2; exit 1; fi ;;
  check)
    mesh_login && echo "Token valid (signed in as ${MESH_WHO})." ;;
  clear)
    if [[ -f "$MESH_TOKEN_FILE" ]]; then shred -u "$MESH_TOKEN_FILE"; echo "Token deleted."; else echo "No token stored."; fi ;;
  *) echo "usage: scripts/mesh-token.sh set|check|clear" >&2; exit 2 ;;
esac
