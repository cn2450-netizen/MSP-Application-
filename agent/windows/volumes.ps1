# Emits one line per fixed drive as InfluxDB line protocol for Telegraf's exec input.
# Adds what Telegraf's built-in disk input lacks: the volume label, so dashboards can show
# "C: (Windows)" instead of a raw path. The label is part of the "name" tag; it is just "C:" when empty.
# ASCII only: Windows PowerShell 5.1 mis-reads UTF-8 scripts that have no byte-order mark.
$ErrorActionPreference = 'Stop'
$inv = [Globalization.CultureInfo]::InvariantCulture

# Line-protocol tag values: no backslashes, and escape comma / equals / space.
function Esc([string] $s) {
    $s = $s -replace '[^\x20-\x7E]', '?'
    return $s.Replace('\', '-').Replace(',', '\,').Replace('=', '\=').Replace(' ', '\ ')
}

try {
    foreach ($v in (Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' })) {
        $size = [double]$v.Size
        if ($size -le 0) { continue }
        $free  = [double]$v.SizeRemaining
        $drive = "$($v.DriveLetter):"
        $label = [string]$v.FileSystemLabel
        $name  = if ($label) { "$drive ($label)" } else { $drive }
        $used  = (($size - $free) / $size * 100).ToString('0.00', $inv)
        "volume,drive=$(Esc $drive),name=$(Esc $name) size_bytes=$([int64]$size)i,free_bytes=$([int64]$free)i,used_percent=$used"
    }
}
catch {
    "volume_error,reason=query_failed value=1i"
}
