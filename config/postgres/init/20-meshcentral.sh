#!/bin/sh
# Runs once, on first start of an empty data volume (after 10-authentik.sh).
# Existing installs use scripts/init-meshcentral-db.sh instead.
set -e

MESH_PW="$(cat /run/secrets/meshcentral_db_password)"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<SQL
CREATE ROLE meshcentral LOGIN PASSWORD '${MESH_PW}';
CREATE DATABASE meshcentral OWNER meshcentral;
REVOKE ALL ON DATABASE meshcentral FROM PUBLIC;
SQL
