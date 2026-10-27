#!/usr/bin/env bash
# Regression: logins created AFTER another machine was removed must work (htpasswd is replaced with mv on removal).
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
pass=0; fail=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1  (expected '$2', got '$3')"; fail=$((fail+1)); fi; }
code() { curl -s -m 15 -o /dev/null -w "%{http_code}" "$@"; }
SRV="http://${BIND_ADDR}:${RESTIC_PORT}"
f() { sed -n "s/^$2:[[:space:]]*//p" "generated/backup/credentials/testco/main/$1.txt"; }
ok() { [[ "$1" == 200 || "$1" == 404 ]] && echo ok || echo "got-$1"; }   # repo exists -> 200; authenticated but missing -> 404

for m in ra rb; do scripts/backup-add-machine.sh testco main $m >/dev/null 2>&1; done
UA=$(f ra "server user"); PA=$(f ra "server password"); UB=$(f rb "server user"); PB=$(f rb "server password")
check "ra logs in right after being added"          ok "$(ok "$(code -u "$UA:$PA" "$SRV/$UA/config")")"
echo "  removing ra (this replaces the htpasswd file with mv)..."
scripts/backup-remove-machine.sh testco main ra --delete-backups >/dev/null 2>&1
scripts/backup-add-machine.sh testco main rc >/dev/null 2>&1
UC=$(f rc "server user"); PC=$(f rc "server password")
check "rc (added AFTER the removal) can log in"     ok "$(ok "$(code -u "$UC:$PC" "$SRV/$UC/config")")"
check "rb (added before) still logs in"             ok "$(ok "$(code -u "$UB:$PB" "$SRV/$UB/config")")"
check "ra (removed) is refused"                     401 "$(code -u "$UA:$PA" "$SRV/$UA/config")"
# (the server logs 'Invalid htpasswd entry for X' for any refused login of an unknown/removed user, so it is not an error signal)
for m in rb rc; do scripts/backup-remove-machine.sh testco main $m --delete-backups >/dev/null 2>&1; done
check "everything cleaned up (marker only)"         1 "$([[ $(ls -A "$BACKUP_DIR" | wc -l) == 1 ]] && echo 1 || echo 0)"
echo; echo "RESULT: $pass passed, $fail failed"
