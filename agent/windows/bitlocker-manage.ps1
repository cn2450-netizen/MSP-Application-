# Turns BitLocker on for one drive (-Mode Enable) and/or reads its recovery password(s) (-Mode Escrow).
# Pushed to a PC through MeshCentral by scripts/bitlocker-run.sh and run as SYSTEM, then deleted.
# It prints machine-readable lines the host worker parses; nothing else is written anywhere:
#   MSP-BL-KEY|<drive letter>|<protector id>|<48-digit recovery password>
#   MSP-BL-RESULT|ok|<short text>     or     MSP-BL-RESULT|error|<short text>
# Enable: used-space-only XtsAes256 unless the PC's own BitLocker policy says otherwise (full-disk, or a named method). The Windows drive needs a ready TPM (TPM protector, no restart needed:
# -SkipHardwareTest); other drives get a recovery password and auto-unlock. Never decrypts or removes anything.
# ASCII only: Windows PowerShell 5.1 mis-reads UTF-8 scripts that have no byte-order mark.
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z]$')][string] $Volume,
    [ValidateSet('Enable', 'Escrow')][string] $Mode = 'Enable'
)
$ErrorActionPreference = 'Stop'

function Result([string] $state, [string] $text) {
    $text = ($text -replace '[^\x20-\x7E]', '?') -replace '\|', '/'
    if ($text.Length -gt 300) { $text = $text.Substring(0, 300) }
    "MSP-BL-RESULT|$state|$text"
}

function Has-Protector([string] $mp, [string] $type) {
    @((Get-BitLockerVolume -MountPoint $mp).KeyProtector | Where-Object { "$($_.KeyProtectorType)" -eq $type }).Count -gt 0
}

function Recovery-Protectors($mp) {
    @((Get-BitLockerVolume -MountPoint $mp).KeyProtector | Where-Object { "$($_.KeyProtectorType)" -eq 'RecoveryPassword' })
}

# Follow the machine's BitLocker policy (Group Policy / Intune) where it has one: a policy that requires full-disk
# encryption refuses "used space only", and one that names an encryption method refuses ours (1 = full, 2 = used space).
function Policy-Value([string] $name) {
    try { return (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\FVE' -Name $name -ErrorAction Stop).$name } catch { return $null }
}
function Enable-Params([string] $mp, [bool] $isOs) {
    $p = @{ MountPoint = $mp }
    if ($isOs) { $type = Policy-Value 'OSEncryptionType'; $method = Policy-Value 'EncryptionMethodWithXtsOs' }
    else       { $type = Policy-Value 'FDVEncryptionType'; $method = Policy-Value 'EncryptionMethodWithXtsFdv' }
    if ($type -ne 1) { $p.UsedSpaceOnly = $true }
    if ($null -eq $method -and $null -eq (Policy-Value 'EncryptionMethod')) { $p.EncryptionMethod = 'XtsAes256' }
    return $p
}

$step = 'starting'
try {
    $letter = $Volume.ToUpper()
    $mp = "${letter}:"
    if (-not (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue)) {
        Result 'error' 'BitLocker is not available here: this Windows edition does not include it, or the BitLocker feature is not installed (servers need it added, which restarts the server)'; return
    }
    if (-not (Test-Path -LiteralPath "$mp\")) { Result 'error' "drive $mp was not found on this computer"; return }

    $v = Get-BitLockerVolume -MountPoint $mp
    $note = ''

    if ($Mode -eq 'Enable') {
        $status = "$($v.VolumeStatus)"
        if ($status -eq 'FullyDecrypted') {
            if ($mp -eq $env:SystemDrive) {
                $step = 'checking the TPM'
                $tpm = Get-Tpm
                if (-not ($tpm.TpmPresent -and $tpm.TpmReady)) {
                    Result 'error' 'this computer has no ready TPM, so BitLocker cannot protect the Windows drive without a startup key or password: not changed'; return
                }
                # Add only the protectors that are missing (an earlier attempt may have left one behind): policy often
                # requires the recovery password to exist BEFORE encryption starts. Then start encryption with manage-bde,
                # which uses the protectors that are already there instead of trying to add more.
                if (-not (Has-Protector $mp 'RecoveryPassword')) {
                    $step = 'adding the recovery password'
                    Add-BitLockerKeyProtector -MountPoint $mp -RecoveryPasswordProtector | Out-Null
                }
                if (-not (Has-Protector $mp 'Tpm')) {
                    $step = 'adding the TPM protector'
                    Add-BitLockerKeyProtector -MountPoint $mp -TpmProtector | Out-Null
                }
                $step = 'starting encryption'
                $ep = Enable-Params $mp $true
                $bde = @('-on', $mp, '-SkipHardwareTest')
                if ($ep.ContainsKey('UsedSpaceOnly')) { $bde += '-UsedSpaceOnly' }
                if ($ep.ContainsKey('EncryptionMethod')) { $bde += @('-EncryptionMethod', 'xts_aes256') }
                $ErrorActionPreference = 'Continue'      # Windows PowerShell 5.1 turns a native command's stderr into a fatal error otherwise
                $bdeOut = (& manage-bde.exe @bde 2>&1 | Out-String)
                $bdeCode = $LASTEXITCODE
                $ErrorActionPreference = 'Stop'
                if ($bdeCode -ne 0) { throw ("manage-bde failed (" + $bdeCode + "): " + (($bdeOut -replace '\s+', ' ').Trim())) }
            }
            else {
                $step = 'enabling BitLocker with a recovery password'
                $ep = Enable-Params $mp $false
                Enable-BitLocker @ep -RecoveryPasswordProtector | Out-Null
                try { Enable-BitLockerAutoUnlock -MountPoint $mp | Out-Null }
                catch { $note = ' The drive will not unlock by itself until the Windows drive is encrypted: run this again afterwards.' }
            }
            $note = "BitLocker turned on, encrypting in the background.$note"
        }
        elseif ("$($v.ProtectionStatus)" -ne 'On') {
            $step = 'resuming protection'
            Resume-BitLocker -MountPoint $mp | Out-Null
            $note = 'BitLocker was suspended: protection resumed.'
        }
        else { $note = 'BitLocker was already on.' }
    }

    # make sure there is a recovery password, then report every one
    $step = 'reading the recovery key'
    $rps = Recovery-Protectors $mp
    if ($rps.Count -eq 0 -and "$((Get-BitLockerVolume -MountPoint $mp).VolumeStatus)" -ne 'FullyDecrypted') {
        Add-BitLockerKeyProtector -MountPoint $mp -RecoveryPasswordProtector | Out-Null
        $rps = Recovery-Protectors $mp
    }
    if ($rps.Count -eq 0) { Result 'error' "drive $mp is not encrypted, so it has no recovery key"; return }
    foreach ($p in $rps) { "MSP-BL-KEY|$letter|$($p.KeyProtectorId)|$($p.RecoveryPassword)" }
    $now = Get-BitLockerVolume -MountPoint $mp
    $summary = "$note Drive ${mp}: $($now.VolumeStatus), $([int]$now.EncryptionPercentage)% encrypted, protection $($now.ProtectionStatus)."
    Result 'ok' $summary.Trim()
}
catch {
    Result 'error' ("while ${step}: " + [string]$_.Exception.Message)
}
