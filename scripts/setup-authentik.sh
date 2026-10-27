#!/usr/bin/env bash
# One-time (and safe to re-run) authentik configuration:
#   1. Enforce MFA for every login (TOTP authenticator app; users enrol on first sign-in)
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
for v in stage totp; do [[ -n "${!v}" && "${!v}" != null ]] || { echo "default $v stage not found"; exit 1; }; done
# TOTP only: works with Google/Microsoft Authenticator, Authy, etc. Deliberately no WebAuthn: a passkey kept in
# the same password manager as the password would not be a real second factor.
ak_req PATCH "stages/authenticator/validate/${stage}/" "$(jq -n --arg t "$totp" \
  '{not_configured_action:"configure",device_classes:["totp"],configuration_stages:[$t]}')" >/dev/null
echo "    users without an authenticator app are now forced to enrol one at sign-in"

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
    signing_key:$key,property_mappings:$maps,issuer_mode:"per_provider",
    grant_types:["authorization_code","refresh_token"]}')"   # empty (the default) rejects every login with invalid_request
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

echo "MeshCentral application (OIDC)"
if [[ -n "${MESH_HOST:-}" && -s secrets/meshcentral_oidc_secret ]]; then
  mesh_json="$(jq -n --arg af "$auth_flow" --arg inf "$inv_flow" --arg key "$key" --argjson maps "$maps" \
    --arg secret "$(cat secrets/meshcentral_oidc_secret)" --arg redirect "https://${MESH_HOST}/auth-oidc-callback" \
    '{name:"MeshCentral",authorization_flow:$af,invalidation_flow:$inf,client_type:"confidential",
      client_id:"meshcentral",client_secret:$secret,
      redirect_uris:[{matching_mode:"strict",url:$redirect}],
      signing_key:$key,property_mappings:$maps,issuer_mode:"per_provider",
      grant_types:["authorization_code","refresh_token"]}')"
  mprov="$(ak_req GET 'providers/oauth2/?name=MeshCentral' | jq -r '.results[0].pk // empty')"
  if [[ -n "$mprov" ]]; then ak_req PATCH "providers/oauth2/${mprov}/" "$mesh_json" >/dev/null
  else mprov="$(ak_req POST providers/oauth2/ "$mesh_json" | jq -r '.pk')"; fi
  mapp_json="$(jq -n --argjson p "$mprov" --arg url "https://${MESH_HOST}/auth-oidc" \
    '{name:"Remote Access",slug:"meshcentral",provider:$p,meta_launch_url:$url,group:"Remote",open_in_new_tab:false}')"
  if ak_req GET 'core/applications/meshcentral/' >/dev/null 2>&1; then ak_req PATCH core/applications/meshcentral/ "$mapp_json" >/dev/null
  else ak_req POST core/applications/ "$mapp_json" >/dev/null; fi
  mapp="$(ak_req GET core/applications/meshcentral/ | jq -r '.pk')"
  # Remote access is for staff only: msp-admins here, each customer's tech-<slug> group via add-customer / sync-customer-groups.
  ak_bind_group "$mapp" "$admins"
  echo "    MeshCentral provider $mprov, application $mapp, access limited to bound groups"
else
  echo "    skipped (MESH_HOST not set or secrets/meshcentral_oidc_secret missing; run scripts/init-secrets.sh)"
fi

echo "Backup Portal application (OIDC)"
if [[ -n "${PORTAL_HOST:-}" && -s secrets/portal_oidc_secret ]]; then
  portal_json="$(jq -n --arg af "$auth_flow" --arg inf "$inv_flow" --arg key "$key" --argjson maps "$maps"     --arg secret "$(cat secrets/portal_oidc_secret)" --arg redirect "https://${PORTAL_HOST}/auth/callback"     '{name:"Backup Portal",authorization_flow:$af,invalidation_flow:$inf,client_type:"confidential",
      client_id:"portal",client_secret:$secret,
      redirect_uris:[{matching_mode:"strict",url:$redirect}],
      signing_key:$key,property_mappings:$maps,issuer_mode:"per_provider",
      grant_types:["authorization_code"]}')"
  pprov="$(ak_req GET 'providers/oauth2/?name=Backup%20Portal' | jq -r '.results[0].pk // empty')"
  if [[ -n "$pprov" ]]; then ak_req PATCH "providers/oauth2/${pprov}/" "$portal_json" >/dev/null
  else pprov="$(ak_req POST providers/oauth2/ "$portal_json" | jq -r '.pk')"; fi
  papp_json="$(jq -n --argjson p "$pprov" --arg url "https://${PORTAL_HOST}/"     '{name:"Backup Portal",slug:"portal",provider:$p,meta_launch_url:$url,group:"Backup",open_in_new_tab:false}')"
  if ak_req GET 'core/applications/portal/' >/dev/null 2>&1; then ak_req PATCH core/applications/portal/ "$papp_json" >/dev/null
  else ak_req POST core/applications/ "$papp_json" >/dev/null; fi
  papp="$(ak_req GET core/applications/portal/ | jq -r '.pk')"
  # Staff of every customer, and each customer's own users (the portal itself limits them to their own machines).
  ak_bind_group "$papp" "$admins"
  echo "    Portal provider $pprov, application $papp, access limited to bound groups"
else
  echo "    skipped (PORTAL_HOST not set or secrets/portal_oidc_secret missing; run scripts/init-secrets.sh)"
fi

echo
echo "Done. Next: sign in at https://${AUTH_HOST}/ as akadmin (password in secrets/authentik_bootstrap_password) — you will be asked to enrol an authenticator."
