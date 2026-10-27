# MSP backup job: runs daily as SYSTEM from the "MSPBackup" scheduled task. Backs the machine up with restic over HTTPS
# to the MSP backup server (append-only: this machine can add backups but never delete or alter them), then writes a
# status file the monitoring agent ships to the customer's dashboard.
#   msp-backup.ps1          run a backup now
#   msp-backup.ps1 -Test    only check that the repository is reachable and the passwords are right (no backup)
# ASCII only: Windows PowerShell 5.1 mis-reads UTF-8 scripts that have no byte-order mark.
param([switch] $Test)
$ErrorActionPreference = 'Stop'

$root       = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfg        = Get-Content -Raw -Path (Join-Path $root 'config.json') | ConvertFrom-Json
$restic     = Join-Path $root 'restic.exe'
$logFile    = Join-Path $root 'backup.log'
$statusFile = Join-Path $root 'status.influx'
$stateFile  = Join-Path $root 'state.json'
$work       = Join-Path $root 'work'
New-Item -ItemType Directory -Force -Path $work | Out-Null

function Write-Log([string] $Message) {
    if ((Test-Path $logFile) -and ((Get-Item $logFile).Length -gt 5MB)) { Move-Item -Force $logFile "$logFile.1" }
    Add-Content -Path $logFile -Value ("{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $Message)
}

# restic reads its settings from the environment of this process only (nothing is written to the machine's environment)
$env:RESTIC_REPOSITORY    = "rest:https://$($cfg.server_host)/$($cfg.rest_user)"
$env:RESTIC_REST_USERNAME = $cfg.rest_user
$env:RESTIC_REST_PASSWORD = $cfg.rest_pass
$env:RESTIC_PASSWORD_FILE = Join-Path $root 'repo.pass'
$env:RESTIC_CACHE_DIR     = Join-Path $root 'cache'

# Run restic without tripping Windows PowerShell 5.1's "stderr output is an error" behaviour: output goes to files and
# success is judged by the exit code.
function Invoke-Restic([string[]] $ArgList, [string] $OutFile, [string] $ErrFile) {
    $quoted = foreach ($a in $ArgList) { if ($a -match '[\s"]') { '"' + ($a -replace '"', '\"') + '"' } else { $a } }
    $p = Start-Process -FilePath $restic -ArgumentList ($quoted -join ' ') -NoNewWindow -Wait -PassThru `
         -RedirectStandardOutput $OutFile -RedirectStandardError $ErrFile
    return [int]$p.ExitCode
}

function Tail-Text([string] $File, [int] $Lines = 4) {
    if (-not (Test-Path $File)) { return '' }
    $t = (Get-Content -Path $File -Tail $Lines -ErrorAction SilentlyContinue) -join ' | '
    $t = ($t -replace '[^\x20-\x7E]', '?') -replace '"', "'"
    if ($t.Length -gt 300) { $t = $t.Substring(0, 300) }
    return $t
}

if ($Test) {
    $out = Join-Path $work 'test.out'; $err = Join-Path $work 'test.err'
    $rc = Invoke-Restic @('cat', 'config', '--no-lock') $out $err
    if ($rc -eq 0) { Write-Output 'OK: repository reachable and the passwords are correct.'; exit 0 }
    Write-Output ("FAILED (exit {0}): {1}" -f $rc, (Tail-Text $err)); exit 1
}

$started   = Get-Date
$lastOk    = 0
if (Test-Path $stateFile) { try { $lastOk = [int64]((Get-Content -Raw $stateFile | ConvertFrom-Json).last_success) } catch { $lastOk = 0 } }

# ---- what to back up -----------------------------------------------------------------------------------------------
$paths = @()
if ($cfg.paths -and $cfg.paths.Count -gt 0 -and $cfg.paths[0] -ne 'ALL') { $paths = @($cfg.paths) }
else { $paths = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object { $_.DeviceID + '\' }) }
$paths = @($paths | Where-Object { Test-Path $_ })
if ($paths.Count -eq 0) { Write-Log 'no backup paths exist on this machine'; }

$summary = $null; $rc = 1; $msg = ''
$out = Join-Path $work 'backup.out'; $err = Join-Path $work 'backup.err'
for ($attempt = 1; $attempt -le 3 -and $paths.Count -gt 0; $attempt++) {
    $args = @('backup', '--no-lock', '--exclude-cloud-files', '--json',
              '--host', $cfg.machine, '--tag', 'msp', '--exclude-file', (Join-Path $root 'excludes.txt'))
    # Volume Shadow Copy lets open files (databases, mailboxes) be backed up consistently. On by default; a machine whose
    # volumes cannot be shadow-copied can set "vss": false in config.json.
    $useVss = $true; if ($cfg.PSObject.Properties['vss']) { $useVss = [bool]$cfg.vss }
    if ($useVss) { $args += '--use-fs-snapshot' }
    if ($cfg.limit_upload_kib) { $args += @('--limit-upload', [string]$cfg.limit_upload_kib) }
    $args += $paths
    Write-Log ("backup attempt {0}: {1}" -f $attempt, ($paths -join ' '))
    $rc = Invoke-Restic $args $out $err
    Write-Log ("restic exit code {0}" -f $rc)
    if ($rc -eq 0 -or $rc -eq 3) { break }                 # 3 = snapshot created, but some files could not be read
    $msg = Tail-Text $err
    Write-Log ("failed: {0}" -f $msg)
    if ($attempt -lt 3) { Start-Sleep -Seconds (300 * $attempt) }
}
if (Test-Path $out) {
    $line = Get-Content -Path $out -Tail 40 -ErrorAction SilentlyContinue | Where-Object { $_ -like '*"message_type":"summary"*' } | Select-Object -Last 1
    if ($line) { try { $summary = $line | ConvertFrom-Json } catch { $summary = $null } }
}

function Num($o, [string] $n) { if ($o -and $o.PSObject.Properties[$n]) { return [int64]$o.$n } else { return 0 } }

# ---- result and status line for the monitoring agent -------------------------------------------------------------
if ($paths.Count -eq 0)        { $code = 1; $result = 'failed'; $msg = 'no backup paths found' }
elseif ($rc -eq 0 -and $summary -and (Num $summary 'total_files_processed') -eq 0) {
    # A backup that stored no files is almost certainly wrong (bad exclusions or paths): never report it as success.
    $code = 1; $result = 'failed'; $msg = 'backup processed 0 files: check the exclusions and backup paths'
}
elseif ($rc -eq 0)             { $code = 0; $result = 'ok' }
elseif ($rc -eq 3)             { $code = 2; $result = 'partial'; $msg = Tail-Text $err 3 }
else                           { $code = 1; $result = 'failed' }

$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
if ($code -ne 1) { $lastOk = $now }
(@{ last_success = $lastOk } | ConvertTo-Json) | Set-Content -Path $stateFile

$dur  = [int](((Get-Date) - $started).TotalSeconds)
$snap = ''; if ($summary -and $summary.PSObject.Properties['snapshot_id']) { $snap = [string]$summary.snapshot_id }
$msg  = ($msg -replace '[^\x20-\x7E]', '?') -replace '"', "'"
$lineProto = 'backup_run result_code={0}i,result="{1}",duration_s={2}i,files_new={3}i,files_changed={4}i,files_unmodified={5}i,data_added={6}i,bytes_processed={7}i,snapshot_id="{8}",last_success={9}i,message="{10}" {11}' -f `
    $code, $result, $dur, (Num $summary 'files_new'), (Num $summary 'files_changed'), (Num $summary 'files_unmodified'),
    (Num $summary 'data_added'), (Num $summary 'total_bytes_processed'), $snap, $lastOk, $msg, ($now * 1000000000)
$tmp = "$statusFile.tmp"
Set-Content -Path $tmp -Value $lineProto -Encoding Ascii
Move-Item -Force -Path $tmp -Destination $statusFile
Write-Log ("RESULT {0} in {1}s (snapshot {2})" -f $result, $dur, $snap)
exit $code
