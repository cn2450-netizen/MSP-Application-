# MSP backup job: runs daily as SYSTEM from the "MSPBackup" scheduled task (and on demand from the portal). Backs the
# machine up with restic over HTTPS to the MSP backup server (append-only: this machine can add backups but never
# delete or alter them), then writes a status file the monitoring agent ships to the customer's dashboard.
#   msp-backup.ps1          run a backup now
#   msp-backup.ps1 -Test    only check that the repository is reachable and the passwords are right (no backup)
# ASCII only: Windows PowerShell 5.1 mis-reads UTF-8 scripts that have no byte-order mark.
param([switch] $Test)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'msp-common.ps1')

$cfg        = Get-AgentConfig
$statusFile = Join-Path $Root 'status.influx'
$stateFile  = Join-Path $Root 'state.json'
$lastRunFile = Join-Path $Root 'last-run.json'
Set-ResticEnv $cfg

if ($Test) {
    $out = Join-Path $Work 'test.out'; $err = Join-Path $Work 'test.err'
    $rc = Invoke-Restic @('cat', 'config', '--no-lock') $out $err
    if ($rc -eq 0) { Write-Output 'OK: repository reachable and the passwords are correct.'; exit 0 }
    Write-Output ("FAILED (exit {0}): {1}" -f $rc, (Tail-Text $err)); exit 1
}

$started   = Get-Date
$lastOk    = 0
if (Test-Path $stateFile) { try { $lastOk = [int64]((Get-Content -Raw $stateFile | ConvertFrom-Json).last_success) } catch { $lastOk = 0 } }

# ---- what to back up -----------------------------------------------------------------------------------------------
# The portal's choice (policy.json, written by msp-poll.ps1) wins over what the installer was built with.
$wanted = @()
if ($cfg.paths -and $cfg.paths.Count -gt 0) { $wanted = @($cfg.paths) }
$policyFile = Join-Path $Root 'policy.json'
if (Test-Path $policyFile) {
    try {
        $pol = Get-Content -Raw -Path $policyFile -Encoding UTF8 | ConvertFrom-Json
        $inc = @($pol.include | Where-Object { Test-DrivePath $_ })
        if ($inc.Count -gt 0) { $wanted = $inc; Write-Log ("using the portal's folder choice (version {0})" -f $pol.version) }
    } catch { Write-Log 'policy.json unreadable; using the installer default' }
}
$paths = @()
if ($wanted.Count -gt 0 -and $wanted[0] -ne 'ALL') { $paths = $wanted }
else { $paths = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object { $_.DeviceID + '\' }) }
$paths = @($paths | Where-Object { Test-Path $_ })
if ($paths.Count -eq 0) { Write-Log 'no backup paths exist on this machine'; }

$summary = $null; $rc = 1; $msg = ''
$out = Join-Path $Work 'backup.out'; $err = Join-Path $Work 'backup.err'
for ($attempt = 1; $attempt -le 3 -and $paths.Count -gt 0; $attempt++) {
    $args = @('backup', '--no-lock', '--exclude-cloud-files', '--json',
              '--host', $cfg.machine, '--tag', 'msp', '--exclude-file', (Join-Path $Root 'excludes.txt'))
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

# The same result for the portal (msp-poll.ps1 reports it at its next check-in).
$last = [ordered]@{ result = $result; run_epoch = [int64]$now; duration_s = $dur; files_new = (Num $summary 'files_new')
                    data_added = (Num $summary 'data_added'); bytes_processed = (Num $summary 'total_bytes_processed'); message = $msg }
if ($code -ne 1) { $last.success_epoch = [int64]$now }
if ($snap) { $last.snapshot_id = $snap }
$tmp = "$lastRunFile.tmp"
Set-Content -Path $tmp -Value ($last | ConvertTo-Json -Compress) -Encoding Ascii
Move-Item -Force -Path $tmp -Destination $lastRunFile

Write-Log ("RESULT {0} in {1}s (snapshot {2})" -f $result, $dur, $snap)
exit $code
