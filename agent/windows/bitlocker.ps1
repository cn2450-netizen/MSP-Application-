# Emits BitLocker state per volume as InfluxDB line protocol for Telegraf's exec input.
# Runs as LocalSystem under the Telegraf service. On editions without BitLocker
# (e.g. Windows Home) it emits bitlocker_error so the gap is visible, not silent.
$ErrorActionPreference = 'Stop'
$inv = [Globalization.CultureInfo]::InvariantCulture

try {
    foreach ($v in Get-BitLockerVolume) {
        $mp     = ($v.MountPoint -replace ':', '')
        $prot   = if ("$($v.ProtectionStatus)" -eq 'On') { 1 } else { 0 }
        $locked = if ("$($v.LockStatus)" -eq 'Locked') { 1 } else { 0 }
        $pct    = ([double]$v.EncryptionPercentage).ToString('0.0', $inv)
        "bitlocker,volume=$mp protection_status=${prot}i,locked=${locked}i,encryption_percentage=$pct,volume_status=`"$($v.VolumeStatus)`""
    }
}
catch {
    "bitlocker_error,reason=query_failed value=1i"
}
