#!/usr/bin/env bash
# Back up the PLATFORM itself (not customer computers) to the NAS, encrypted with restic. Run as root, daily, from the
# msp-platform-backup timer (scripts/install-platform-backup.sh).
#   sudo scripts/backup-platform.sh --init      once: create the repository and its password (shown ONCE: put it in your vault)
#   sudo scripts/backup-platform.sh             back up, apply retention, check, prove the newest snapshot restores
#   sudo scripts/backup-platform.sh --restore-test   only the restore proof
#
# What is saved (a rebuilt VM needs all of it, plus the LUKS key which is deliberately NOT here):
#   postgres.sql       pg_dumpall of every database (authentik, MeshCentral, portal incl. catalog and audit)
#   influx/            `influx backup` of all buckets (consistent, unlike copying live files)
#   files              ./secrets ./generated ./config ./.env, authentik media, Influx config, Grafana data, MeshCentral data/files
# NOT saved: Loki logs (short retention, rebuilt by agents), customer backup repositories (they live on the NAS and have
# their own checks), the LUKS key (vault), container images.
#
# The repository is ${BACKUP_DIR}/_platform on the NAS (customer names cannot start with "_", so nothing collides).
# Its password is secrets/platform_backup_password AND must be in your vault: the copy inside ./secrets is useless if the
# VM is lost, which is exactly when you need it.
set -uo pipefail
cd "$(dirname "$0")/.."
APP="$(pwd)"
set -a; source .env; set +a

BK="${BACKUP_DIR:-/srv/msp-backups}"
DATA="${DATA_DIR:-/srv/msp/data}"
REPO="${BK}/_platform"
PWF="${APP}/secrets/platform_backup_password"
KEEP_DAILY="${KEEP_DAILY:-7}" KEEP_WEEKLY="${KEEP_WEEKLY:-4}" KEEP_MONTHLY="${KEEP_MONTHLY:-6}"
STATUS="${APP}/generated/backup/platform.status"

mode=run
case "${1:-}" in
  --init) mode=init;;
  --restore-test) mode=rtest;;
  "") ;;
  *) echo "usage: backup-platform.sh [--init | --restore-test]" >&2; exit 2;;
esac
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
command -v restic >/dev/null || { echo "restic is not installed: scripts/install-restic.sh" >&2; exit 1; }
mountpoint -q "$BK" && [[ -f "$BK/.msp-backup-root" ]] || { echo "NAS share is not mounted: refusing to write the platform backup anywhere else" >&2; exit 1; }
export RESTIC_REPOSITORY="$REPO" RESTIC_PASSWORD_FILE="$PWF" RESTIC_CACHE_DIR=/var/cache/restic-platform

fail() { echo "FAILED: $*" >&2; mkdir -p "$(dirname "$STATUS")"; printf '%s\tfailed\t%s\n' "$(date -u +%FT%TZ)" "$*" > "$STATUS"; exit 1; }

if [[ "$mode" == init ]]; then
  [[ ! -e "$REPO/config" ]] || { echo "repository already exists at ${REPO}" >&2; exit 1; }
  [[ -f "$PWF" ]] || { umask 077; openssl rand -base64 33 | tr -d '\n' > "$PWF"; }
  mkdir -p "$REPO"; chown --reference="$BK" "$REPO" 2>/dev/null || true
  restic init >/dev/null || fail "restic init"
  echo "Platform backup repository created: ${REPO}"
  echo
  echo "REPOSITORY PASSWORD (save it in your vault NOW; it is the only way to read these backups after a disaster):"
  cat "$PWF"; echo
  echo
  echo "Then schedule it:  sudo scripts/install-platform-backup.sh"
  exit 0
fi
[[ -f "$REPO/config" && -f "$PWF" ]] || { echo "no repository yet: run  sudo scripts/backup-platform.sh --init" >&2; exit 1; }

restore_test() {
  local tmp snap
  tmp="$(mktemp -d /srv/msp/restore-test.XXXXXX)" || fail "cannot create a restore-test directory"
  chmod 700 "$tmp"
  snap="$(restic snapshots --json 2>/dev/null | jq -r 'sort_by(.time) | last | .short_id // empty')"   # newest of all, whatever its paths
  [[ -n "$snap" ]] || { rm -rf -- "$tmp"; fail "no snapshot to test"; }
  restic restore "$snap" --target "$tmp" --include '**/stage/postgres.sql' --include '**/secrets' >/dev/null 2>&1 \
    || { rm -rf -- "$tmp"; fail "restore of snapshot ${snap} failed"; }
  local sql; sql="$(find "$tmp" -name postgres.sql -type f | head -1)"
  if [[ -z "$sql" ]] || ! tail -3 "$sql" | grep -q "PostgreSQL database cluster dump complete"; then rm -rf -- "$tmp"; fail "restored database dump is missing or incomplete (snapshot ${snap})"; fi
  for db in authentik meshcentral portal; do grep -q "^CREATE DATABASE ${db} " "$sql" || { rm -rf -- "$tmp"; fail "restored dump has no database ${db}"; }; done
  [[ -n "$(find "$tmp" -type d -name secrets | head -1)" ]] || { rm -rf -- "$tmp"; fail "restored snapshot has no secrets directory"; }
  rm -rf -- "$tmp"
  echo "restore test ok (snapshot ${snap}: complete database dump with authentik, meshcentral and portal; secrets present)"
}

if [[ "$mode" == rtest ]]; then restore_test; exit $?; fi

STAGE=/srv/msp/platform-stage   # fixed name so every snapshot has the same paths (and retention groups them together)
rm -rf -- "$STAGE"; mkdir -m 700 "$STAGE" || fail "cannot create the staging directory"
trap 'rm -rf -- "$STAGE"' EXIT
mkdir -p "$STAGE/stage/influx"

echo "[1/5] databases"
docker compose exec -T postgres pg_dumpall -U msp_admin --clean --if-exists </dev/null > "$STAGE/stage/postgres.sql" 2>"$STAGE/pg.err" \
  || fail "pg_dumpall: $(head -c 300 "$STAGE/pg.err")"
tail -3 "$STAGE/stage/postgres.sql" | grep -q "PostgreSQL database cluster dump complete" || fail "pg_dumpall output is incomplete"

echo "[2/5] InfluxDB"
docker compose exec -T -e INFLUX_TOKEN="$(cat secrets/influx_admin_token)" influxdb \
  sh -c 'rm -rf /tmp/pbk && influx backup /tmp/pbk >/dev/null && tar -C /tmp -cf - pbk && rm -rf /tmp/pbk' </dev/null \
  | tar -C "$STAGE/stage/influx" -xf - 2>"$STAGE/influx.err" || fail "influx backup: $(head -c 300 "$STAGE/influx.err")"
[[ -n "$(find "$STAGE/stage/influx" -type f | head -1)" ]] || fail "influx backup produced no files"

echo "[3/5] snapshot to the NAS"
paths=("$STAGE/stage" "$APP/secrets" "$APP/generated" "$APP/config" "$APP/.env")
for d in authentik-media influx-config grafana meshcentral/data meshcentral/files; do [[ -d "$DATA/$d" ]] && paths+=("$DATA/$d"); done
restic backup --host msp-platform --tag platform \
  "${paths[@]}" >"$STAGE/backup.out" 2>&1 || fail "restic backup: $(tail -c 400 "$STAGE/backup.out")"
grep -E "^(Files:|snapshot .* saved)" "$STAGE/backup.out" | sed 's/^/      /'

echo "[4/5] retention and integrity"
restic forget --host msp-platform --tag platform --group-by host,tags \
  --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" --keep-monthly "$KEEP_MONTHLY" --prune >"$STAGE/forget.out" 2>&1 \
  || fail "restic forget/prune: $(tail -c 300 "$STAGE/forget.out")"
sub="$(( $(date +%j | sed 's/^0*//') % 7 + 1 ))/7"
restic check --read-data-subset "$sub" >"$STAGE/check.out" 2>&1 || fail "restic check: $(tail -c 300 "$STAGE/check.out")"

echo "[5/5] restore proof"
rm -rf -- "$STAGE/stage"      # the dumps are in the repository now; do not keep a plaintext copy on disk any longer than needed
restore_test || exit 1
printf '%s\tok\tsnapshot saved, checked (data subset %s), restore proven\n' "$(date -u +%FT%TZ)" "$sub" > "$STATUS"
echo "Platform backup ok."
