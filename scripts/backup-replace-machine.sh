#!/usr/bin/env bash
# Move a machine's backup identity to the computer that replaces it (run as root on the backup host; the portal's
# "Replace this computer" feature runs it through scripts/backup-replace-executor.sh after a second person approves).
#   sudo scripts/backup-replace-machine.sh <customer> <site> <old-machine> <new-computer>
#
# The new computer keeps backing up into the SAME repository under the same machine name (restic --host), so the
# history, the retention groups and the portal's catalog all carry over. Steps:
#   1. rotate the machine's backup-server password and portal token: the old computer, if it ever comes back, is cut off
#      (the repository's encryption password is unchanged: it is the key to the history that is being kept)
#   2. build a fresh installer for the old machine's identity (keeping its folder scope)
#   3. install it on the new computer through MeshCentral (the new computer must be online in "<customer> / <site>")
# The new computer must not already have a backup identity of its own, unless it IS the old machine (rebuilt under the
# same name). Safe to re-run: it rotates again and re-installs. Nothing secret is printed.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

cust="${1:?usage: backup-replace-machine.sh <customer> <site> <old-machine> <new-computer>}"
site="${2:?site required}"
old="$(tr 'A-Z_' 'a-z-' <<<"${3:?old machine required}")"
dev_in="${4:?new computer required}"
dev="$(tr 'A-Z_' 'a-z-' <<<"$dev_in")"
[[ "$cust" =~ ^[a-z0-9][a-z0-9-]{1,30}$ && "$site" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || { echo "invalid customer or site name" >&2; exit 2; }
[[ "$old" =~ ^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$ && "$dev" =~ ^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$ ]] || { echo "invalid computer name" >&2; exit 2; }
[[ "$dev_in" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,28}[A-Za-z0-9])?$ ]] || { echo "invalid new computer name" >&2; exit 2; }
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
command -v htpasswd >/dev/null || { echo "htpasswd is missing: apt-get install apache2-utils" >&2; exit 1; }
source scripts/lib/meshcentral.sh

user="${cust}-${site}-${old}"
cred="generated/backup/credentials/${cust}/${site}/${old}.txt"
[[ -f "$cred" ]] || { echo "${old} is not a registered backup machine of ${cust}/${site}" >&2; exit 1; }
awk -F'\t' -v u="$user" '$4==u{f=1} END{exit !f}' generated/backup/machines.tsv || { echo "${user} is not in the machine registry" >&2; exit 1; }
if [[ "$dev" != "$old" ]] && awk -F'\t' -v c="$cust" -v s="$site" -v h="$dev" '$1==c && $2==s && $3==h{f=1} END{exit !f}' generated/backup/machines.tsv; then
  echo "${dev_in} already has a backup identity of its own, so it cannot take over another's: choose a computer that is not set up for backup" >&2; exit 1
fi

# The new computer has to be reachable BEFORE anything is rotated, so a typo cannot cut the old machine off for nothing.
mesh_login || { echo "MeshCentral login token missing or expired: create one (My Account -> Create login token) and run scripts/mesh-token.sh set, then try again" >&2; exit 1; }
gname="${cust} / ${site}"
online="$(mc ListDevices --group "$gname" --json | jq -r --arg n "$dev_in" '[.[]|select(((.conn // 0) % 2) == 1 and ((.name|ascii_downcase)==($n|ascii_downcase)))]|length' 2>/dev/null || echo 0)"
[[ "$online" == 1 ]] || { echo "${dev_in} is not online in the MeshCentral group '${gname}': install the monitoring/remote agent on it first" >&2; exit 1; }
echo "[1/4] ${dev_in} is online in '${gname}'"

# 1. rotate the backup-server password and the portal token
new_http="$(openssl rand -hex 24)"
tmp="$(mktemp generated/restic/.htpasswd.XXXXXX)"
grep -v "^${user}:" generated/restic/htpasswd > "$tmp" || true
htpasswd -nbB "$user" "$new_http" >> "$tmp"
chmod 644 "$tmp"; mv "$tmp" generated/restic/htpasswd          # the server mounts the directory, so a replaced file is seen
docker compose kill -s HUP restic-server >/dev/null 2>&1 || true
sed -i "s|^server password:.*|server password:  ${new_http}|" "$cred"
mid="$(sed -n 's/^portal token:[[:space:]]*//p' "$cred" | cut -d. -f1)"
if [[ "$mid" =~ ^[0-9a-f-]{36}$ ]]; then
  sed -i "s|^portal token:.*|portal token:     ${mid}.$(openssl rand -hex 24)|" "$cred"
fi
scripts/portal-register-machine.sh "$cust" "$site" "$old" >/dev/null       # stores the hash of the new token (the old one stops working)
echo "[2/4] the old backup login and portal token no longer work"

# 2 + 3. a fresh installer for this identity (its folder scope is remembered), installed on the new computer
scripts/build-backup-installer.sh "$cust" "$site" "$old" >/dev/null
echo "[3/4] installer built for ${old}"
if deploy_out="$(scripts/mesh-deploy-backup.sh "$cust" "$site" --device "$dev_in" --as "$old" 2>&1)"; then
  grep -E '^\s*(\[MSP Backup\]|RESULT)' <<<"$deploy_out" | sed 's/^ *//' || true
else
  grep -E '^\s*(\[MSP Backup\]|RESULT|.*rror)' <<<"$deploy_out" | sed 's/^ *//' | tail -4 || true
  echo "installing on ${dev_in} did not complete: run it again (it is safe to repeat)" >&2; exit 1
fi
echo "[4/4] ${dev_in} now backs up as ${old}. Restore the newest backup onto it from the portal."
