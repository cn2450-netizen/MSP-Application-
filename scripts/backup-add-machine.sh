#!/usr/bin/env bash
# Register a machine for backup. Each machine gets its OWN login on the backup server and its OWN repository with
# its own encryption password, so one compromised machine exposes nothing about any other.
#   scripts/backup-add-machine.sh <customer> <site> <hostname>
#
# Creates: an HTTP login (user "<customer>-<site>-<host>") limited by --private-repos to its own repository, a random
# repository password, and the repository itself (initialised here, on the NAS path, so agents never need to init).
# Output: generated/backup/credentials/<customer>/<site>/<host>.txt (mode 600). These passwords are the ONLY way to
# read the backups: keep a copy in your vault. Needs: the NAS share mounted, restic installed, apache2-utils.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
source agent/backup/version.env

cust="${1:?usage: backup-add-machine.sh <customer> <site> <hostname>}"
site="${2:?site required}"
host_in="${3:?hostname required}"
host="$(tr 'A-Z_' 'a-z-' <<<"$host_in")"
[[ "$cust" =~ ^[a-z0-9][a-z0-9-]{1,30}$ && "$site" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || { echo "invalid customer or site name" >&2; exit 2; }
[[ "$host" =~ ^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$ ]] || { echo "hostname must be 1-30 chars of a-z 0-9 and hyphen (got '${host_in}')" >&2; exit 2; }
awk -F'\t' -v c="$cust" -v s="$site" '$1==c && $2==s{f=1} END{exit !f}' generated/sites.tsv || { echo "unknown site ${cust}/${site}: add it with scripts/add-site.sh" >&2; exit 1; }

user="${cust}-${site}-${host}"
BK=${BACKUP_DIR:-/srv/msp-backups}
mountpoint -q "$BK" && [[ -f "$BK/.msp-backup-root" ]] || { echo "the NAS backup share is not mounted at ${BK}" >&2; exit 1; }
command -v restic >/dev/null || { echo "restic is not installed: sudo scripts/install-restic.sh" >&2; exit 1; }
command -v htpasswd >/dev/null || { echo "htpasswd is missing: sudo apt-get install apache2-utils" >&2; exit 1; }
mkdir -p generated/backup; touch generated/backup/machines.tsv generated/restic/htpasswd
awk -F'\t' -v u="$user" '$4==u{f=1} END{exit f}' generated/backup/machines.tsv || { echo "machine ${user} is already registered" >&2; exit 1; }
[[ ! -e "$BK/$user" ]] || { echo "${BK}/${user} already exists on the NAS: refusing to touch it" >&2; exit 1; }

http_pw="$(openssl rand -hex 24)"
repo_pw="$(openssl rand -hex 32)"

# 1. server login (bcrypt); the server re-reads the file on SIGHUP
line="$(htpasswd -nbB "$user" "$http_pw")"
( umask 022; printf '%s\n' "$line" >> generated/restic/htpasswd )
docker compose kill -s HUP restic-server >/dev/null 2>&1 || true

# 2. the repository, created on the NAS path (repo format 2 = compression). Chunker parameters are fixed here so that
#    a later copy to a cold-storage repository (restic copy --copy-chunker-params) stays deduplicated.
repo_local="${BK}/${user}"
RESTIC_PASSWORD="$repo_pw" restic init --repo "$repo_local" --repository-version 2 >/dev/null
chmod 2750 "$repo_local" 2>/dev/null || true

# 3. credentials + registry
d="generated/backup/credentials/${cust}/${site}"; mkdir -p "$d"
( umask 077; cat > "${d}/${host}.txt" <<EOF
customer:         ${cust}
site:             ${site}
machine:          ${host}
repository url:   https://${BACKUP_HOST:-backup.example.com}/${user}
server user:      ${user}
server password:  ${http_pw}
repo password:    ${repo_pw}
local repo path:  ${repo_local}
restic version:   ${RESTIC_VERSION}
EOF
)
printf '%s\t%s\t%s\t%s\t%s\n' "$cust" "$site" "$host" "$user" "$(date -u +%FT%TZ)" >> generated/backup/machines.tsv
echo "Registered ${user}"
echo "  credentials: ${d}/${host}.txt (mode 600). Copy the repo password into your vault: without it the backups cannot be read."
