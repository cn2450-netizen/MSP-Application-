<#
.SYNOPSIS
  Installs the monitoring agent (Telegraf) as a Windows service for one customer.

.NOTES
  Run elevated. Place the vendor telegraf.exe next to this script first and pass its
  SHA256 (from the release page) so the install refuses a tampered binary.
  The config holds the customer's write-only credentials, so it is ACL'd to SYSTEM + Administrators.
#>
param(
    [Parameter(Mandatory)] [string] $Customer,
    [Parameter(Mandatory)] [string] $IngestHost,
    [Parameter(Mandatory)] [string] $InfluxWriteToken,
    [Parameter(Mandatory)] [string] $LokiPushKey,
    [Parameter(Mandatory)] [string] $TelegrafSha256,
    [string] $InstallDir = "$env:ProgramFiles\MSP-Agent"
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

if ($Customer -notmatch '^[a-z0-9][a-z0-9-]{1,30}$') { throw 'Invalid customer slug.' }

$exe = Join-Path $here 'telegraf.exe'
if (-not (Test-Path $exe)) { throw "telegraf.exe not found next to this script." }
if ((Get-FileHash $exe -Algorithm SHA256).Hash -ne $TelegrafSha256.ToUpper()) {
    throw 'telegraf.exe SHA256 mismatch — refusing to install.'
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Copy-Item $exe, (Join-Path $here 'bitlocker.ps1') $InstallDir -Force

$conf = Get-Content (Join-Path $here 'telegraf.conf.tmpl') -Raw
$conf = $conf.Replace('{{CUSTOMER}}', $Customer).
              Replace('{{INGEST_HOST}}', $IngestHost).
              Replace('{{INFLUX_WRITE_TOKEN}}', $InfluxWriteToken).
              Replace('{{LOKI_PUSH_KEY}}', $LokiPushKey).
              Replace('{{AGENT_DIR}}', $InstallDir)
$confPath = Join-Path $InstallDir 'telegraf.conf'
Set-Content -Path $confPath -Value $conf -Encoding UTF8

# Lock the directory down: SYSTEM + Administrators only.
icacls $InstallDir /inheritance:r /grant:r 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F' | Out-Null

& (Join-Path $InstallDir 'telegraf.exe') --config $confPath --service install
Start-Service telegraf
Write-Host "Agent installed for '$Customer'. Check: Get-Service telegraf"
