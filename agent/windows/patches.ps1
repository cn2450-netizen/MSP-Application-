# Emits Windows patch history as InfluxDB line protocol for Telegraf's exec input.
#
# No single Windows source is complete, so two are merged and de-duplicated by KB number:
#   source=wua     Windows Update Agent history: installs AND failures (Get-HotFix cannot show failures).
#                  Can be nearly empty on machines patched by other tools or whose history was reset.
#   source=hotfix  Get-HotFix: updates currently installed, with their install date.
# Each run re-emits the recent history stamped "now"; the dashboard collapses repeats with last() per
# (kb, result, operation, date), so nothing piles up and retention limits can never reject old points.
# Daily Defender signature updates are skipped: they would drown out the real patches.
# ASCII only: Windows PowerShell 5.1 mis-reads UTF-8 scripts that have no byte-order mark.
$ErrorActionPreference = 'Stop'
$inv = [Globalization.CultureInfo]::InvariantCulture

function EscTag([string] $s) {
    $s = $s -replace '[^\x20-\x7E]', '?'
    return $s.Replace('\', '-').Replace(',', '\,').Replace('=', '\=').Replace(' ', '\ ')
}
function EscStr([string] $s) {
    $s = $s -replace '[^\x20-\x7E]', '?'
    return '"' + $s.Replace('\', '\\').Replace('"', '\"') + '"'
}
function Emit([string] $kb, [string] $result, [string] $op, [string] $date, [string] $source, [string] $title, [int] $hresult) {
    "patch_history,kb=$(EscTag $kb),result=$result,operation=$op,date=$date,source=$source title=$(EscStr $title),hresult=${hresult}i"
}

$seenInstalled = @{}   # KBs already reported as installed by the Windows Update history

try {
    $session  = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $total    = $searcher.GetTotalHistoryCount()
    $count    = [Math]::Min($total, 300)
    if ($count -gt 0) {
        foreach ($e in $searcher.QueryHistory(0, $count)) {
            if (-not $e.Title) { continue }
            if ($e.Title -match 'Security Intelligence Update|Definition Update') { continue }

            $kb = 'none'
            if ($e.Title -match '(KB\d{4,8})') { $kb = $Matches[1] }

            switch ([int]$e.ResultCode) {
                1 { $result = 'InProgress' }
                2 { $result = 'Succeeded' }
                3 { $result = 'SucceededWithErrors' }
                4 { $result = 'Failed' }
                5 { $result = 'Aborted' }
                default { $result = 'Unknown' }
            }
            switch ([int]$e.Operation) {
                1 { $op = 'Install' }
                2 { $op = 'Uninstall' }
                default { $op = 'Other' }
            }
            if ($result -eq 'Succeeded' -and $op -eq 'Install' -and $kb -ne 'none') { $seenInstalled[$kb] = $true }
            Emit $kb $result $op ($e.Date.ToString('yyyy-MM-dd', $inv)) 'wua' $e.Title ([int]$e.HResult)
        }
    }
}
catch {
    "patch_history_error,reason=wua_query_failed value=1i"
}

try {
    foreach ($h in (Get-HotFix)) {
        if (-not $h.HotFixID -or $seenInstalled.ContainsKey($h.HotFixID)) { continue }
        $date = 'unknown'
        if ($h.InstalledOn) { $date = ([datetime]$h.InstalledOn).ToString('yyyy-MM-dd', $inv) }
        Emit $h.HotFixID 'Succeeded' 'Install' $date 'hotfix' ("$($h.Description) $($h.HotFixID)") 0
    }
}
catch {
    "patch_history_error,reason=hotfix_query_failed value=1i"
}
