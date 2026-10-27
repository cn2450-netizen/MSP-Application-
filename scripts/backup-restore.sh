#!/usr/bin/env bash
# Operator-side restore of a registered machine's backup. Run as root on the VM.
#   scripts/backup-restore.sh <customer> <site> <hostname> --list                       list snapshots
#   scripts/backup-restore.sh <customer> <site> <hostname> --files [--snapshot ID]      list files in a snapshot (default: latest)
#   scripts/backup-restore.sh <customer> <site> <hostname> --target DIR [--snapshot ID] [--path /C/Data/Docs] [--yes]
#
# Restores into DIR (must be empty or not exist; default parent /srv/msp/restore, the encrypted data volume). Without --path
# the whole snapshot is restored. Paths inside a snapshot look like /C/Users/bob/Documents (drive letter first).
# Restored files are customer data: hand them over securely, then delete the directory. Every restore (not listing) is
# appended to generated/backup/restore-audit.log with the date, the operator (sudo user) and what was restored.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

cust="${1:?usage: backup-restore.sh <customer> <site> <hostname> (--list | --files | --target DIR) [--snapshot ID] [--path P] [--yes]}"
site="${2:?site required}"
host="$(tr 'A-Z_' 'a-z-' <<<"${3:?hostname required}")"; shift 3
mode="" snap="latest" path="" target="" yes=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list) mode=list; shift;;
    --files) mode=files; shift;;
    --target) mode=restore; target="${2:?--target needs a directory}"; shift 2;;
    --snapshot) snap="${2:?--snapshot needs an id}"; shift 2;;
    --path) path="${2:?--path needs a path}"; shift 2;;
    --yes) yes=1; shift;;
    *) echo "unknown option $1" >&2; exit 2;;
  esac
done
[[ -n "$mode" ]] || { echo "say what to do: --list, --files or --target DIR" >&2; exit 2; }
[[ "$cust" =~ ^[a-z0-9][a-z0-9-]{1,30}$ && "$site" =~ ^[a-z0-9][a-z0-9-]{0,30}$ && "$host" =~ ^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$ ]] || { echo "invalid name" >&2; exit 2; }
[[ "$snap" =~ ^([0-9a-f]{8,64}|latest)$ ]] || { echo "snapshot must be latest or a hex id" >&2; exit 2; }
[[ -z "$path" || "$path" == /* ]] || { echo "--path must start with / (e.g. /C/Users/bob/Documents)" >&2; exit 2; }
[[ $EUID -eq 0 ]] || { echo "run as root (sudo)" >&2; exit 1; }

BK="${BACKUP_DIR:-/srv/msp-backups}"
DATA="${MSP_DATA:-/srv/msp}"
cred="generated/backup/credentials/${cust}/${site}/${host}.txt"
repo="${BK}/${cust}-${site}-${host}"
[[ -f "$cred" ]] || { echo "no credentials file for ${cust}/${site}/${host}" >&2; exit 1; }
mountpoint -q "$BK" && [[ -f "$BK/.msp-backup-root" ]] || { echo "the NAS backup share is not mounted at ${BK}" >&2; exit 1; }
[[ -d "$repo" ]] || { echo "no repository at ${repo}" >&2; exit 1; }
RESTIC_PASSWORD="$(sed -n 's/^repo password:[[:space:]]*//p' "$cred")"; export RESTIC_PASSWORD
export RESTIC_CACHE_DIR=/var/cache/msp-restic

case "$mode" in
  list)  restic -r "$repo" snapshots --no-lock;;
  files) restic -r "$repo" ls "$snap" --no-lock ${path:+"$path"};;
  restore)
    mountpoint -q "$DATA" || { echo "the data volume is not mounted at ${DATA}" >&2; exit 1; }
    case "$target" in /*) ;; *) target="${DATA}/restore/${target}";; esac
    target="$(realpath -m -- "$target")"
    [[ "$target" == "${DATA}/"* ]] || { echo "restore target must be on the encrypted data volume (under ${DATA}/), not ${target}" >&2; exit 1; }
    if [[ -e "$target" ]]; then [[ -d "$target" && -z "$(ls -A "$target")" ]] || { echo "${target} exists and is not empty" >&2; exit 1; }; fi
    if (( ! yes )); then
      echo "Restoring snapshot '${snap}' of ${cust}/${site}/${host}${path:+ (only ${path})} into ${target}"
      read -r -p "Type the customer name to confirm: " ans; [[ "$ans" == "$cust" ]] || { echo "not confirmed"; exit 1; }
    fi
    umask 077; mkdir -p "$target"
    who="${SUDO_USER:-root}"
    printf '%s\t%s\t%s/%s/%s\tsnapshot=%s\tpath=%s\ttarget=%s\n' "$(date -u +%FT%TZ)" "$who" "$cust" "$site" "$host" "$snap" "${path:-ALL}" "$target" >> generated/backup/restore-audit.log
    restic -r "$repo" restore "$snap" --no-lock --verify --target "$target" ${path:+--include "$path"}
    echo "Restored and verified into ${target}. It is customer data: deliver it securely, then delete it (rm -rf -- '${target}')."
    ;;
esac
