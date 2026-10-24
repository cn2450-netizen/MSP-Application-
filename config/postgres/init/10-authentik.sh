#!/bin/sh
# Runs once, on first start of an empty data volume. authentik gets its own
# non-superuser role and database; later apps (ticketing) get the same treatment.
set -e

AUTHENTIK_PW="$(cat /run/secrets/authentik_db_password)"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<SQL
CREATE ROLE authentik LOGIN PASSWORD '${AUTHENTIK_PW}';
CREATE DATABASE authentik OWNER authentik;
REVOKE ALL ON DATABASE authentik FROM PUBLIC;
SQL
