#!/bin/sh
# Runs once, on first start of an empty data volume (after 20-meshcentral.sh).
# Existing installs use scripts/init-portal-db.sh instead.
set -e

PORTAL_PW="$(cat /run/secrets/portal_db_password)"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<SQL
CREATE ROLE portal LOGIN PASSWORD '${PORTAL_PW}';
CREATE DATABASE portal OWNER portal;
REVOKE ALL ON DATABASE portal FROM PUBLIC;
SQL
