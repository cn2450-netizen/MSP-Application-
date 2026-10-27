# Shared helpers for the MSP backup agent scripts (dot-sourced by msp-backup.ps1 and msp-poll.ps1).
# ASCII only: Windows PowerShell 5.1 mis-reads UTF-8 scripts that have no byte-order mark.
$script:AgentVersion = '0.4.0'
$script:Root    = $PSScriptRoot
$script:Restic  = Join-Path $Root 'restic.exe'
$script:LogFile = Join-Path $Root 'backup.log'
$script:Work    = Join-Path $Root 'work'
New-Item -ItemType Directory -Force -Path $script:Work | Out-Null

function Write-Log([string] $Message) {
    if ((Test-Path $script:LogFile) -and ((Get-Item $script:LogFile).Length -gt 5MB)) { Move-Item -Force $script:LogFile "$($script:LogFile).1" }
    Add-Content -Path $script:LogFile -Value ("{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $Message)
}

function Get-AgentConfig { return (Get-Content -Raw -Path (Join-Path $script:Root 'config.json') | ConvertFrom-Json) }

# restic reads its settings from the environment of this process only (nothing is written to the machine's environment)
function Set-ResticEnv($Cfg) {
    $env:RESTIC_REPOSITORY    = "rest:https://$($Cfg.server_host)/$($Cfg.rest_user)"
    $env:RESTIC_REST_USERNAME = $Cfg.rest_user
    $env:RESTIC_REST_PASSWORD = $Cfg.rest_pass
    $env:RESTIC_PASSWORD_FILE = Join-Path $script:Root 'repo.pass'
    $env:RESTIC_CACHE_DIR     = Join-Path $script:Root 'cache'
}

function Format-ResticArgs([string[]] $ArgList) {
    $quoted = foreach ($a in $ArgList) {
        if ($a -eq '') { '""' }
        elseif ($a -match '[\s"]') { '"' + (($a -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"' }
        else { $a }
    }
    return ($quoted -join ' ')
}

# Run restic without tripping Windows PowerShell 5.1's "stderr output is an error" behaviour: output goes to files and
# success is judged by the exit code. OnTick (optional) is called about every 5 seconds while restic runs.
function Invoke-Restic([string[]] $ArgList, [string] $OutFile, [string] $ErrFile, [scriptblock] $OnTick = $null) {
    $p = Start-Process -FilePath $script:Restic -ArgumentList (Format-ResticArgs $ArgList) -NoNewWindow -PassThru `
         -RedirectStandardOutput $OutFile -RedirectStandardError $ErrFile
    $tick = 0
    while (-not $p.WaitForExit(1000)) {
        if ($OnTick -and (++$tick % 5 -eq 0)) { try { & $OnTick } catch { } }
    }
    $p.WaitForExit()
    return [int]$p.ExitCode
}

function Tail-Text([string] $File, [int] $Lines = 4) {
    if (-not (Test-Path $File)) { return '' }
    $t = (Get-Content -Path $File -Tail $Lines -ErrorAction SilentlyContinue) -join ' | '
    $t = ($t -replace '[^\x20-\x7E]', '?') -replace '"', "'"
    if ($t.Length -gt 300) { $t = $t.Substring(0, 300) }
    return $t
}

# A folder on a fixed local drive, written X:\folder\sub. No "..", nothing Windows forbids in names, no control characters.
function Test-DrivePath([string] $Path) {
    if ($Path -notmatch '^[A-Za-z]:\\') { return $false }
    if ($Path -match '[\x00-\x1f<>"|?*]') { return $false }
    foreach ($part in $Path.Substring(3).Split('\')) { if ($part -eq '..' -or $part -eq '.') { return $false } }
    if ($Path.Substring(2) -match ':') { return $false }
    return $true
}

# The newest restic "status" line of a run in progress, as a small object (or $null).
function Get-ResticProgress([string] $OutFile) {
    if (-not (Test-Path $OutFile)) { return $null }
    $line = Get-Content -Path $OutFile -Tail 5 -ErrorAction SilentlyContinue | Where-Object { $_ -like '*"message_type":"status"*' } | Select-Object -Last 1
    if (-not $line) { return $null }
    try { $s = $line | ConvertFrom-Json } catch { return $null }
    $o = @{}
    if ($s.PSObject.Properties['percent_done']) { $o.percent_done = [math]::Min(1.0, [double]$s.percent_done) }
    if ($s.PSObject.Properties['files_done'])   { $o.files_done = [int64]$s.files_done }
    if ($s.PSObject.Properties['total_files'])  { $o.total_files = [int64]$s.total_files }
    if ($s.PSObject.Properties['bytes_done'])   { $o.bytes_done = [int64]$s.bytes_done }
    if ($s.PSObject.Properties['total_bytes'])  { $o.total_bytes = [int64]$s.total_bytes }
    return $o
}
