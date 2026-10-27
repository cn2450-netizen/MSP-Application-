#!/usr/bin/env bash
# Backup-server tests (needs the NAS share mounted, restic installed, and the stack running). Run on the VM as the normal user (NFS mapall makes NAS access work without root).
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
pass=0; fail=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1  (expected '$2', got '$3')"; fail=$((fail+1)); fi; }
code() { curl -s -o /dev/null -w "%{http_code}" "$@"; }
SRV="http://${BIND_ADDR}:${RESTIC_PORT}"
BK="${BACKUP_DIR}"
field() { sed -n "s/^$2:[[:space:]]*//p" "generated/backup/credentials/testco/main/$1.txt"; }
export RESTIC_CACHE_DIR=/tmp/restic-cache-test

echo "=== server up"
docker compose up -d restic-server >/dev/null 2>&1; sleep 4
check "container running"                         running "$(docker compose ps restic-server --format '{{.State}}')"
check "unauthenticated request refused (401)"     401 "$(code "$SRV/")"

echo; echo "=== register two machines (own login + own repo + own password)"
scripts/backup-add-machine.sh testco main lab1 2>&1 | head -1
scripts/backup-add-machine.sh testco main lab2 2>&1 | head -1
U1=$(field lab1 "server user"); P1=$(field lab1 "server password"); R1=$(field lab1 "repo password")
U2=$(field lab2 "server user"); P2=$(field lab2 "server password"); R2=$(field lab2 "repo password")
check "repo 1 exists on the NAS"                  1 "$([[ -f $BK/$U1/config ]] && echo 1 || echo 0)"
check "repo files owned by restic-svc (uid 1500)" 1500 "$(stat -c %u "$BK/$U1/config")"
check "repo passwords differ per machine"         1 "$([[ $R1 != $R2 ]] && echo 1 || echo 0)"

echo; echo "=== back up through the server (as an agent would)"
SRC=$(mktemp -d); head -c 8000000 /dev/urandom > $SRC/big.bin; for i in $(seq 1 30); do echo "file $i" > $SRC/f$i.txt; done
URL1="rest:http://${U1}:${P1}@${BIND_ADDR}:${RESTIC_PORT}/${U1}"
RESTIC_PASSWORD="$R1" restic -r "$URL1" backup "$SRC" --no-lock --host lab1 --tag test -q 2>&1 | tail -1
snap=$(RESTIC_PASSWORD="$R1" restic -r "$URL1" snapshots --no-lock --json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[-1]['short_id'] if d else '')")
check "snapshot visible through the server"       1 "$([[ -n $snap ]] && echo 1 || echo 0)"
RES=$(mktemp -d); RESTIC_PASSWORD="$R1" restic -r "$URL1" restore latest --target "$RES" --no-lock -q 2>&1 | tail -1
check "restored data is identical"                0 "$(diff -r "$SRC" "$RES$SRC" >/dev/null 2>&1; echo $?)"

echo; echo "=== append-only: a client can NOT delete or overwrite"
out=$(RESTIC_PASSWORD="$R1" restic -r "$URL1" forget "$snap" --prune 2>&1 | tr '\n' ' ')
check "forget/prune through the server is refused" 1 "$(grep -ciE 'forbidden|403|not allowed|Fatal|error' <<<"$out" | awk '{print ($1>0)}')"
check "snapshot still exists after the attempt"    1 "$(RESTIC_PASSWORD="$R1" restic -r "$URL1" snapshots --no-lock --json 2>/dev/null | python3 -c "import sys,json; print(1 if any(s['short_id']=='$snap' for s in json.load(sys.stdin)) else 0)")"
datafile=$(find "$BK/$U1/data" -type f | head -1); rel=${datafile#$BK/$U1/}; id=$(basename "$datafile")
check "DELETE of an existing data file refused"    403 "$(code -X DELETE -u "$U1:$P1" "$SRV/$U1/data/$id")"
check "overwrite of an existing data file refused" 403 "$(code -X POST -u "$U1:$P1" --data-binary x "$SRV/$U1/data/$id")"
check "file on the NAS unchanged"                  1 "$([[ -s $datafile ]] && echo 1 || echo 0)"

echo; echo "=== isolation between machines"
check "lab1 can reach its own repo"                200 "$(code -u "$U1:$P1" "$SRV/$U1/config")"
r=$(code -u "$U1:$P1" "$SRV/$U2/config"); check "lab1 refused on lab2's repo (got $r)" 1 "$([[ $r == 401 || $r == 403 ]] && echo 1 || echo 0)"
r=$(code -u "$U1:$P1" "$SRV/"); check "lab1 refused on the server root (got $r)" 1 "$([[ $r == 401 || $r == 403 ]] && echo 1 || echo 0)"
check "wrong HTTP password refused"                401 "$(code -u "$U1:nope" "$SRV/$U1/config")"
out=$(RESTIC_PASSWORD="wrong-password" restic -r "$URL1" snapshots --no-lock 2>&1 | tr '\n' ' ')
check "wrong repository password cannot decrypt"   1 "$(grep -ciE 'wrong password|no key' <<<"$out" | awk '{print ($1>0)}')"

echo; echo "=== server-side maintenance on the local NAS path (this is how retention is enforced)"
RESTIC_PASSWORD="$R1" restic -r "$BK/$U1" backup "$SRC" --no-lock --host lab1 --tag second -q >/dev/null 2>&1
n=$(RESTIC_PASSWORD="$R1" restic -r "$BK/$U1" snapshots --json 2>/dev/null | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
check "two snapshots before pruning"               2 "$n"
RESTIC_PASSWORD="$R1" restic -r "$BK/$U1" forget --keep-last 1 --prune -q >/dev/null 2>&1
n=$(RESTIC_PASSWORD="$R1" restic -r "$BK/$U1" snapshots --json 2>/dev/null | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
check "local forget+prune works (1 kept)"          1 "$n"
check "repo passes an integrity check"             0 "$(RESTIC_PASSWORD="$R1" restic -r "$BK/$U1" check -q >/dev/null 2>&1; echo $?)"

scripts/backup-remove-machine.sh testco main lab1 --delete-backups >/dev/null 2>&1
scripts/backup-remove-machine.sh testco main lab2 --delete-backups >/dev/null 2>&1
rm -rf -- "${SRC:?}" "${RES:?}" /tmp/restic-cache-test
echo; echo "RESULT: $pass passed, $fail failed"
