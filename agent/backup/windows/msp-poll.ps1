# MSP backup agent check-in: runs every minute from the "MSPBackupPoll" scheduled task (SYSTEM).
# It only ever CALLS OUT (HTTPS) to the MSP portal: it reports the backup status, receives the folder choice and at most
# one job (browse folders, back up now, list/search backups, restore), runs it, and reports the result. Nothing listens
# on this machine. While someone has the portal's browse screen open it checks in every few seconds instead.
# ASCII only: Windows PowerShell 5.1 mis-reads UTF-8 scripts that have no byte-order mark.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'msp-common.ps1')
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$cfg = Get-AgentConfig
if (-not $cfg.portal_url -or -not $cfg.agent_token) { exit 0 }                 # portal not configured for this machine
if ($cfg.portal_url -notmatch '^https://[A-Za-z0-9.-]+/?$') { Write-Log 'portal_url must be https://host: refusing'; exit 1 }
Set-ResticEnv $cfg

$lastRunFile = Join-Path $Root 'last-run.json'
$policyFile  = Join-Path $Root 'policy.json'
$taskName = 'MSPBackup'; $taskPath = '\MSP\'
$loopUntil = (Get-Date).AddHours(6)          # a single run never lasts longer than this (the next minute starts a new one)

function Invoke-Portal([string] $Path, $Body) {
    $json = $Body | ConvertTo-Json -Depth 12 -Compress
    return Invoke-RestMethod -Method Post -Uri ($cfg.portal_url.TrimEnd('/') + $Path) `
        -Headers @{ Authorization = 'Bearer ' + $cfg.agent_token } -ContentType 'application/json; charset=utf-8' `
        -Body ([Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 50 -UseBasicParsing
}

function Get-BackupRunning {
    try { return ((Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction Stop).State -eq 'Running') } catch { return $false }
}

function Send-Job([string] $Id, $Body) {
    try { Invoke-Portal "/api/agent/jobs/$Id" $Body | Out-Null } catch { Write-Log ("could not report job {0}: {1}" -f $Id, $_.Exception.Message) }
}

# ---- jobs ----------------------------------------------------------------------------------------------------------
function Get-SnapshotId([string] $S) {
    if ($S -notmatch '^([0-9a-f]{8,64}|latest)$') { throw 'bad snapshot id' }
    return $S
}
function Get-SnapPath([string] $P) {
    if ($P -notmatch '^/' -or $P -match '[\x00-\x1f]') { throw 'bad path' }
    foreach ($part in $P.Split('/')) { if ($part -eq '..' -or $part -eq '.') { throw 'bad path' } }
    return $P
}
function Read-Json([string] $File) {
    $text = Get-Content -Raw -Path $File -Encoding UTF8
    if (-not $text) { return @() }
    return ($text | ConvertFrom-Json)
}
function Fail-Restic([string] $What, [string] $ErrFile) { throw ("{0} failed: {1}" -f $What, (Tail-Text $ErrFile 2)) }

function Job-ListDirs($p) {
    $path = [string]$p.path
    if ($path -eq '') {
        $entries = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Sort-Object DeviceID | ForEach-Object {
            $label = ''; if ($_.VolumeName) { $label = ' (' + $_.VolumeName + ')' }
            @{ name = ($_.DeviceID + $label); path = ($_.DeviceID + '\') } })
        return @{ path = ''; entries = $entries }
    }
    if (-not (Test-DrivePath $path)) { throw 'not a valid folder' }
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw 'that folder does not exist' }
    $dirs = @(Get-ChildItem -LiteralPath $path -Directory -Force -ErrorAction SilentlyContinue | Where-Object {
        -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -and -not (($_.Attributes -band [IO.FileAttributes]::Hidden) -and ($_.Attributes -band [IO.FileAttributes]::System)) } |
        Sort-Object Name | Select-Object -First 1000)
    return @{ path = $path; entries = @($dirs | ForEach-Object { @{ name = $_.Name; path = $_.FullName } }) }
}

function Job-BackupNow($p) {
    if (Get-BackupRunning) { return @{ started = $false; already_running = $true } }
    Start-ScheduledTask -TaskName $taskName -TaskPath $taskPath | Out-Null
    return @{ started = $true }
}

function Job-ListSnapshots($p) {
    $out = Join-Path $Work 'job.out'; $err = Join-Path $Work 'job.err'
    if ((Invoke-Restic @('snapshots', '--json', '--no-lock') $out $err) -ne 0) { Fail-Restic 'listing backups' $err }
    $snaps = @(Read-Json $out | Sort-Object time -Descending | Select-Object -First 200 | ForEach-Object {
        @{ id = $_.short_id; time = $_.time; host = $_.hostname; paths = @($_.paths) } })
    return @{ snapshots = $snaps }
}

function Job-LsSnapshot($p) {
    $snap = Get-SnapshotId ([string]$p.snapshot); $dir = Get-SnapPath ([string]$p.path)
    $out = Join-Path $Work 'job.out'; $err = Join-Path $Work 'job.err'
    if ((Invoke-Restic @('ls', '--json', '--no-lock', $snap, $dir) $out $err) -ne 0) { Fail-Restic 'looking inside the backup' $err }
    $entries = New-Object System.Collections.ArrayList
    $want = $dir.TrimEnd('/')
    foreach ($line in (Get-Content -Path $out -Encoding UTF8)) {
        if ($line -notlike '*"struct_type":"node"*' -and $line -notlike '*"name":*') { continue }
        try { $n = $line | ConvertFrom-Json } catch { continue }
        if (-not $n.PSObject.Properties['path'] -or $n.path.TrimEnd('/') -eq $want) { continue }      # the folder itself
        if ($n.type -ne 'dir' -and $n.type -ne 'file') { continue }
        $size = 0; if ($n.PSObject.Properties['size']) { $size = [int64]$n.size }
        [void]$entries.Add(@{ name = $n.name; path = $n.path; type = $n.type; size = $size; mtime = $n.mtime })
        if ($entries.Count -ge 2000) { break }
    }
    return @{ snapshot = $snap; path = $dir; entries = @($entries) }
}

function Job-Find($p) {
    $pattern = [string]$p.pattern
    if ($pattern -match '^-' -or $pattern -match '[\x00-\x1f]' -or $pattern.Length -gt 100) { throw 'bad search' }
    if ($pattern -notmatch '[*?\[]') { $pattern = '*' + $pattern + '*' }
    $a = @('find', '--json', '--no-lock', '--ignore-case')
    if ($p.snapshot) { $a += @('--snapshot', (Get-SnapshotId ([string]$p.snapshot))) }
    $a += @('--', $pattern)
    $out = Join-Path $Work 'job.out'; $err = Join-Path $Work 'job.err'
    if ((Invoke-Restic $a $out $err) -ne 0) { Fail-Restic 'searching' $err }
    $hits = New-Object System.Collections.ArrayList
    foreach ($grp in @(Read-Json $out)) {
        foreach ($m in @($grp.matches)) {
            $size = 0; if ($m.PSObject.Properties['size']) { $size = [int64]$m.size }
            [void]$hits.Add(@{ snapshot = ([string]$grp.snapshot).Substring(0, 8); path = $m.path; type = $m.type; size = $size; mtime = $m.mtime })
            if ($hits.Count -ge 500) { break }
        }
        if ($hits.Count -ge 500) { break }
    }
    return @{ pattern = [string]$p.pattern; hits = @($hits); truncated = ($hits.Count -ge 500) }
}

function Job-Restore($p, [string] $JobId) {
    $snap = Get-SnapshotId ([string]$p.snapshot)
    $items = @($p.items | ForEach-Object { Get-SnapPath ([string]$_) })
    if ($items.Count -lt 1 -or $items.Count -gt 50) { throw 'nothing to restore' }
    # Always a NEW folder, never the original location: restoring cannot overwrite what is on the machine today.
    $drive = $env:SystemDrive.Substring(0, 1)
    if ($p.drive) { $drive = [string]$p.drive }
    if ($drive -notmatch '^[A-Za-z]$' -or -not (Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3 AND DeviceID='${drive}:'")) { throw 'that drive is not available' }
    $base = "${drive}:\MSP-Restored"
    New-Item -ItemType Directory -Force -Path $base | Out-Null
    # Restored files are customer data: only SYSTEM and Administrators can open them (well-known SIDs, any language).
    & icacls.exe $base /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    $target = Join-Path $base ((Get-Date).ToString('yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    $a = @('restore', $snap, '--no-lock', '--verify', '--json', '--target', $target)
    foreach ($i in $items) {
        # restic reads --include as a pattern: escape characters that would otherwise be wildcards
        $esc = (($i -replace '\[', '[[]') -replace '\*', '[*]') -replace '\?', '[?]'
        $a += @('--include', $esc)
    }
    $out = Join-Path $Work 'job.out'; $err = Join-Path $Work 'job.err'
    $tick = { $pr = Get-ResticProgress $out; if ($pr) { Send-Job $JobId @{ status = 'running'; progress = $pr } } }
    $rc = Invoke-Restic $a $out $err $tick
    if ($rc -ne 0) { Fail-Restic 'restoring' $err }
    $files = 0; $bytes = 0
    $sum = Get-Content -Path $out -Tail 20 -ErrorAction SilentlyContinue | Where-Object { $_ -like '*"message_type":"summary"*' } | Select-Object -Last 1
    if ($sum) { try { $s = $sum | ConvertFrom-Json; if ($s.PSObject.Properties['files_restored']) { $files = [int64]$s.files_restored }; if ($s.PSObject.Properties['bytes_restored']) { $bytes = [int64]$s.bytes_restored } } catch { } }
    Write-Log ("restored {0} item(s) from snapshot {1} into {2}" -f $items.Count, $snap, $target)
    return @{ target = $target; files = $files; bytes = $bytes }
}

function Invoke-AgentJob($job) {
    $id = [string]$job.id
    if ($id -notmatch '^[0-9a-f-]{36}$') { return }
    try {
        $result = switch ([string]$job.type) {
            'list_dirs'      { Job-ListDirs $job.params }
            'backup_now'     { Job-BackupNow $job.params }
            'list_snapshots' { Job-ListSnapshots $job.params }
            'ls_snapshot'    { Job-LsSnapshot $job.params }
            'find'           { Job-Find $job.params }
            'restore'        { Job-Restore $job.params $id }
            default          { throw 'unknown job type' }
        }
        Send-Job $id @{ status = 'done'; result = $result }
    } catch {
        $m = ($_.Exception.Message -replace '[^\x20-\x7E]', '?'); if ($m.Length -gt 400) { $m = $m.Substring(0, 400) }
        Write-Log ("job {0} ({1}) failed: {2}" -f $id, $job.type, $m)
        Send-Job $id @{ status = 'failed'; error = $m }
    }
}

# ---- check-in loop -------------------------------------------------------------------------------------------------
$os = ''
try { $os = (Get-CimInstance Win32_OperatingSystem).Caption } catch { }
$policyVersion = -1
if (Test-Path $policyFile) { try { $policyVersion = [int](Get-Content -Raw -Encoding UTF8 $policyFile | ConvertFrom-Json).version } catch { } }

$scheduleFile = Join-Path $Root 'schedule.json'
$scheduleVersion = -1
if (Test-Path $scheduleFile) { try { $scheduleVersion = [int](Get-Content -Raw -Encoding UTF8 $scheduleFile | ConvertFrom-Json).version } catch { } }

# Moves the nightly backup task to the days/time chosen in the portal. Only the trigger changes (the task keeps its
# SYSTEM account and settings); the version is remembered only after Windows accepted the change.
function Set-BackupSchedule($Sched) {
    $dayNames = @('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday')
    $days = @($Sched.days | ForEach-Object { [int]$_ } | Where-Object { $_ -ge 0 -and $_ -le 6 } | Sort-Object -Unique)
    if ($days.Count -eq 0 -or $days.Count -gt 7) { throw 'bad schedule days' }
    if ([string]$Sched.time -notmatch '^([01][0-9]|2[0-3]):[0-5][0-9]$') { throw 'bad schedule time' }
    $at = [datetime]::ParseExact([string]$Sched.time, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek ($days | ForEach-Object { $dayNames[$_] }) -At $at
    Set-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Trigger $trigger | Out-Null
    $tmp = "$scheduleFile.tmp"
    Set-Content -Path $tmp -Value (@{ version = [int]$Sched.version; days = $days; time = [string]$Sched.time } | ConvertTo-Json -Compress) -Encoding UTF8
    Move-Item -Force -Path $tmp -Destination $scheduleFile
    Write-Log ("backup schedule updated by the portal (version {0}): days {1} at {2}" -f [int]$Sched.version, ($days -join ','), $Sched.time)
}

# "Seen" = the newest version the portal has told us about, applied or not. It is what we report back, so the portal does
# not cut its wait short again and again for a change that cannot be applied (the schedule is retried every 10 minutes).
$policySeen = $policyVersion; $scheduleSeen = $scheduleVersion; $scheduleRetryAfter = Get-Date

# The portal holds each check-in open for up to ~25 seconds and answers the moment there is a job or a changed setting,
# so a click in the portal reaches this computer within a second or so. This script keeps looping for a few hours; the
# every-minute task then starts a fresh copy (a copy that is still running makes the new one exit at once).
do {
    $started = Get-Date
    $running = Get-BackupRunning
    $body = @{ agent_version = $script:AgentVersion; os = $os; wait = $true; busy = [bool]$running
               policy_version = $policySeen; schedule_version = $scheduleSeen }
    if (Test-Path $lastRunFile) { try { $body.last_run = (Get-Content -Raw $lastRunFile | ConvertFrom-Json) } catch { } }
    $body.progress = $null
    if ($running) { $pr = Get-ResticProgress (Join-Path $Work 'backup.out'); if ($pr) { $body.progress = $pr } }

    try { $reply = Invoke-Portal '/api/agent/poll' $body }
    catch { Write-Log ("check-in failed: {0}" -f $_.Exception.Message); exit 0 }

    if ($reply.policy -and [int]$reply.policy.version -ne $policyVersion) {
        $policySeen = [int]$reply.policy.version
        $inc = @($reply.policy.include | Where-Object { Test-DrivePath $_ })
        if ($inc.Count -gt 0) {
            $tmp = "$policyFile.tmp"
            Set-Content -Path $tmp -Value (@{ version = [int]$reply.policy.version; include = $inc } | ConvertTo-Json -Compress) -Encoding UTF8
            Move-Item -Force -Path $tmp -Destination $policyFile
            $policyVersion = [int]$reply.policy.version
            Write-Log ("folder choice updated by the portal (version {0}): {1}" -f $policyVersion, ($inc -join '; '))
        }
    }
    if ($reply.schedule -and [int]$reply.schedule.version -ne $scheduleVersion) {
        $scheduleSeen = [int]$reply.schedule.version
        if ((Get-Date) -ge $scheduleRetryAfter) {
            try { Set-BackupSchedule $reply.schedule; $scheduleVersion = [int]$reply.schedule.version }
            catch { Write-Log ("could not apply the backup schedule (will retry in 10 minutes): {0}" -f $_.Exception.Message); $scheduleRetryAfter = (Get-Date).AddMinutes(10) }
        }
    }
    if ($reply.job) { Invoke-AgentJob $reply.job }
    # an answer that came back at once with nothing to do (an older portal, or an error page) must not become a busy loop
    if (-not $reply.job -and ((Get-Date) - $started).TotalSeconds -lt 2) { Start-Sleep -Seconds 2 }
} while ((Get-Date) -lt $loopUntil)
exit 0
