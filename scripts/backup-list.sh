#!/usr/bin/env bash
# Which machines of a site are backed up? Compares the site's MeshCentral devices with the backup registry.
#   sudo scripts/backup-list.sh <customer> <site>
# Run as root to also see each machine's newest snapshot (the repositories on the NAS are readable only by root).
#   protected              registered, newest snapshot younger than MAX_AGE_HOURS (default 36)
#   STALE                  registered but the newest snapshot is older: the agent stopped, or the machine is off
#   registered, no backup  registered but nothing stored yet (installer not run, or first backup pending)
#   not backed up          a device that is NOT registered (fine if that is the intent: only critical servers need it)
#   registered, not in Mesh  registered for backup but no such device in the site's Mesh group (renamed or never enrolled)
# Needs a MeshCentral login token: scripts/mesh-token.sh set
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
source scripts/lib/meshcentral.sh
cust="${1:?usage: backup-list.sh <customer> <site>}"; site="${2:?site required}"
[[ "$cust" =~ ^[a-z0-9][a-z0-9-]{1,30}$ && "$site" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || { echo "invalid customer or site name" >&2; exit 2; }
MAX_AGE_HOURS="${MAX_AGE_HOURS:-36}"
BK="${BACKUP_DIR:-/srv/msp-backups}"
can_read=0
[[ $EUID -eq 0 ]] && mountpoint -q "$BK" && command -v restic >/dev/null && can_read=1
export RESTIC_CACHE_DIR=/var/cache/msp-restic

mesh_login || exit 1
gname="${cust} / ${site}"
[[ -n "$(mesh_group_id "$gname")" ]] || { echo "no device group '${gname}': run scripts/mesh-site.sh ${cust} ${site}" >&2; exit 1; }
devices="$(mc ListDevices --group "$gname" --json 2>/dev/null | jq -c '.' || echo '[]')"

registered="$(awk -F'\t' -v c="$cust" -v s="$site" '$1==c && $2==s{print $3}' generated/backup/machines.tsv 2>/dev/null || true)"
newest_age() {   # hours since the newest snapshot of a registered machine; empty if none or unreadable
  local host="$1" cred="generated/backup/credentials/${cust}/${site}/${1}.txt" t
  [[ "$can_read" == 1 && -f "$cred" && -d "${BK}/${cust}-${site}-${host}" ]] || return 0
  t="$(RESTIC_PASSWORD="$(sed -n 's/^repo password:[[:space:]]*//p' "$cred")" restic -r "${BK}/${cust}-${site}-${host}" snapshots --json --no-lock 2>/dev/null | jq -r '[.[].time]|max // empty')" || return 0
  [[ -n "$t" ]] && echo $(( ( $(date +%s) - $(date -d "$t" +%s) ) / 3600 ))
}

printf '%-24s %-8s %s\n' "DEVICE" "ONLINE" "BACKUP"
seen=""
while read -r dev; do
  [[ -z "$dev" ]] && continue
  name="$(jq -r '.name' <<<"$dev")"; host="$(tr 'A-Z_' 'a-z-' <<<"$name")"
  on="no"; [[ "$(( $(jq -r '.conn // 0' <<<"$dev") % 2 ))" == 1 ]] && on="yes"
  if grep -qx -- "$host" <<<"$registered"; then
    seen+="$host"$'\n'
    age="$(newest_age "$host")"
    if [[ "$can_read" != 1 ]]; then st="registered (run as root to see the last backup)"
    elif [[ -z "$age" ]]; then st="registered, no backup yet"
    elif (( age > MAX_AGE_HOURS )); then st="STALE: last backup ${age}h ago"
    else st="protected (last backup ${age}h ago)"; fi
  else st="not backed up"; fi
  printf '%-24s %-8s %s\n' "$name" "$on" "$st"
done < <(jq -c '.[]' <<<"$devices")
while read -r host; do
  [[ -z "$host" ]] || grep -qx -- "$host" <<<"$seen" || printf '%-24s %-8s %s\n' "$host" "-" "registered, not in Mesh"
done <<<"$registered"
