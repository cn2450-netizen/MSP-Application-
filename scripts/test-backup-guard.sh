#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
pass=0; fail=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1  (expected '$2', got '$3')"; fail=$((fail+1)); fi; }
code() { curl -s -m 3 -o /dev/null -w "%{http_code}" "$@"; }
SRV="http://${BIND_ADDR}:${RESTIC_PORT}"; BK="${BACKUP_DIR}"
field() { sed -n "s/^$2:[[:space:]]*//p" "generated/backup/credentials/testco/main/$1.txt"; }
scripts/backup-add-machine.sh testco main lab1 >/dev/null 2>&1; scripts/backup-add-machine.sh testco main lab2 >/dev/null 2>&1
U1=$(field lab1 "server user"); P1=$(field lab1 "server password"); U2=$(field lab2 "server user")

echo "=== isolation: a refusal is 401 or 403 (both are refusals), and never 200"
r1="$(code -u "$U1:$P1" "$SRV/$U2/config")"; r2="$(code -u "$U1:$P1" "$SRV/")"
check "lab1 refused on lab2's repo (got $r1)"      1 "$([[ $r1 == 401 || $r1 == 403 ]] && echo 1 || echo 0)"
check "lab1 refused on the server root (got $r2)"  1 "$([[ $r2 == 401 || $r2 == 403 ]] && echo 1 || echo 0)"
check "lab1 still reaches its own repo"            200 "$(code -u "$U1:$P1" "$SRV/$U1/config")"

echo; echo "=== share absent: the server must serve NOTHING (sampled over ~10 s) and write nothing locally"
docker compose stop restic-server >/dev/null 2>&1
sudo systemctl stop msp-backup-nfs.service
docker compose up -d restic-server >/dev/null 2>&1
served=0
for i in $(seq 1 10); do [[ "$(code -u "$U1:$P1" "$SRV/$U1/config")" == 200 ]] && served=$((served+1)); sleep 1; done
check "never answered 200 while the share was missing"  0 "$served"
check "log explains the refusal"                        1 "$([[ $(docker compose logs --no-log-prefix --tail 20 restic-server 2>&1 | grep -c 'marker file missing') -ge 1 ]] && echo 1 || echo 0)"
check "nothing written to the local mount point"        0 "$(ls -A "$BK" | wc -l)"
check "the server is in a restart loop, not serving"    1 "$(docker inspect -f '{{.RestartCount}}' msp-platform-restic-server-1 | awk '{print ($1>=1)}')"
sudo systemctl start msp-backup-nfs.service
for i in $(seq 1 40); do [[ "$(code -u "$U1:$P1" "$SRV/$U1/config")" == 200 ]] && break; sleep 3; done
check "serving again once the share is back"            200 "$(code -u "$U1:$P1" "$SRV/$U1/config")"

echo; echo "=== remove script: cut off access first, then (flagged) delete"
scripts/backup-remove-machine.sh testco main lab2 2>&1 | sed 's/^/  /'
check "lab2 login no longer works"                      401 "$(code -u "$U2:x" "$SRV/$U2/config")"
check "lab2 data KEPT without the flag"                 1 "$([[ -f $BK/$U2/config ]] && echo 1 || echo 0)"
scripts/backup-remove-machine.sh testco main lab2 2>&1 | tail -1
echo "  (second removal is refused because it is already unregistered, as expected)"
scripts/backup-remove-machine.sh testco main lab1 --delete-backups 2>&1 | sed 's/^/  /'
check "lab1 repo deleted from the NAS"                  0 "$([[ -e $BK/$U1 ]] && echo 1 || echo 0)"
check "lab1 no longer in the registry"                  0 "$(awk -F'\t' '$3=="lab1"' generated/backup/machines.tsv | wc -l)"
check "htpasswd has only lab2's entry removed too"      0 "$(grep -c "^testco-main-lab[12]:" generated/restic/htpasswd)"
# finally delete lab2's retained data too, so the lab is clean
scripts/backup-remove-machine.sh testco main lab2 --delete-backups >/dev/null 2>&1 || true

echo; echo "RESULT: $pass passed, $fail failed"
