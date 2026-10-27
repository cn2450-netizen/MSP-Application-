#!/usr/bin/env bash
# Keep the portal's catalog of backups up to date (run as root, every few minutes, from the msp-backup-catalog timer;
# see scripts/install-backup-catalog.sh).
#   scripts/backup-catalog.sh [--machine <customer-site-host>] [--rebuild]
#
# For every registered machine: reads the repository's snapshot list directly on the NAS path, loads any snapshot the
# catalog does not have yet (file names, sizes and dates only), and drops snapshots that retention has removed. The
# portal never sees a repository or its password: this script holds them and hands the portal only the listing.
# The cheap path (nothing new) is one restic "snapshots" call per machine. File NAMES are never logged.
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

BK="${BACKUP_DIR:-/srv/msp-backups}"
DATA="${MSP_DATA:-/srv/msp}"
only="" rebuild=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --machine) only="${2:?--machine needs a name}"; shift 2;;
    --rebuild) rebuild=1; shift;;
    *) echo "unknown option $1" >&2; exit 2;;
  esac
done
[[ $EUID -eq 0 ]] || { echo "run as root (the repositories on the NAS are owned by the backup server's user)" >&2; exit 1; }
command -v restic >/dev/null && command -v jq >/dev/null || { echo "restic and jq are required" >&2; exit 1; }
mountpoint -q "$BK" && [[ -f "$BK/.msp-backup-root" ]] || { echo "the NAS backup share is not mounted at ${BK}: nothing done" >&2; exit 1; }
mountpoint -q "$DATA" || { echo "the data volume is not mounted at ${DATA}: nothing done" >&2; exit 1; }

exec 9>/run/msp-backup-catalog.lock
flock -n 9 || { echo "another catalog run is in progress" >&2; exit 0; }

umask 077
export RESTIC_CACHE_DIR=/var/cache/msp-restic
work="$(mktemp -d "${DATA}/.catalog.XXXXXX")"
trap 'rm -rf -- "${work:?}"' EXIT
psql_portal() { docker compose exec -T postgres psql -U portal -d portal -v ON_ERROR_STOP=1 -X -q -A -t "$@"; }

fails=0
while IFS=$'\t' read -r cust site host user _created; do
  [[ -z "${user:-}" ]] && continue
  [[ -z "$only" || "$only" == "$user" ]] || continue
  repo="${BK}/${user}"
  cred="generated/backup/credentials/${cust}/${site}/${host}.txt"
  [[ -f "$cred" && -d "$repo" ]] || { echo "${user}: skipped (repository or credentials missing)"; continue; }
  mid="$(psql_portal -c "SELECT id FROM machine WHERE repo_user = '${user//\'/}'" 2>/dev/null)"
  [[ "$mid" =~ ^[0-9a-f-]{36}$ ]] || { echo "${user}: skipped (not registered in the portal)"; continue; }
  RESTIC_PASSWORD="$(sed -n 's/^repo password:[[:space:]]*//p' "$cred")"; export RESTIC_PASSWORD

  if ! snaps="$(restic -r "$repo" snapshots --json --no-lock 2>"$work/err")"; then
    echo "${user}: FAIL cannot open repository: $(tail -n1 "$work/err" | cut -c1-120)"; fails=$((fails+1)); unset RESTIC_PASSWORD; continue
  fi
  if (( rebuild )); then psql_portal -c "DELETE FROM catalog_snapshot WHERE machine_id = '${mid}'; DELETE FROM catalog_file WHERE machine_id = '${mid}'" >/dev/null; fi

  have="$(psql_portal -c "SELECT snapshot_id FROM catalog_snapshot WHERE machine_id = '${mid}'")"
  added=0
  # oldest first, so a file's list of snapshots grows in order
  while IFS=$'\t' read -r sid taken paths; do
    [[ "$sid" =~ ^[0-9a-f]{64}$ ]] || continue
    grep -qxF "$sid" <<<"$have" && continue
    # list the snapshot into a file first: a listing that stopped halfway must never be loaded
    if ! restic -r "$repo" ls "$sid" --json --no-lock >"$work/ls.json" 2>"$work/err"; then
      echo "${user}: FAIL listing snapshot ${sid:0:8}: $(tail -n1 "$work/err" | cut -c1-120)"; fails=$((fails+1)); break
    fi
    {
      echo "BEGIN;"
      echo "CREATE TEMP TABLE stage (parent text, name text, kind char(1), size bigint, mtime timestamptz) ON COMMIT DROP;"
      echo "COPY stage FROM STDIN;"
      # jq's @tsv escapes tab/newline/backslash exactly the way COPY's text format expects
      jq -r '
        select(.struct_type == "node" and (.type == "file" or .type == "dir")) |
        ((.path | sub("/[^/]*$"; "")) | if . == "" then "/" else . end) as $parent |
        [$parent, .name, (if .type == "dir" then "d" else "f" end),
         (if .type == "dir" then 0 else (.size // 0) end),
         (if .type == "dir" then "1970-01-01T00:00:00Z" else (.mtime // "1970-01-01T00:00:00Z") end)] | @tsv' "$work/ls.json"
      echo '\.'
      echo "INSERT INTO catalog_snapshot(machine_id, snapshot_id, taken_at, paths) VALUES ('${mid}', '${sid}', '${taken}', '${paths//\'/}'::jsonb) RETURNING seq \\gset"
      echo "INSERT INTO catalog_file(machine_id, parent, name, kind, size, mtime, snaps)
              SELECT DISTINCT ON (parent, name, kind, size, mtime) '${mid}', parent, name, kind, size, mtime, ARRAY[:seq]::bigint[] FROM stage
            ON CONFLICT (machine_id, parent, name, kind, size, mtime)
              DO UPDATE SET snaps = CASE WHEN :seq = ANY(catalog_file.snaps) THEN catalog_file.snaps ELSE array_append(catalog_file.snaps, :seq) END;"
      echo "COMMIT;"
    } | psql_portal >/dev/null 2>"$work/perr" && added=$((added+1)) || { echo "${user}: FAIL loading snapshot ${sid:0:8}: $(tail -n1 "$work/perr" | cut -c1-160)"; fails=$((fails+1)); break; }
    rm -f "$work/ls.json"
  done < <(jq -r 'sort_by(.time) | .[] | [.id, .time, (.paths | tojson)] | join("\t")' <<<"$snaps")

  # snapshots that retention has removed: forget them, take them out of every file's list, then drop files in none
  ids="$(jq -r '.[].id' <<<"$snaps" | sed "s/.*/'&'/" | paste -sd, -)"
  psql_portal -c "
    WITH gone AS (DELETE FROM catalog_snapshot WHERE machine_id = '${mid}' AND snapshot_id NOT IN (${ids:-''}) RETURNING seq)
    UPDATE catalog_file f SET snaps = ARRAY(SELECT s FROM unnest(f.snaps) s WHERE s NOT IN (SELECT seq FROM gone))
     WHERE f.machine_id = '${mid}' AND f.snaps && ARRAY(SELECT seq FROM gone);
    DELETE FROM catalog_file WHERE machine_id = '${mid}' AND cardinality(snaps) = 0;" >/dev/null 2>"$work/perr" \
    || { echo "${user}: FAIL clean-up: $(tail -n1 "$work/perr" | cut -c1-160)"; fails=$((fails+1)); }

  if (( added > 0 )); then echo "${user}: catalogued ${added} new snapshot(s)"; fi
  unset RESTIC_PASSWORD
done < generated/backup/machines.tsv
exit $(( fails > 0 ))
