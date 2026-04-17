<#
.SYNOPSIS
    Checks BitLocker encryption status and TPM health on the C: drive.

.DESCRIPTION
    Collects all BitLocker and TPM data silently first, then reasons across the findings
    to surface actionable issues. Outputs a clean header, a FINDINGS block with
    interpreted results, and a compact DETAIL block for raw reference.
    Designed to fit in one ticket note or terminal screenshot.

.EXAMPLE
    .\Get-BitLockerHealth.ps1

.NOTES
    Author:  Lachlan Alston
    Version: v1
    Updated: 2026-04-17
#>

[CmdletBinding()]
param()

# ─────────────────────────────────────────────────────────────
#  HELPERS
# ─────────────────────────────────────────────────────────────

function Write-Divider { param([string]$T)
    Write-Host "── $T " -ForegroundColor Cyan -NoNewline
    Write-Host ('─' * [Math]::Max(1, 56 - $T.Length)) -ForegroundColor Cyan
}

function Write-KV { param([string]$K, [string]$V, [string]$C = 'White')
    Write-Host ("  {0,-20} {1}" -f $K, $V) -ForegroundColor $C
}

$findings = [System.Collections.Generic.List[hashtable]]::new()
function Add-Finding { param([string]$Severity, [string]$Title, [string]$Detail)
    $findings.Add(@{ Severity = $Severity; Title = $Title; Detail = $Detail })
}

# ─────────────────────────────────────────────────────────────
#  COLLECT
# ─────────────────────────────────────────────────────────────
$scriptStart = Get-Date

try {
    $cs          = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    $rawUser     = $cs.UserName
    $currentUser = if ($rawUser) { $rawUser.Split('\')[-1] } else { '(unknown)' }
    $model       = if ($cs.Model) { $cs.Model } else { '(unknown)' }
} catch {
    $currentUser = '(unknown)'; $model = '(unknown)'
}

try { $serial = (Get-CimInstance Win32_BIOS -ErrorAction Stop).SerialNumber } catch { $serial = '(unknown)' }

try {
    $os        = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $osCaption = $os.Caption -replace 'Microsoft Windows', 'Windows' -replace 'Professional', 'Pro'
    $osBuild   = $os.BuildNumber
    $uptime    = (Get-Date) - $os.LastBootUpTime
    $uptimeStr = if ($uptime.Days -gt 0) { "$($uptime.Days)d $($uptime.Hours)h" } else { "$($uptime.Hours)h $($uptime.Minutes)m" }
} catch {
    $osCaption = '(unknown)'; $osBuild = '(unknown)'; $uptimeStr = '(unknown)'
}

# BitLocker
$blProtectionStatus = 'Error'
$blVolumeStatus     = 'Unknown'
$blEncryptionPct    = 0
$blEncryptionMethod = 'Unknown'
$blKeyProtectors    = @()
$blRecoveryKeyId    = '(none)'
$blHasTpm           = $false
$blHasRecoveryPwd   = $false
$blHasPin           = $false

try {
    $blv                = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
    $blProtectionStatus = $blv.ProtectionStatus.ToString()
    $blVolumeStatus     = $blv.VolumeStatus.ToString()
    $blEncryptionPct    = $blv.EncryptionPercentage
    $blEncryptionMethod = $blv.EncryptionMethod.ToString()
    $blKeyProtectors    = $blv.KeyProtector

    $blHasTpm         = [bool]($blKeyProtectors | Where-Object { $_.KeyProtectorType -in 'Tpm', 'TpmPin', 'TpmStartupKey', 'TpmPinStartupKey' })
    $blHasPin         = [bool]($blKeyProtectors | Where-Object { $_.KeyProtectorType -in 'TpmPin', 'TpmPinStartupKey', 'Password' })
    $recoveryProt     = $blKeyProtectors | Where-Object { $_.KeyProtectorType -in 'RecoveryPassword', 'AzureAdRecoveryPassword' } | Select-Object -First 1
    $blHasRecoveryPwd = [bool]$recoveryProt
    if ($recoveryProt) { $blRecoveryKeyId = $recoveryProt.KeyProtectorId -replace '[{}]', '' }
} catch {
    $blProtectionStatus = 'Error'
}

# Used space only + PCR profile via WMI (locale-independent)
$blUsedSpaceOnly = $false
$pcrProfile      = '(not available)'
$pcrValid        = $null

try {
    $cimVol = Get-CimInstance -Namespace 'Root\CIMv2\Security\MicrosoftVolumeEncryption' `
                              -ClassName 'Win32_EncryptableVolume' `
                              -Filter "DriveLetter='C:'" -ErrorAction Stop

    try {
        $convStatus      = Invoke-CimMethod -InputObject $cimVol -MethodName 'GetConversionStatus' -ErrorAction Stop
        $blUsedSpaceOnly = ($convStatus.EncryptionFlags -band 1) -ne 0
    } catch { }

    try {
        $tpmProt = $blKeyProtectors | Where-Object { $_.KeyProtectorType -in 'Tpm', 'TpmPin', 'TpmStartupKey', 'TpmPinStartupKey' } | Select-Object -First 1
        if ($tpmProt) {
            $pcrResult  = Invoke-CimMethod -InputObject $cimVol -MethodName 'GetKeyProtectorValidationProfile' `
                                           -Arguments @{ VolumeKeyProtectorID = $tpmProt.KeyProtectorId } -ErrorAction Stop
            $pcrIndices = $pcrResult.ValidationProfile
            if ($null -ne $pcrIndices -and $pcrIndices.Count -gt 0) {
                $pcrProfile = ($pcrIndices | Sort-Object) -join ', '
                $pcrValid   = ($pcrIndices -contains 7) -and ($pcrIndices -contains 11)
            } else {
                $pcrProfile = '(empty)'; $pcrValid = $false
            }
        } else {
            $pcrProfile = '(no TPM protector)'; $pcrValid = $null
        }
    } catch {
        $pcrProfile = '(query error)'; $pcrValid = $false
    }
} catch { }

# UEFI / Secure Boot
$isUEFI        = $false
$secureBoot    = $false
$secureBootStr = 'Unknown'

try {
    $peFwType = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name 'PEFirmwareType' -ErrorAction Stop).PEFirmwareType
    $isUEFI   = ($peFwType -eq 2)
} catch {
    try { $null = Confirm-SecureBootUEFI; $isUEFI = $true }
    catch [System.PlatformNotSupportedException] { $isUEFI = $false }
    catch { $isUEFI = $false }
}

try {
    if ($isUEFI) {
        $secureBoot    = Confirm-SecureBootUEFI
        $secureBootStr = if ($secureBoot) { 'Enabled' } else { 'Disabled' }
    } else {
        $secureBootStr = 'N/A (Legacy BIOS)'
    }
} catch { $secureBootStr = '(error)' }

# TPM
$tpmPresent      = $false
$tpmEnabled      = $false
$tpmActivated    = $false
$tpmReady        = $false
$tpmSpecVersion  = '(unknown)'
$tpmManufacturer = '(unknown)'
$tpmFwVersion    = '(unknown)'

try {
    $tpm             = Get-Tpm -ErrorAction Stop
    $tpmPresent      = [bool]$tpm.TpmPresent
    $tpmEnabled      = [bool]$tpm.TpmEnabled
    $tpmActivated    = [bool]$tpm.TpmActivated
    $tpmReady        = [bool]$tpm.TpmReady
    $tpmSpecVersion  = if ($tpm.SpecVersion) { $tpm.SpecVersion.Split(',')[0].Trim() } else { '(unknown)' }
    $tpmManufacturer = if ($tpm.ManufacturerIdTxt) { $tpm.ManufacturerIdTxt.Trim() } else { '(unknown)' }
    $tpmFwVersion    = if ($tpm.ManufacturerVersion) { $tpm.ManufacturerVersion } else { '(unknown)' }
} catch { $tpmPresent = $false }

# ─────────────────────────────────────────────────────────────
#  REASON
# ─────────────────────────────────────────────────────────────

# BitLocker collection failed
if ($blProtectionStatus -eq 'Error') {
    Add-Finding 'CRIT' 'Unable to query BitLocker status on C:' `
        'Run Get-BitLockerVolume -MountPoint C: manually — may require elevation or BitLocker may not be installed.'
}

# BitLocker not enabled at all (drive fully decrypted)
if ($blProtectionStatus -eq 'Off' -and $blVolumeStatus -eq 'FullyDecrypted') {
    Add-Finding 'CRIT' 'BitLocker is not enabled on C:' `
        'Enable BitLocker via Settings > Privacy & Security > Device Encryption, or manage-bde -on C: — then re-check Intune compliance.'
}

# BitLocker protection off but drive is encrypted — distinguish suspended vs waiting for activation
if ($blProtectionStatus -eq 'Off' -and $blVolumeStatus -eq 'FullyEncrypted') {
    if ($blKeyProtectors.Count -gt 0) {
        Add-Finding 'WARN' 'BitLocker protection is suspended on C:' `
            'Resume via: manage-bde -protectors -enable C: — commonly caused by Windows Update, BIOS changes, or manual suspension.'
    } else {
        Add-Finding 'WARN' 'BitLocker is waiting for activation on C:' `
            'Drive was auto-encrypted by Windows but has no key protectors — sync Intune policy to complete activation, or add a TPM protector manually via manage-bde -protectors -add C: -tpm.'
    }
}

# Decryption actively in progress
if ($blVolumeStatus -in 'DecryptionInProgress', 'DecryptionSuspended') {
    Add-Finding 'CRIT' 'C: drive is being decrypted' `
        'Decryption is in progress — confirm this is intentional, or pause with manage-bde -pause C: and investigate.'
}

# Encryption incomplete or stalled
if ($blVolumeStatus -in 'EncryptionInProgress', 'PartiallyEncrypted', 'EncryptionSuspended') {
    Add-Finding 'WARN' "C: encryption is incomplete ($blEncryptionPct%)" `
        'Encryption is in progress or stalled — check state with manage-bde -status C: and resume with manage-bde -resume C: if paused.'
}

# No TPM key protector (only relevant if BitLocker is on)
if ($blProtectionStatus -eq 'On' -and -not $blHasTpm) {
    Add-Finding 'CRIT' 'No TPM key protector on C:' `
        'BitLocker is running without TPM binding — add via manage-bde -protectors -add C: -tpm, then re-check Intune compliance.'
}

# No recovery password protector
if ($blProtectionStatus -eq 'On' -and -not $blHasRecoveryPwd) {
    Add-Finding 'WARN' 'No recovery password protector on C:' `
        'Add a recovery password via manage-bde -protectors -add C: -recoverypassword and upload the key ID to SharePoint.'
}

# Weak PCR profile (only check if BitLocker is on with a TPM protector)
if ($blProtectionStatus -eq 'On' -and $blHasTpm -and $pcrValid -eq $false) {
    Add-Finding 'WARN' "TPM PCR profile may be weak — PCR 7 or 11 missing ($pcrProfile)" `
        'PCR 7 (Secure Boot) and PCR 11 (BitLocker access control) should both be present — review with manage-bde -protectors -get C:.'
}

# TPM not present
if (-not $tpmPresent) {
    Add-Finding 'CRIT' 'TPM chip not detected by Windows' `
        'Check BIOS/UEFI firmware — TPM may be disabled under Security settings. If physically absent, BitLocker TPM binding and Intune compliance will fail.'
} else {
    # TPM present but not fully ready
    if (-not $tpmEnabled -or -not $tpmActivated) {
        Add-Finding 'CRIT' 'TPM is present but not fully enabled or activated' `
            'Enable and activate TPM in BIOS/UEFI Security settings, then confirm ready state with tpm.msc.'
    }
    if ($tpmEnabled -and $tpmActivated -and -not $tpmReady) {
        Add-Finding 'WARN' 'TPM is enabled but not in a ready state' `
            'Open tpm.msc and complete any pending action — may require TPM owner initialisation or a firmware update.'
    }
    # TPM spec version below 2.0
    if ($tpmSpecVersion -ne '(unknown)') {
        try {
            if ([int]($tpmSpecVersion -replace '\..*', '') -lt 2) {
                Add-Finding 'WARN' "TPM spec version is $tpmSpecVersion — below required 2.0" `
                    'Modern Intune compliance requires TPM 2.0 — check for a firmware upgrade or flag for hardware replacement.'
            }
        } catch { }
    }
}

# Secure Boot disabled (UEFI only — Legacy BIOS flagged separately)
if ($isUEFI -and -not $secureBoot) {
    Add-Finding 'WARN' 'Secure Boot is disabled' `
        'Enable Secure Boot in UEFI firmware settings — required for the TPM/BitLocker chain of trust and Intune compliance.'
}

# Legacy BIOS mode
if (-not $isUEFI) {
    Add-Finding 'WARN' 'Device is running in Legacy BIOS mode (not UEFI)' `
        'Legacy BIOS blocks Secure Boot and proper TPM 2.0 operation — check BIOS for a UEFI/CSM mode switch, or flag for hardware review.'
}

# PIN / Windows Hello — advisory only
if ($blProtectionStatus -eq 'On' -and -not $blHasPin) {
    Add-Finding 'INFO' 'No PIN or Windows Hello protector configured' `
        'TPM-only mode auto-unlocks at boot — consider adding a PIN via manage-bde -protectors -add C: -tpmandpin for higher-security clients.'
}

# ─────────────────────────────────────────────────────────────
#  OUTPUT
# ─────────────────────────────────────────────────────────────

$termWidth = $Host.UI.RawUI.WindowSize.Width
if ($termWidth -gt 0 -and $termWidth -lt 90) {
    Write-Host "  [WARN] Terminal is $termWidth cols wide — output may wrap. Recommended: 90+ cols." -ForegroundColor Yellow
}

$runAt = Get-Date -Format 'yyyy-MM-dd HH:mm'

Write-Host ""
Write-Host ("  ┌─ BITLOCKER & TPM HEALTH " + ('─' * 35) + "┐") -ForegroundColor Cyan
Write-Host ("  │  {0,-58}│" -f "Host    $env:COMPUTERNAME") -ForegroundColor Cyan
Write-Host ("  │  {0,-58}│" -f "User    $currentUser") -ForegroundColor Cyan
Write-Host ("  │  {0,-58}│" -f "Model   $model") -ForegroundColor Cyan
Write-Host ("  │  {0,-58}│" -f "S/N     $serial") -ForegroundColor Cyan
Write-Host ("  │  {0,-58}│" -f "OS      $osCaption  Build $osBuild") -ForegroundColor Cyan
Write-Host ("  │  {0,-58}│" -f "Uptime  $uptimeStr") -ForegroundColor Cyan
Write-Host ("  │  {0,-58}│" -f "Run     $runAt") -ForegroundColor Cyan
Write-Host ("  └" + ('─' * 60) + "┘") -ForegroundColor Cyan
Write-Host ""

# Findings — sorted CRIT → WARN → INFO
$findings = $findings | Sort-Object { switch ($_.Severity) { 'CRIT' { 0 } 'WARN' { 1 } default { 2 } } }

Write-Divider 'FINDINGS'
if ($findings.Count -eq 0) {
    Write-Host "  [OK] No issues found — BitLocker and TPM look healthy." -ForegroundColor Green
} else {
    foreach ($f in $findings) {
        $icon  = if ($f.Severity -eq 'INFO') { '[--]' } else { '[!!]' }
        $color = switch ($f.Severity) { 'CRIT' { 'Red' } 'WARN' { 'Yellow' } default { 'Cyan' } }
        Write-Host "  $icon $($f.Title)" -ForegroundColor $color
        Write-Host "       $($f.Detail)" -ForegroundColor DarkGray
    }
}

$issueCount = ($findings | Where-Object { $_.Severity -in 'CRIT', 'WARN' }).Count
$countLabel = "$issueCount issue(s) found"
$countColor = if ($issueCount -gt 0) { 'Yellow' } else { 'Green' }
Write-Host ""
Write-Host "── $countLabel " -ForegroundColor $countColor -NoNewline
Write-Host ('─' * [Math]::Max(1, 56 - $countLabel.Length)) -ForegroundColor $countColor

# Detail — BitLocker
Write-Host ""
Write-Divider 'DETAIL — BITLOCKER'

$blStatusColor = if ($blProtectionStatus -ne 'On') { 'Red' } else { 'Green' }
Write-KV 'Protection' $blProtectionStatus $blStatusColor

$blVsColor = if ($blVolumeStatus -ne 'FullyEncrypted') { 'Yellow' } else { 'White' }
Write-KV 'Volume Status' $blVolumeStatus $blVsColor

$blPctColor = if ($blEncryptionPct -lt 100) { 'Yellow' } else { 'White' }
Write-KV 'Encrypted' "$blEncryptionPct%" $blPctColor

Write-KV 'Method' $blEncryptionMethod

$diskModeStr   = if ($blUsedSpaceOnly) { 'Used Space Only' } else { 'Full Disk' }
$diskModeColor = if ($blUsedSpaceOnly) { 'Yellow' } else { 'White' }
Write-KV 'Disk Mode' $diskModeStr $diskModeColor

$protectorList = if ($blKeyProtectors.Count -gt 0) {
    ($blKeyProtectors | ForEach-Object { $_.KeyProtectorType.ToString() }) -join ', '
} else { '(none)' }
Write-KV 'Key Protectors' $protectorList

$rkColor = if ($blRecoveryKeyId -eq '(none)') { 'Yellow' } else { 'DarkGray' }
Write-KV 'Recovery Key ID' $blRecoveryKeyId $rkColor

$pcrColor = if ($pcrValid -eq $false) { 'Yellow' } else { 'White' }
Write-KV 'PCR Profile' $pcrProfile $pcrColor

Write-KV 'PIN / Hello' $(if ($blHasPin) { 'Yes' } else { 'No' })

# Detail — TPM
Write-Host ""
Write-Divider 'DETAIL — TPM'

Write-KV 'Present'  $(if ($tpmPresent)   { 'Yes' } else { 'No' }) $(if (-not $tpmPresent)   { 'Red'    } else { 'White' })
Write-KV 'Enabled'  $(if ($tpmEnabled)   { 'Yes' } else { 'No' }) $(if (-not $tpmEnabled)   { 'Red'    } else { 'White' })
Write-KV 'Activated' $(if ($tpmActivated) { 'Yes' } else { 'No' }) $(if (-not $tpmActivated) { 'Red'    } else { 'White' })
Write-KV 'Ready'    $(if ($tpmReady)     { 'Yes' } else { 'No' }) $(if (-not $tpmReady)     { 'Yellow' } else { 'White' })

$tpmVerColor = 'White'
if ($tpmSpecVersion -ne '(unknown)') {
    try { if ([int]($tpmSpecVersion -replace '\..*', '') -lt 2) { $tpmVerColor = 'Yellow' } } catch { }
}
Write-KV 'Spec Version' $tpmSpecVersion $tpmVerColor
Write-KV 'Manufacturer' $tpmManufacturer
Write-KV 'FW Version'   $tpmFwVersion

# Detail — Firmware
Write-Host ""
Write-Divider 'DETAIL — FIRMWARE'

$bootModeColor = if (-not $isUEFI) { 'Yellow' } else { 'White' }
Write-KV 'Boot Mode' $(if ($isUEFI) { 'UEFI' } else { 'Legacy BIOS' }) $bootModeColor

$sbColor = switch ($secureBootStr) { 'Disabled' { 'Yellow' } 'Enabled' { 'White' } default { 'DarkGray' } }
Write-KV 'Secure Boot' $secureBootStr $sbColor

Write-Host ""
$elapsed = [Math]::Round(((Get-Date) - $scriptStart).TotalSeconds, 1)
Write-Host "  Done in ${elapsed}s  |  $currentUser" -ForegroundColor DarkGray
Write-Host ""
