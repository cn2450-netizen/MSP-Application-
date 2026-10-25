#!/usr/bin/env bash
# One-time (and safe to re-run) authentik configuration:
#   1. Enforce MFA for every login (WebAuthn or TOTP; users enrol on first sign-in)
#   2. Create the msp-admins group
#   3. Register Grafana as an OIDC application, visible only to groups bound to it
#
# Run on the Docker host after `docker compose up -d` once authentik is healthy:
#   scripts/setup-authentik.sh
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
source scripts/lib/authentik.sh

command -v jq >/dev/null || { echo "jq is required"; exit 1; }
ak_login

echo "[0/3] Check akadmin does not use a known password"
if docker compose exec -T authentik-server ak shell -c "
from authentik.core.models import User
u = User.objects.get(username='akadmin')
print('LEGACY' if u.check_password('file:///run/secrets/authentik_bootstrap_password') else 'OK')
" </dev/null 2>/dev/null | grep -q LEGACY; then
  docker compose exec -T authentik-server ak shell -c "
from authentik.core.models import User
u = User.objects.get(username='akadmin')
u.set_password(open('/run/secrets/authentik_bootstrap_password').read().strip()); u.save()
" </dev/null >/dev/null 2>&1
  echo "    akadmin had a guessable password from an older config: replaced with secrets/authentik_bootstrap_password"
else
  echo "    ok"
fi

echo "[1/3] Enforce MFA"
stage="$(ak_req GET 'stages/authenticator/validate/?name=default-authentication-mfa-validation' | jq -r '.results[0].pk')"
totp="$(ak_req GET 'stages/authenticator/totp/?name=default-authenticator-totp-setup' | jq -r '.results[0].pk')"
webauthn="$(ak_req GET 'stages/authenticator/webauthn/?name=default-authenticator-webauthn-setup' | jq -r '.results[0].pk')"
for v in stage totp webauthn; do [[ -n "${!v}" && "${!v}" != null ]] || { echo "default $v stage not found"; exit 1; }; done
ak_req PATCH "stages/authenticator/validate/${stage}/" "$(jq -n --arg t "$totp" --arg w "$webauthn" \
  '{not_configured_action:"configure",device_classes:["webauthn","totp"],configuration_stages:[$t,$w]}')" >/dev/null
echo "    users without a second factor are now forced to enrol one at sign-in"

echo "[2/3] Groups"
admins="$(ak_group msp-admins)"
echo "    msp-admins ($admins)"

echo "[3/3] Grafana application (OIDC)"
auth_flow="$(ak_req GET 'flows/instances/?slug=default-provider-authorization-implicit-consent' | jq -r '.results[0].pk')"
inv_flow="$(ak_req GET 'flows/instances/?slug=default-provider-invalidation-flow' | jq -r '.results[0].pk')"
key="$(ak_req GET 'crypto/certificatekeypairs/?name=authentik%20Self-signed%20Certificate' | jq -r '.results[0].pk')"
maps="$(for s in openid email profile; do ak_req GET "propertymappings/provider/scope/?scope_name=$s" | jq -r '.results[]|select(.name|startswith("authentik default OAuth Mapping"))|.pk'; done | jq -R . | jq -sc .)"
secret="$(cat secrets/grafana_oauth_secret)"

provider_json="$(jq -n --arg af "$auth_flow" --arg inf "$inv_flow" --arg key "$key" --argjson maps "$maps" \
  --arg secret "$secret" --arg redirect "https://${GRAFANA_HOST}/login/generic_oauth" \
  '{name:"Grafana",authorization_flow:$af,invalidation_flow:$inf,client_type:"confidential",
    client_id:"grafana",client_secret:$secret,
    redirect_uris:[{matching_mode:"strict",url:$redirect}],
    signing_key:$key,property_mappings:$maps,issuer_mode:"per_provider"}')"
prov="$(ak_req GET 'providers/oauth2/?name=Grafana' | jq -r '.results[0].pk // empty')"
if [[ -n "$prov" ]]; then
  ak_req PATCH "providers/oauth2/${prov}/" "$provider_json" >/dev/null
else
  prov="$(ak_req POST providers/oauth2/ "$provider_json" | jq -r '.pk')"
fi

app_json="$(jq -n --argjson p "$prov" --arg url "https://${GRAFANA_HOST}/" \
  '{name:"Grafana",slug:"grafana",provider:$p,meta_launch_url:$url,group:"Monitoring",open_in_new_tab:false}')"
if ak_req GET 'core/applications/grafana/' >/dev/null 2>&1; then
  ak_req PATCH core/applications/grafana/ "$app_json" >/dev/null
else
  ak_req POST core/applications/ "$app_json" >/dev/null
fi
app="$(ak_req GET core/applications/grafana/ | jq -r '.pk')"

# With at least one binding, ONLY bound groups can open the app. Customer groups are
# added by add-customer.sh.
ak_bind_group "$app" "$admins"
echo "    Grafana provider $prov, application $app, access limited to bound groups"

echo
echo "Done. Next: sign in at https://${AUTH_HOST}/ as akadmin (password in secrets/authentik_bootstrap_password) — you will be asked to enrol an authenticator."
