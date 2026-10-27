#!/usr/bin/env bash
# Create (or reconcile) the MeshCentral device group for a site and fetch the MeshCentral agent built for it.
#   scripts/mesh-site.sh <customer> <site> [--consent N]
#   scripts/mesh-site.sh --all [--consent N]          every site in generated/sites.tsv
#
# Device group name:  "<customer> / <site>".  Consent defaults to 71 = notify the user + on-screen toolbar.
# (consent bits: 1/2/4 notify for desktop/terminal/files, 8/16/32 prompt for them, 64 toolbar; 0 = silent)
# Output: generated/agents/<customer>/<site>/meshagent64-<customer>-<site>.exe  (Windows 64-bit service agent).
# Anyone holding that file can enrol a device into that customer's group, so treat it as sensitive (mode 600).
# Needs a MeshCentral login token: scripts/mesh-token.sh set
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
source scripts/lib/meshcentral.sh

consent="$MESH_CONSENT_DEFAULT" all=0 cust="" site=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) all=1; shift;;
    --consent) consent="${2:?--consent needs a number}"; shift 2;;
    -*) echo "unknown option $1" >&2; exit 2;;
    *) if [[ -z "$cust" ]]; then cust="$1"; elif [[ -z "$site" ]]; then site="$1"; else echo "too many arguments" >&2; exit 2; fi; shift;;
  esac
done
[[ "$consent" =~ ^[0-9]+$ && "$consent" -le 127 ]] || { echo "consent must be a number 0-127" >&2; exit 2; }
[[ "$all" == 1 || ( -n "$cust" && -n "$site" ) ]] || { echo "usage: mesh-site.sh <customer> <site> | --all  [--consent N]" >&2; exit 2; }

mesh_login || exit 1
echo "Signed in to MeshCentral as ${MESH_WHO}."

process_site() {
  local c="$1" s="$2" gname gid short code f out
  awk -F'\t' -v c="$c" -v s="$s" '$1==c && $2==s{f=1} END{exit !f}' generated/sites.tsv 2>/dev/null \
    || { echo "  ${c}/${s}: not in generated/sites.tsv (add it with scripts/add-site.sh first)" >&2; return 1; }
  gname="${c} / ${s}"
  gid="$(mesh_group_id "$gname")"
  if [[ -z "$gid" ]]; then
    out="$(mc AddDeviceGroup --name "$gname" --desc "Customer ${c}, site ${s}" --consent "$consent")"
    [[ "$out" == ok* ]] || { echo "  ${gname}: could not create the device group: ${out}" >&2; return 1; }
    gid="$(mesh_group_id "$gname")"
    echo "  created device group '${gname}' (consent ${consent})"
  else
    out="$(mc EditDeviceGroup --id "$gid" --consent "$consent")"
    [[ "$out" == ok* ]] || { echo "  ${gname}: could not set consent: ${out}" >&2; return 1; }
    echo "  device group '${gname}' already exists; consent set to ${consent}"
  fi
  short="${gid#mesh//}"     # the download endpoint wants the 64-char id without the "mesh//" prefix
  mkdir -p "generated/agents/${c}/${s}"
  f="generated/agents/${c}/${s}/meshagent64-${c}-${s}.exe"
  code="$( umask 077; mesh_http_get "/meshagents?id=4&meshid=$(jq -rn --arg v "$short" '$v|@uri')&installflags=0" "$f" )"
  if [[ "$code" != 200 || "$(head -c2 "$f" 2>/dev/null)" != "MZ" ]]; then
    echo "  ${gname}: agent download failed (http ${code})" >&2; rm -f -- "$f"; return 1
  fi
  chmod 600 "$f"; sha256sum "$f" | cut -d' ' -f1 > "${f}.sha256"
  echo "  agent: ${f}  ($(stat -c %s "$f") bytes, sha256 $(cut -c1-16 "${f}.sha256")...)"
}

rc=0
if [[ "$all" == 1 ]]; then
  while IFS=$'\t' read -r c s _n _d _id; do
    [[ -z "${c:-}" ]] && continue
    process_site "$c" "$s" || rc=1
  done < generated/sites.tsv
else
  process_site "$cust" "$site" || rc=1
fi
echo
echo "Next: scripts/mesh-grant.sh   (gives each customer's techs access once their group exists in MeshCentral)"
exit "$rc"
