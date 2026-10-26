#!/usr/bin/env bash
# Create (or fix the password of) the MeshCentral role and database in the running Postgres. Safe to re-run.
# Fresh installs get this from config/postgres/init/20-meshcentral.sh; existing installs run this once.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -s secrets/meshcentral_db_password ]] || { echo "missing secrets/meshcentral_db_password - run scripts/init-secrets.sh first"; exit 1; }
PW="$(cat secrets/meshcentral_db_password)"
[[ "$PW" =~ ^[0-9a-f]+$ ]] || { echo "unexpected characters in the generated password"; exit 1; }   # hex only: safe inside SQL

docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U msp_admin -d postgres <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'meshcentral') THEN
    CREATE ROLE meshcentral LOGIN PASSWORD '${PW}';
  ELSE
    ALTER ROLE meshcentral WITH LOGIN PASSWORD '${PW}';
  END IF;
END \$\$;
SELECT 'CREATE DATABASE meshcentral OWNER meshcentral'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'meshcentral')\gexec
REVOKE ALL ON DATABASE meshcentral FROM PUBLIC;
SQL
echo "MeshCentral database ready."
