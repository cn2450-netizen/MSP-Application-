#!/usr/bin/env bash
# Build the one-file Windows agent installer for a customer that already exists (add-customer.sh calls
# this automatically; run it by hand to rebuild after changing the template or pinned Telegraf version).
#
# usage: scripts/build-agent-installer.sh <slug>
# output: generated/agents/<slug>/install-agent-<slug>.ps1   (mode 600: it embeds the customer's write-only keys)
set -euo pipefail
cd "$(dirname "$0")/.."

slug="${1:?usage: build-agent-installer.sh <slug>}"
[[ "$slug" =~ ^[a-z0-9][a-z0-9-]{1,30}$ ]] || { echo "invalid slug"; exit 1; }
cred="generated/credentials/${slug}.txt"
[[ -f "$cred" ]] || { echo "no credentials file for '${slug}' ($cred) - onboard the customer first"; exit 1; }
set -a; source agent/windows/version.env; source .env; set +a   # INGEST_HOST comes from .env, not from the credentials file (it can go stale)

out_dir="generated/agents/${slug}"
mkdir -p "$out_dir"
out="${out_dir}/install-agent-${slug}.ps1"

SLUG="$slug" CRED="$cred" INGEST_HOST="${INGEST_HOST:?INGEST_HOST not set in .env}" OUT="$out" TELEGRAF_URL="$TELEGRAF_URL" TELEGRAF_SHA256="$TELEGRAF_SHA256" \
python3 - <<'PY'
import base64, os, re, sys

slug, cred, out = os.environ["SLUG"], os.environ["CRED"], os.environ["OUT"]
vals = {}
for line in open(cred, encoding="utf-8"):
    m = re.match(r"^(influx WRITE tk|loki push key):\s*(\S+)\s*$", line)
    if m: vals[m.group(1)] = m.group(2)
for k in ("influx WRITE tk", "loki push key"):
    if k not in vals: sys.exit(f"credentials file is missing '{k}'")
host = os.environ["INGEST_HOST"].strip().rstrip("/")
if not re.fullmatch(r"[A-Za-z0-9.-]+(:[0-9]+)?", host): sys.exit(f"INGEST_HOST looks wrong: {host!r}")

conf = open("agent/windows/telegraf.conf.tmpl", encoding="utf-8").read()
for k, v in {"CUSTOMER": slug, "INGEST_HOST": host,
             "INFLUX_WRITE_TOKEN": vals["influx WRITE tk"], "LOKI_PUSH_KEY": vals["loki push key"]}.items():
    conf = conf.replace("{{" + k + "}}", v)   # {{AGENT_DIR}} is filled in on the PC at install time
bl = open("agent/windows/bitlocker.ps1", "rb").read()
for name, data in (("telegraf.conf.tmpl", conf.encode()), ("bitlocker.ps1", bl)):
    try: data.decode("ascii")
    except UnicodeDecodeError: sys.exit(f"{name} must be ASCII only (Windows PowerShell 5.1 mis-reads UTF-8 without a BOM)")

tpl = open("agent/windows/installer.ps1.tmpl", encoding="utf-8").read()
for k, v in {"CUSTOMER": slug, "TELEGRAF_URL": os.environ["TELEGRAF_URL"],
             "TELEGRAF_SHA256": os.environ["TELEGRAF_SHA256"],
             "CONF_B64": base64.b64encode(conf.encode()).decode(),
             "BITLOCKER_B64": base64.b64encode(bl).decode()}.items():
    tpl = tpl.replace("@@" + k + "@@", v)
left = re.findall(r"@@[A-Z0-9_]+@@", tpl)
if left: sys.exit(f"unfilled placeholders: {left}")

old = os.umask(0o077)
open(out, "w", encoding="ascii", newline="\r\n").write(tpl)   # CRLF + ASCII: safest for Windows PowerShell 5.1
os.umask(old)
print(out)
PY
chmod 600 "$out"
echo "Built ${out}"
echo "Deliver securely; it contains this customer's write-only ingest credentials. Run it elevated on the PC."
