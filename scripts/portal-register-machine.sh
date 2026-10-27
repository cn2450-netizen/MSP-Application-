#!/usr/bin/env bash
# Make a backup machine known to the portal and give its agent a token to check in with. Idempotent.
#   scripts/portal-register-machine.sh <customer> <site> <hostname>
# The agent token ("<machine-id>.<secret>") goes into the machine's credentials file (line "portal token:") and is
# embedded in its installer. Only a SHA-256 hash of the secret is stored in the portal database.
# Called by backup-add-machine.sh and build-backup-installer.sh; run it by hand for machines registered earlier.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

cust="${1:?usage: portal-register-machine.sh <customer> <site> <hostname>}"
site="${2:?site required}"
host="$(tr 'A-Z_' 'a-z-' <<<"${3:?hostname required}")"
[[ "$cust" =~ ^[a-z0-9][a-z0-9-]{1,30}$ && "$site" =~ ^[a-z0-9][a-z0-9-]{0,30}$ && "$host" =~ ^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$ ]] || { echo "invalid name" >&2; exit 2; }
cred="generated/backup/credentials/${cust}/${site}/${host}.txt"
[[ -f "$cred" ]] || { echo "no credentials file ${cred}: run scripts/backup-add-machine.sh first" >&2; exit 1; }
cname="$(awk -F'\t' -v s="$cust" '$1==s{print $2}' generated/customers.tsv)"
[[ -n "$cname" ]] || { echo "unknown customer ${cust}" >&2; exit 1; }
repo_user="${cust}-${site}-${host}"

psql_portal() { docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -qtA -U msp_admin -d portal "$@"; }

id="$(psql_portal -v c="$cust" -v cn="$cname" -v s="$site" -v h="$host" -v u="$repo_user" <<'SQL'
INSERT INTO customer(slug, name) VALUES (:'c', :'cn') ON CONFLICT (slug) DO UPDATE SET name = EXCLUDED.name;
INSERT INTO site(customer_slug, slug) VALUES (:'c', :'s') ON CONFLICT DO NOTHING;
INSERT INTO machine(customer_slug, site_slug, name, repo_user) VALUES (:'c', :'s', :'h', :'u')
  ON CONFLICT (repo_user) DO UPDATE SET retired = false
  RETURNING id;
SQL
)"
id="$(grep -Eo '^[0-9a-f-]{36}' <<<"$id" | head -1)"
[[ -n "$id" ]] || { echo "could not register the machine in the portal database" >&2; exit 1; }

token="$(sed -n 's/^portal token:[[:space:]]*//p' "$cred")"
if [[ -z "$token" ]]; then
  token="${id}.$(openssl rand -hex 24)"
  ( umask 077; printf 'portal token:     %s\n' "$token" >> "$cred" )
elif [[ "${token%%.*}" != "$id" ]]; then
  echo "the token in ${cred} does not belong to this machine record; remove that line and re-run" >&2; exit 1
fi
hash="$(printf '%s' "${token#*.}" | sha256sum | cut -d' ' -f1)"
psql_portal -v id="$id" -v h="$hash" <<'SQL' >/dev/null
UPDATE machine SET token_hash = :'h' WHERE id = :'id';
SQL
echo "portal: ${repo_user} registered (machine ${id})"
