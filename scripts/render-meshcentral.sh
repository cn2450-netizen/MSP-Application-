#!/usr/bin/env bash
# Render generated/meshcentral/config.json from config/meshcentral/config.json.tmpl + .env + ./secrets.
# The file holds secrets (database password, OIDC client secret, session key), so it lives under ./generated
# (parent dir mode 700) and is mounted read-only into the container. Re-run after changing hostnames/secrets,
# then `docker compose up -d meshcentral`.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
: "${MESH_HOST:?MESH_HOST not set in .env}" "${AUTH_HOST:?AUTH_HOST not set in .env}" "${NPM_IP:?NPM_IP not set in .env}"
for f in meshcentral_db_password meshcentral_oidc_secret meshcentral_session_key; do
  [[ -s "secrets/$f" ]] || { echo "missing secrets/$f - run scripts/init-secrets.sh first"; exit 1; }
done

mkdir -p generated/meshcentral
chmod 755 generated/meshcentral
umask 077
MESH_HOST="$MESH_HOST" AUTH_HOST="$AUTH_HOST" NPM_IP="$NPM_IP" python3 - <<'PY'
import json, os, re, sys
t = open("config/meshcentral/config.json.tmpl", encoding="utf-8").read()
def sec(n): return open("secrets/" + n, encoding="utf-8").read().strip()
vals = {"MESH_HOST": os.environ["MESH_HOST"], "AUTH_HOST": os.environ["AUTH_HOST"], "NPM_IP": os.environ["NPM_IP"],
        "DB_PASSWORD": sec("meshcentral_db_password"), "OIDC_SECRET": sec("meshcentral_oidc_secret"),
        "SESSION_KEY": sec("meshcentral_session_key")}
for k, v in vals.items():
    t = t.replace("@@" + k + "@@", json.dumps(v)[1:-1])      # JSON-escape, we are inside a string literal
left = re.findall(r"@@[A-Z_]+@@", t)
if left: sys.exit(f"unfilled placeholders: {left}")
json.loads(t)                                                # must be valid JSON before it reaches the container
open("generated/meshcentral/config.json", "w", encoding="utf-8", newline="\n").write(t)
PY
chmod 644 generated/meshcentral/config.json   # readable by the container user; the parent ./generated is mode 700
echo "Rendered generated/meshcentral/config.json"
