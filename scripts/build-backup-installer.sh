#!/usr/bin/env bash
# Build the one-file Windows backup installer for a machine that is already registered (scripts/backup-add-machine.sh).
#   scripts/build-backup-installer.sh <customer> <site> <hostname> [--paths 'C:\Data;D:\Docs'] [--time HH:MM]
#
# Default scope: every fixed drive minus agent/backup/windows/excludes.txt (and agent/backup/windows/excludes.site/
# <customer>-<site>.txt if present). --paths limits it to specific folders. The start time defaults to a slot between
# 01:00 and 04:59 derived from the machine name, so a customer's machines do not all start at once.
# Output: generated/agents/<customer>/<site>/backup/install-backup-<host>.ps1 (mode 600: it holds this machine's
# credentials, including the password that decrypts its backups).
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; source agent/backup/version.env; set +a

cust="${1:?usage: build-backup-installer.sh <customer> <site> <hostname> [--paths 'C:\\a;D:\\b'] [--time HH:MM]}"
site="${2:?site required}"
host="$(tr 'A-Z_' 'a-z-' <<<"${3:?hostname required}")"; shift 3
paths="ALL" when="" paths_given=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --paths) paths="${2:?--paths needs a value}"; paths_given=1; shift 2;;
    --time)  when="${2:?--time needs HH:MM}"; shift 2;;
    *) echo "unknown option $1" >&2; exit 2;;
  esac
done
[[ "$cust" =~ ^[a-z0-9][a-z0-9-]{1,30}$ && "$site" =~ ^[a-z0-9][a-z0-9-]{0,30}$ && "$host" =~ ^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$ ]] || { echo "invalid name" >&2; exit 2; }
[[ -z "$when" || "$when" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "--time must be HH:MM" >&2; exit 2; }
cred="generated/backup/credentials/${cust}/${site}/${host}.txt"
[[ -f "$cred" ]] || { echo "no credentials for ${cust}/${site}/${host}: run scripts/backup-add-machine.sh ${cust} ${site} ${host}" >&2; exit 1; }

# The scope chosen at install time is remembered per machine, so rebuilding the installer to upgrade an agent (without
# --paths) keeps it instead of silently widening it to every drive. "--paths ALL" is how to go back to everything.
scope_file="${cred%.txt}.scope"
if [[ "$paths_given" == 0 && -s "$scope_file" ]]; then paths="$(cat "$scope_file")"; fi
(umask 077; printf '%s' "$paths" > "$scope_file")

# Portal check-in: needs the portal address and a per-machine token. Best-effort: without them the installer still
# schedules the daily backup, it just cannot be managed from the portal.
portal_url="" agent_token=""
if [[ -n "${PORTAL_HOST:-}" ]]; then
  if scripts/portal-register-machine.sh "$cust" "$site" "$host" >/dev/null 2>&1; then
    portal_url="https://${PORTAL_HOST}"
    agent_token="$(sed -n 's/^portal token:[[:space:]]*//p' "$cred")"
  else
    echo "WARNING: could not register ${host} in the portal; the installer will not include portal check-in" >&2
  fi
fi

out_dir="generated/agents/${cust}/${site}/backup"
mkdir -p "$out_dir"; out="${out_dir}/install-backup-${host}.ps1"

CUST="$cust" SITE="$site" HOST="$host" PATHS="$paths" WHEN="$when" CRED="$cred" OUT="$out" \
SERVER_HOST="${BACKUP_HOST:?BACKUP_HOST not set in .env}" PORTAL_URL="$portal_url" AGENT_TOKEN="$agent_token" \
RESTIC_URL="${RESTIC_URL_BASE}/${RESTIC_WINDOWS_AMD64_FILE}" RESTIC_SHA="${RESTIC_WINDOWS_AMD64_SHA256}" \
python3 - <<'PY'
import base64, hashlib, os, re, sys

e = os.environ
vals = {}
for line in open(e["CRED"], encoding="utf-8"):
    m = re.match(r"^(server user|server password|repo password):\s*(\S+)\s*$", line)
    if m: vals[m.group(1)] = m.group(2)
for k in ("server user", "server password", "repo password"):
    if k not in vals: sys.exit(f"credentials file is missing '{k}'")
if not re.fullmatch(r"[A-Za-z0-9.-]+", e["SERVER_HOST"]): sys.exit("BACKUP_HOST looks wrong")

when = e["WHEN"]
if not when:   # deterministic slot in 01:00-04:59 from the machine name
    n = int(hashlib.md5(e["HOST"].encode()).hexdigest(), 16) % 240
    when = "%02d:%02d" % (1 + n // 60, n % 60)

if e["PATHS"] == "ALL": paths = ["ALL"]
else: paths = [p.strip() for p in e["PATHS"].split(";") if p.strip()]
for k in ("PORTAL_URL", "AGENT_TOKEN"):
    if e[k] and not re.fullmatch(r"[A-Za-z0-9.:/_-]+", e[k]): sys.exit(f"{k} has unexpected characters")
if any(("'" in p or "\n" in p or "\r" in p) for p in paths): sys.exit("paths must not contain quotes or line breaks")
paths_ps = "','".join(paths)

root = "agent/backup/windows/"
wrapper = open(root + "msp-backup.ps1", "rb").read()
excl = open(root + "excludes.txt", "rb").read()
common = open(root + "msp-common.ps1", "rb").read()
poll = open(root + "msp-poll.ps1", "rb").read()
site_file = f"{root}excludes.site/{e['CUST']}-{e['SITE']}.txt"
if os.path.exists(site_file):
    excl += b"\n# --- site-specific (" + site_file.encode() + b") ---\n" + open(site_file, "rb").read()
for name, data in (("msp-backup.ps1", wrapper), ("excludes.txt", excl), ("msp-common.ps1", common), ("msp-poll.ps1", poll)):
    try: data.decode("ascii")
    except UnicodeDecodeError: sys.exit(f"{name} must be ASCII only (Windows PowerShell 5.1 mis-reads UTF-8 without a BOM)")

tpl = open(root + "installer.ps1.tmpl", encoding="utf-8").read()
subs = {"MACHINE": e["HOST"], "CUSTOMER": e["CUST"], "SITE": e["SITE"], "SERVER_HOST": e["SERVER_HOST"],
        "REST_USER": vals["server user"], "REST_PASS": vals["server password"], "REPO_PASS": vals["repo password"],
        "PORTAL_URL": e["PORTAL_URL"], "AGENT_TOKEN": e["AGENT_TOKEN"],
        "COMMON_B64": base64.b64encode(common).decode(), "POLL_B64": base64.b64encode(poll).decode(),
        "RESTIC_URL": e["RESTIC_URL"], "RESTIC_SHA256": e["RESTIC_SHA"], "TIME": when, "PATHS": paths_ps,
        "WRAPPER_B64": base64.b64encode(wrapper).decode(), "EXCLUDES_B64": base64.b64encode(excl).decode()}
for k, v in subs.items():
    tpl = tpl.replace("@@" + k + "@@", v)
left = re.findall(r"@@[A-Z0-9_]+@@", tpl)
if left: sys.exit(f"unfilled placeholders: {left}")

old = os.umask(0o077)
open(e["OUT"], "w", encoding="ascii", newline="\r\n").write(tpl)   # CRLF + ASCII: safest for Windows PowerShell 5.1
os.umask(old)
print(f"{e['OUT']}  (daily at {when}; scope: {', '.join(paths)})")
PY
chmod 600 "$out"
echo "Built ${out}"
echo "Deliver securely: it contains this machine's backup credentials. Run it elevated on that PC (use -RunNow for a first backup)."
