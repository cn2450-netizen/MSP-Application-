#!/usr/bin/env bash
# Generates every secret the stack needs. Safe to re-run: existing files are never overwritten.
#
# ./secrets is mode 700 (host users other than you can't traverse it); the files inside
# are 644 because Docker bind-mounts them and the container users (postgres, grafana,
# influx, authentik) are different uids that must be able to read them.
set -euo pipefail
cd "$(dirname "$0")/.."

umask 077
mkdir -p secrets generated/gateway
chmod 700 secrets

gen() { # gen <name> [bytes]
  local f="secrets/$1"
  if [[ -e "$f" ]]; then echo "  keep   $f"; return; fi
  openssl rand -hex "${2:-32}" > "$f"
  chmod 644 "$f"
  echo "  create $f"
}

echo "Secrets:"
gen postgres_password
gen authentik_db_password
gen authentik_secret_key 64
gen authentik_bootstrap_password 16
gen influx_admin_password 16
gen influx_admin_token
gen grafana_admin_password 16
gen grafana_oauth_secret
gen meshcentral_db_password
gen meshcentral_oidc_secret
gen meshcentral_session_key 48

[[ -e .env ]] || { cp .env.example .env; echo "Created .env — edit hostnames before 'docker compose up'."; }
chmod 600 .env
# authentik reads its first-boot admin password from an env var (no file:// support), so mirror the secret there.
grep -q '^AUTHENTIK_BOOTSTRAP_PASSWORD=' .env || echo "AUTHENTIK_BOOTSTRAP_PASSWORD=$(cat secrets/authentik_bootstrap_password)" >> .env

# Gateway map must exist before nginx starts (empty = no agent can push yet).
[[ -e generated/gateway/loki.map ]] || : > generated/gateway/loki.map
# Same pattern as ./secrets: parent dir 700 keeps other host users out, while the
# mounted dir/file are readable by the unprivileged nginx uid inside the container.
chmod 700 generated
chmod 755 generated/gateway
chmod 644 generated/gateway/loki.map
[[ -e generated/customers.tsv ]]    || : > generated/customers.tsv

"$(dirname "$0")/render-config.sh"

echo
echo "authentik first login:  akadmin / $(cat secrets/authentik_bootstrap_password)   (sign in at https://<AUTH_HOST>/ — NOT /initial-setup/, which only works on an empty install)"
echo "Grafana break-glass:    msp-admin / $(cat secrets/grafana_admin_password)   (login form is disabled; API only)"
echo "OAuth client secret for Grafana (paste into the authentik provider): secrets/grafana_oauth_secret"
echo "Back up ./secrets somewhere safe and offline — losing it means losing the data keys."
