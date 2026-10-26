# Emits BitLocker state per volume as InfluxDB line protocol for Telegraf's exec input.
# Runs as LocalSystem under the Telegraf service. On editions without BitLocker
# (e.g. Windows Home) it emits bitlocker_error so the gap is visible, not silent.
# The "name" tag is the drive letter plus its volume label when one exists ("C: (Windows)" or just "C:").
# ASCII only: Windows PowerShell 5.1 mis-reads UTF-8 scripts that have no byte-order mark.
$ErrorActionPreference = 'Stop'
$inv = [Globalization.CultureInfo]::InvariantCulture

function Esc([string] $s) {
    $s = $s -replace '[^\x20-\x7E]', '?'
    return $s.Replace('\', '-').Replace(',', '\,').Replace('=', '\=').Replace(' ', '\ ')
}

try {
    foreach ($v in Get-BitLockerVolume) {
        $mp     = ($v.MountPoint -replace ':', '')
        $prot   = if ("$($v.ProtectionStatus)" -eq 'On') { 1 } else { 0 }
        $locked = if ("$($v.LockStatus)" -eq 'Locked') { 1 } else { 0 }
        $pct    = ([double]$v.EncryptionPercentage).ToString('0.0', $inv)

        $label = ''
        try { $label = [string](Get-Volume -DriveLetter $mp -ErrorAction Stop).FileSystemLabel } catch { }
        $name = if ($label) { "${mp}: ($label)" } else { "${mp}:" }

        "bitlocker,volume=$(Esc $mp),name=$(Esc $name) protection_status=${prot}i,locked=${locked}i,encryption_percentage=$pct,volume_status=`"$($v.VolumeStatus)`""
    }
}
catch {
    "bitlocker_error,reason=query_failed value=1i"
}
