#!/usr/bin/env bash
# Helpers for talking to authentik's API from scripts on the Docker host. Source this file.
# Needs: cwd = repo root, .env loaded (BIND_ADDR, AUTHENTIK_PORT), jq, curl, docker compose.
#
# No long-lived API token exists: ak_login mints a 1-hour token for akadmin via `ak shell`
# and ak_logout (run automatically on exit) deletes it again.

AK_API="http://${BIND_ADDR:-127.0.0.1}:${AUTHENTIK_PORT:-9000}/api/v3"
AK_TOKEN_ID="script-$$-$(date +%s)"
AK_KEY=""

ak_logout() {
  if [[ -n "$AK_KEY" ]]; then
    curl -fsS -X DELETE -H "Authorization: Bearer $AK_KEY" "$AK_API/core/tokens/${AK_TOKEN_ID}/" >/dev/null 2>&1 || true
    AK_KEY=""
  fi
}

ak_login() {
  AK_KEY="$(docker compose exec -T authentik-server ak shell -c "
from datetime import timedelta
from django.utils import timezone
from authentik.core.models import Token, User, TokenIntents
u = User.objects.get(username='akadmin')
t, _ = Token.objects.update_or_create(identifier='${AK_TOKEN_ID}', defaults=dict(
    user=u, intent=TokenIntents.INTENT_API, expiring=True,
    expires=timezone.now() + timedelta(hours=1), description='temporary, created by a setup script'))
print('KEYSTART' + t.key + 'KEYEND')
" </dev/null 2>/dev/null | sed -n 's/.*KEYSTART\(.*\)KEYEND.*/\1/p')"
  if [[ -z "$AK_KEY" ]]; then
    echo "could not create an authentik API token (is authentik up and 'akadmin' present?)" >&2
    return 1
  fi
  trap ak_logout EXIT
}

# ak_req METHOD path [json-body]  -> prints the JSON response
ak_req() {
  local method="$1" path="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    curl -fsS -X "$method" -H "Authorization: Bearer $AK_KEY" -H 'Content-Type: application/json' "$AK_API/$path" -d "$body"
  else
    curl -fsS -X "$method" -H "Authorization: Bearer $AK_KEY" "$AK_API/$path"
  fi
}

# ak_group <name>  -> prints the group's pk, creating the group if needed
ak_group() {
  local name="$1" pk
  pk="$(ak_req GET "core/groups/?name=$(jq -rn --arg n "$name" '$n|@uri')" | jq -r --arg n "$name" '.results[]|select(.name==$n)|.pk' | head -1)"
  if [[ -z "$pk" ]]; then
    pk="$(ak_req POST core/groups/ "$(jq -n --arg n "$name" '{name:$n,is_superuser:false}')" | jq -r '.pk')"
  fi
  printf '%s' "$pk"
}

# ak_bind_group <application-uuid> <group-uuid>  (idempotent)
# NB: the bindings endpoint ignores a `group` filter, so list by target and match client-side.
ak_bind_group() {
  local app="$1" group="$2" n
  n="$(ak_req GET "policies/bindings/?target=${app}&page_size=500" | jq --arg g "$group" '[.results[]|select(.group==$g)]|length')"
  if [[ "$n" == "0" ]]; then
    ak_req POST policies/bindings/ "$(jq -n --arg t "$app" --arg g "$group" \
      '{target:$t,group:$g,order:0,enabled:true,negate:false,timeout:30,failure_result:false}')" >/dev/null
  fi
}
