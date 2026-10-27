#!/usr/bin/env bash
# Server-side upkeep of every registered machine's backup repository (run as root, daily, from the
# msp-backup-maintain timer; see scripts/install-backup-maintenance.sh).
#   scripts/backup-maintain.sh [--machine <customer-site-host>] [--no-prune] [--no-restore-test]
#
# Per repository, directly on the NAS path (never through the append-only server: clients cannot delete anything,
# only this job can, and only by the retention policy below):
#   1. FRESHNESS  newest snapshot must be younger than MAX_AGE_HOURS, otherwise the machine has silently stopped
#                 backing up. This is the one check that does not depend on the agent itself still working.
#   2. PRUNE      keep KEEP_DAILY daily, KEEP_WEEKLY weekly, KEEP_MONTHLY monthly snapshots; free the rest.
#                 Skipped while the machine is uploading (clients use --no-lock, so a prune during a backup could
#                 remove data that backup is about to reference).
#   3. CHECK      repository structure, plus a rotating 1/7 of the stored data re-read and re-hashed each day, so every
#                 byte is verified once a week and silent NAS corruption is found.
#   4. RESTORE    a few real files from the newest snapshot are restored to the encrypted data volume and verified
#                 against the repository. A backup that cannot be restored is not a backup.
# Results: one line per machine in the journal, generated/backup/maintenance.tsv, and exit status 1 if anything failed.
# File NAMES are never logged (they are customer data); only counts.
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

KEEP_DAILY="${KEEP_DAILY:-7}" KEEP_WEEKLY="${KEEP_WEEKLY:-4}" KEEP_MONTHLY="${KEEP_MONTHLY:-6}"
MAX_AGE_HOURS="${MAX_AGE_HOURS:-36}"
RESTORE_SAMPLE="${RESTORE_SAMPLE:-3}"
BUSY_MINUTES="${BUSY_MINUTES:-30}"
BK="${BACKUP_DIR:-/srv/msp-backups}"
DATA="${MSP_DATA:-/srv/msp}"

only="" prune=1 rtest=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --machine) only="${2:?--machine needs a name}"; shift 2;;
    --no-prune) prune=0; shift;;
    --no-restore-test) rtest=0; shift;;
    *) echo "unknown option $1" >&2; exit 2;;
  esac
done
[[ $EUID -eq 0 ]] || { echo "run as root (the repositories on the NAS are owned by the backup server's user)" >&2; exit 1; }
command -v restic >/dev/null || { echo "restic is not installed: scripts/install-restic.sh" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
mountpoint -q "$BK" && [[ -f "$BK/.msp-backup-root" ]] || { echo "the NAS backup share is not mounted at ${BK}: nothing done" >&2; exit 1; }
mountpoint -q "$DATA" || { echo "the data volume is not mounted at ${DATA}: nothing done" >&2; exit 1; }

exec 9>/run/msp-backup-maintain.lock
flock -n 9 || { echo "another maintenance run is in progress" >&2; exit 1; }

umask 077
export RESTIC_CACHE_DIR=/var/cache/msp-restic
work="$(mktemp -d "${DATA}/.maintain.XXXXXX")"
trap 'rm -rf -- "${work:?}"' EXIT
mkdir -p generated/backup; touch generated/backup/maintenance.tsv

fails=0
# Recent request lines from the backup server mentioning this machine's repository = it is uploading right now.
busy() { docker compose logs --no-log-prefix --since "${BUSY_MINUTES}m" restic-server 2>/dev/null | grep -qF "/${1}/"; }
rv() { restic -r "$1" "${@:2}"; }

while IFS=$'\t' read -r cust site host user _created; do
  [[ -z "${user:-}" ]] && continue
  [[ -z "$only" || "$only" == "$user" ]] || continue
  repo="${BK}/${user}"
  cred="generated/backup/credentials/${cust}/${site}/${host}.txt"
  [[ -f "$cred" && -d "$repo" ]] || { echo "${user}: FAIL  repository or credentials file missing"; fails=$((fails+1)); continue; }
  RESTIC_PASSWORD="$(sed -n 's/^repo password:[[:space:]]*//p' "$cred")"; export RESTIC_PASSWORD
  status="ok"; notes=()
  fail() { status="FAIL"; notes+=("$1"); }

  snaps="$(rv "$repo" snapshots --json --no-lock 2>"$work/err")" || { fail "cannot open repository: $(tail -n1 "$work/err" | cut -c1-120)"; snaps="[]"; }
  count="$(jq 'length' <<<"$snaps")"
  newest="$(jq -r '[.[].time] | max // empty' <<<"$snaps")"
  age_h=-1
  if [[ -n "$newest" ]]; then age_h=$(( ( $(date +%s) - $(date -d "$newest" +%s) ) / 3600 )); fi
  if [[ "$count" == 0 ]]; then fail "no snapshots yet"
  elif (( age_h > MAX_AGE_HOURS )); then fail "newest snapshot is ${age_h}h old (limit ${MAX_AGE_HOURS}h)"; fi

  pruned="skipped"
  if (( prune )) && [[ "$count" -gt 0 ]]; then
    if busy "$user"; then pruned="deferred (machine is uploading)"
    elif rv "$repo" forget --prune --group-by host,paths --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" \
           --keep-monthly "$KEEP_MONTHLY" >"$work/prune.out" 2>"$work/err"; then pruned="done"
    else pruned="failed"; fail "prune failed: $(tail -n1 "$work/err" | cut -c1-120)"; fi
  fi

  # data subset: day-of-year picks which 1/7 to verify today
  subset="$(( (10#$(date +%j) % 7) + 1 ))/7"
  if [[ "$count" -gt 0 ]]; then
    if busy "$user"; then checked="deferred"
    elif rv "$repo" check --no-lock --read-data-subset="$subset" >"$work/check.out" 2>&1; then checked="ok(${subset})"
    else checked="FAILED"; fail "integrity check failed (see: restic check on ${user})"; tail -n 8 "$work/check.out" | sed 's/^/    /'; fi
  else checked="n/a"; fi

  restored="skipped"
  if (( rtest )) && [[ "$count" -gt 0 ]]; then
    latest="$(jq -r 'max_by(.time).id' <<<"$snaps")"
    rv "$repo" ls "$latest" --json --no-lock 2>/dev/null \
      | jq -r 'select(.struct_type=="node" and .type=="file" and .size>0 and .size<10485760 and (.path|test("[*?\\[\\]\\\\]")|not)) | .path' \
      | shuf -n "$RESTORE_SAMPLE" > "$work/sample" || true
    n="$(wc -l < "$work/sample")"
    if [[ "$n" == 0 ]]; then restored="no files"; fail "newest snapshot contains no restorable files"
    else
      args=(); while IFS= read -r f; do args+=(--include "$f"); done < "$work/sample"
      rm -rf -- "${work:?}/restore"; mkdir -p "$work/restore"
      if rv "$repo" restore "$latest" --no-lock --verify --target "$work/restore" "${args[@]}" >"$work/restore.out" 2>&1 \
         && [[ "$(find "$work/restore" -type f | wc -l)" -ge 1 ]]; then restored="ok(${n} files)"
      else restored="FAILED"; fail "restore test failed"; tail -n 5 "$work/restore.out" | sed 's/^/    /'; fi
      rm -rf -- "${work:?}/restore"
    fi
  fi

  size="$(rv "$repo" stats --mode raw-data --json --no-lock 2>/dev/null | jq -r '.total_size // 0')"; [[ "$size" =~ ^[0-9]+$ ]] || size=0
  printf '%s: %s  snapshots=%s newest=%sh stored=%sMiB prune=%s check=%s restore=%s%s\n' "$user" "$status" "$count" "$age_h" \
    "$(( size / 1048576 ))" "$pruned" "$checked" "$restored" "$([[ ${#notes[@]} -gt 0 ]] && printf '  [%s]' "$(IFS=';'; echo "${notes[*]}")")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$user" "$status" "$count" "$size" "${notes[*]:-}" >> generated/backup/maintenance.tsv
  [[ "$status" == ok ]] || fails=$((fails+1))
  unset RESTIC_PASSWORD
done < generated/backup/machines.tsv

# keep the history file from growing forever
tail -n 5000 generated/backup/maintenance.tsv > "$work/m.tsv" && cat "$work/m.tsv" > generated/backup/maintenance.tsv
(( fails == 0 )) && echo "all repositories healthy" || { echo "${fails} repositories need attention" >&2; exit 1; }
