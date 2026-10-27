#!/usr/bin/env bash
# Create (or fix the password of) the portal role and database in the running Postgres. Safe to re-run.
# Fresh installs get this from config/postgres/init/30-portal.sh; existing installs run this once.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -s secrets/portal_db_password ]] || { echo "missing secrets/portal_db_password - run scripts/init-secrets.sh first"; exit 1; }
PW="$(cat secrets/portal_db_password)"
[[ "$PW" =~ ^[0-9a-f]+$ ]] || { echo "unexpected characters in the generated password"; exit 1; }   # hex only: safe inside SQL

docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U msp_admin -d postgres <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'portal') THEN
    CREATE ROLE portal LOGIN PASSWORD '${PW}';
  ELSE
    ALTER ROLE portal WITH LOGIN PASSWORD '${PW}';
  END IF;
END \$\$;
SELECT 'CREATE DATABASE portal OWNER portal'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'portal')\gexec
REVOKE ALL ON DATABASE portal FROM PUBLIC;
SQL
echo "Portal database ready."
