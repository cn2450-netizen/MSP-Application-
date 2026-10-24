#!/usr/bin/env bash
# Cross-tenant isolation regression test. Run on the Docker host against a live stack:
#   scripts/test-isolation.sh
# Creates two throwaway customers (testco, otherco) on first run. Prints PASS/FAIL per check.
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
GW="http://127.0.0.1:${GATEWAY_PORT}"
GF="http://127.0.0.1:${GRAFANA_PORT}"
GFA="msp-admin:$(cat secrets/grafana_admin_password)"
pass=0; fail=0
check() { # check <name> <expected> <actual>
  if [[ "$2" == "$3" ]]; then echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1  (expected '$2', got '$3')"; fail=$((fail+1)); fi
}
cred() { grep -E "^$2" "generated/credentials/$1.txt" | sed -E 's/^[^:]*:[ ]*//'; }

[[ -f generated/credentials/otherco.txt ]] || scripts/add-customer.sh otherco "Other Co" 30 >/dev/null 2>&1

A_W=$(cred testco  "influx WRITE"); A_L=$(cred testco  "loki push")
B_W=$(cred otherco "influx WRITE"); B_L=$(cred otherco "loki push")
NOW=$(date +%s%N)

# ── Loki: push via gateway
code() { curl -s -o /dev/null -w "%{http_code}" "$@"; }
push() { # push <key> <msg> [extra curl args]
  local key="$1" msg="$2"; shift 2
  code -X POST "$GW/loki/api/v1/push" -H "Authorization: Bearer $key" -H 'Content-Type: application/json' "$@" \
    -d "{\"streams\":[{\"stream\":{\"host\":\"pc-$msg\"},\"values\":[[\"$NOW\",\"$msg\"]]}]}"
}
check "loki push testco key"                 204 "$(push "$A_L" secretA)"
check "loki push otherco key"                204 "$(push "$B_L" secretB)"
check "loki push bad key rejected"           401 "$(push deadbeef x)"
# spoof: testco key but claims to be otherco's tenant — must still land in testco
check "loki push with spoofed X-Scope-OrgID" 204 "$(push "$A_L" spoofed -H 'X-Scope-OrgID: otherco')"

sleep 3
lokiq() { # lokiq <org-id> -> number of log lines visible in that org's Grafana Loki datasource
  curl -s -u "$GFA" -H "X-Grafana-Org-Id: $1" -H 'Content-Type: application/json' "$GF/api/ds/query" \
    -d '{"queries":[{"refId":"A","datasource":{"uid":"loki"},"expr":"{host=~\".+\"}","queryType":"range","maxLines":100}],"from":"now-1h","to":"now"}' \
  | jq -r '[.results.A.frames[]?.data.values[2][]?] | join(",")'
}
orgid() { curl -s -u "$GFA" "$GF/api/orgs/name/$1" | jq -r .id; }
OA=$(orgid testco); OB=$(orgid otherco)
LA=$(lokiq "$OA"); LB=$(lokiq "$OB")
echo "      testco sees logs: [$LA]   otherco sees logs: [$LB]"
check "testco sees its own log"               1 "$(grep -c secretA <<<"$LA")"
check "testco does NOT see otherco's log"     0 "$(grep -c secretB <<<"$LA")"
check "spoofed line landed in testco"         1 "$(grep -c spoofed <<<"$LA")"
check "otherco sees its own log"              1 "$(grep -c secretB <<<"$LB")"
check "otherco does NOT see testco's logs"    0 "$(grep -cE 'secretA|spoofed' <<<"$LB")"

# ── Influx: write via gateway
wr() { # wr <token> <bucket> <host>
  code -X POST "$GW/influx/api/v2/write?org=msp&bucket=$2&precision=s" -H "Authorization: Token $1" \
    --data-binary "cpu,host=$3 usage_idle=42 $(date +%s)"
}
check "influx write own bucket (testco)"       204 "$(wr "$A_W" cust_testco pcA)"
check "influx write own bucket (otherco)"      204 "$(wr "$B_W" cust_otherco pcB)"
r="$(wr "$A_W" cust_otherco evil)"; check "influx testco token -> otherco bucket denied" denied "$([[ $r == 401 || $r == 403 ]] && echo denied || echo "$r")"
check "influx bad token rejected"              401 "$(wr nope cust_testco x)"
check "gateway blocks influx query endpoint"   404 "$(code -X POST "$GW/influx/api/v2/query?org=msp" -H "Authorization: Token $A_W" -d x)"
check "gateway blocks influx admin API"        404 "$(code "$GW/influx/api/v2/buckets" -H "Authorization: Token $A_W")"
rq="$(docker compose exec -T -e INFLUX_TOKEN="$A_W" influxdb influx query --org msp 'from(bucket:"cust_testco") |> range(start:-1h)' </dev/null 2>&1)"
check "write-only token cannot read its own bucket" 1 "$([[ "$rq" == *"could not find bucket"* || "$rq" == *nauthorized* || "$rq" == *ermission* ]] && echo 1 || echo 0)"

# ── Grafana org isolation on metrics
fluxq() { # fluxq <org-id> <bucket> -> distinct hosts visible
  curl -s -u "$GFA" -H "X-Grafana-Org-Id: $1" -H 'Content-Type: application/json' "$GF/api/ds/query" \
    -d "{\"queries\":[{\"refId\":\"A\",\"datasource\":{\"uid\":\"influx\"},\"query\":\"from(bucket: \\\"$2\\\") |> range(start: -1h) |> filter(fn: (r) => r._measurement == \\\"cpu\\\") |> keep(columns: [\\\"host\\\",\\\"_value\\\"])\"}],\"from\":\"now-1h\",\"to\":\"now\"}" \
  | jq -r '[.results.A.frames[]?.schema.fields[]?.labels.host? // empty] | unique | join(",")'
}
echo "      testco org, own bucket sees hosts: [$(fluxq "$OA" cust_testco)]"
check "grafana testco org sees pcA"                1 "$(fluxq "$OA" cust_testco | grep -c pcA)"
check "grafana testco org can't read otherco data" 0 "$(fluxq "$OA" cust_otherco | grep -c pcB)"
check "grafana otherco org can't read testco data" 0 "$(fluxq "$OB" cust_testco  | grep -c pcA)"

echo; echo "RESULT: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
