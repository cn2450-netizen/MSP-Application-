#!/usr/bin/env bash
# Retire a machine from backup: remove its server login immediately (it can no longer reach the server), and,
# ONLY with --delete-backups, also delete its repository from the NAS. That deletion is permanent.
#   scripts/backup-remove-machine.sh <customer> <site> <hostname> [--delete-backups]
# Without the flag the data stays on the NAS (still readable with the repo password) so it can be kept for a
# retention period or deleted later.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

cust="${1:?usage: backup-remove-machine.sh <customer> <site> <hostname> [--delete-backups]}"
site="${2:?site required}"
host="$(tr 'A-Z_' 'a-z-' <<<"${3:?hostname required}")"
delete=0
[[ "${4:-}" == "--delete-backups" ]] && delete=1
[[ -z "${4:-}" || "$delete" == 1 ]] || { echo "unknown option ${4}" >&2; exit 2; }
[[ "$cust" =~ ^[a-z0-9][a-z0-9-]{1,30}$ && "$site" =~ ^[a-z0-9][a-z0-9-]{0,30}$ && "$host" =~ ^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$ ]] \
  || { echo "invalid name" >&2; exit 2; }

user="${cust}-${site}-${host}"
BK="${BACKUP_DIR:-/srv/msp-backups}"
registered=0
awk -F'\t' -v u="$user" '$4==u{f=1} END{exit !f}' generated/backup/machines.tsv 2>/dev/null && registered=1
# A machine retired earlier WITHOUT --delete-backups is no longer registered but its data is still on the NAS:
# --delete-backups must still be able to finish the job later.
if [[ "$registered" == 0 ]] && ! { [[ "$delete" == 1 ]] && [[ -d "${BK}/${user}" ]]; }; then
  echo "machine ${user} is not registered (and, for a delete, no retained repository was found)" >&2; exit 1
fi

if [[ "$registered" == 1 ]]; then
  # 1. cut off access first
  grep -v "^${user}:" generated/restic/htpasswd > generated/restic/htpasswd.new || true
  mv generated/restic/htpasswd.new generated/restic/htpasswd; chmod 644 generated/restic/htpasswd
  docker compose kill -s HUP restic-server >/dev/null 2>&1 || true
  echo "  server login for ${user} removed"
  # 2. registry (the credentials file is the only copy of the repo password: kept unless the data is deleted)
  awk -F'\t' -v u="$user" '$4!=u' generated/backup/machines.tsv > generated/backup/machines.tsv.new && mv generated/backup/machines.tsv.new generated/backup/machines.tsv
else
  echo "  (already unregistered; finishing the deletion of the retained backups)"
fi
if [[ "$delete" == 1 ]]; then
  repo="${BK}/${user}"
  mountpoint -q "$BK" && [[ -f "$BK/.msp-backup-root" ]] || { echo "NAS share not mounted: backups NOT deleted" >&2; exit 1; }
  if [[ -d "$repo" && -f "$repo/config" ]]; then
    size="$(du -sh "$repo" 2>/dev/null | cut -f1)"
    rm -rf -- "${BK:?}/${user:?}"
    echo "  DELETED repository ${user} (${size}) from the NAS"
  else
    echo "  no repository directory found at ${repo}"
  fi
  rm -f -- "generated/backup/credentials/${cust}/${site}/${host}.txt"
  echo "  credentials file deleted"
else
  echo "  backups KEPT on the NAS at ${BK}/${user}; credentials file kept (needed to read them): generated/backup/credentials/${cust}/${site}/${host}.txt"
fi
