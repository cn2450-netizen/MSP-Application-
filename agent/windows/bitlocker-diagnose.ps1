# READ-ONLY report on why BitLocker may not turn on: TPM, boot mode, WinRE, BitLocker policy, current state, Windows build.
# Changes nothing and prints no recovery keys. Run as SYSTEM through MeshCentral (scripts/bitlocker-diagnose.sh).
# ASCII only: Windows PowerShell 5.1 mis-reads UTF-8 scripts that have no byte-order mark.
$ErrorActionPreference = 'Continue'
function Section($t) { "`n=== $t" }

Section 'Windows'
try { $os = Get-CimInstance Win32_OperatingSystem; "$($os.Caption) build $($os.BuildNumber), edition SKU $($os.OperatingSystemSKU)" } catch { "error: $($_.Exception.Message)" }
try { $cs = Get-CimInstance Win32_ComputerSystem; "model: $($cs.Manufacturer) $($cs.Model); domain joined: $($cs.PartOfDomain)" } catch { }

Section 'TPM'
try { Get-Tpm | Format-List TpmPresent, TpmReady, TpmEnabled, TpmActivated, ManagedAuthLevel, OwnerAuth, LockedOut | Out-String -Width 200 } catch { "error: $($_.Exception.Message)" }
try { $t = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName Win32_Tpm; "spec version: $($t.SpecVersion)" } catch { "spec version: unknown ($($_.Exception.Message))" }

Section 'Boot mode and Secure Boot'
try { "Secure Boot enabled: $(Confirm-SecureBootUEFI)" } catch { "Secure Boot: not available (legacy BIOS boot, or not supported): $($_.Exception.Message)" }
try { "firmware type: $((Get-ComputerInfo -Property BiosFirmwareType).BiosFirmwareType)" } catch { }

Section 'Windows Recovery Environment'
reagentc /info 2>&1 | Out-String

Section 'BitLocker state (manage-bde)'
manage-bde -status 2>&1 | Out-String -Width 200

Section 'BitLocker policy (Group Policy / Intune): HKLM\SOFTWARE\Policies\Microsoft\FVE'
try {
    if (Test-Path 'HKLM:\SOFTWARE\Policies\Microsoft\FVE') { Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\FVE' | Format-List * | Out-String -Width 200 }
    else { 'none set' }
} catch { "error: $($_.Exception.Message)" }

Section 'Volumes'
try { Get-Volume | Where-Object { $_.DriveLetter } | Format-Table DriveLetter, FileSystemLabel, FileSystem, DriveType, @{n='SizeGB';e={[math]::Round($_.Size/1GB,1)}}, @{n='FreeGB';e={[math]::Round($_.SizeRemaining/1GB,1)}} -AutoSize | Out-String -Width 200 } catch { }

Section 'Disk layout (system disk)'
try { Get-Partition | Format-Table DiskNumber, PartitionNumber, DriveLetter, Type, @{n='SizeMB';e={[math]::Round($_.Size/1MB)}} -AutoSize | Out-String -Width 200 } catch { }
