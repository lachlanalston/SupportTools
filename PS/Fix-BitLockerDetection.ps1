<#
.SYNOPSIS
    Check BitLocker status and fix N-able false "not enabled" detection.
.DESCRIPTION
    After ImmyBot maintenance, N-able can report BitLocker as not enabled because:
      - BDESVC is in a stale state
      - BitLocker protection is suspended (encrypted but protectors disabled)
      - The N-central agent has cached the pre-maintenance state

    This script is safe to run as SYSTEM before user login or from ImmyBot.
    It uses Win32_EncryptableVolume WMI (the same source N-central queries) to
    enumerate drives and check status without requiring a user session.

    Remediation steps performed:
      1. Enumerate BitLocker volumes via WMI (pre-login safe)
      2. Resume protection on any volume that is encrypted but suspended
      3. Restart BDESVC to flush stale state
      4. Force manage-bde status poll on all fixed drives
      5. Restart the N-central Windows Agent so it re-reads the updated state

    Exit codes:
      0 - OS drive is Protected (or encryption is in progress) — N-central should clear
      1 - OS drive is not encrypted / still not protected after remediation
      2 - Unexpected error
.NOTES
    Run as: SYSTEM (N-central AutoHeal / ImmyBot default)
    Minimum rights: Local Administrator
    Tested against: N-able N-central 2020.1+, ImmyBot
#>

#region --- Config ---

# WMI namespace used by N-central and manage-bde for BitLocker status
$script:BitLockerWmiNs    = 'Root\CIMV2\Security\MicrosoftVolumeEncryption'
$script:BitLockerWmiClass = 'Win32_EncryptableVolume'

# Seconds to wait after restarting BDESVC before re-checking status
$script:ServiceSettleSeconds = 5

# Timeout waiting for a service to reach Running state
$script:ServiceTimeoutSeconds = 45

# WMI ConversionStatus values
$script:CS_FullyDecrypted       = 0
$script:CS_FullyEncrypted       = 1
$script:CS_EncryptionInProgress = 2
$script:CS_DecryptionInProgress = 3
$script:CS_EncryptionPaused     = 4
$script:CS_DecryptionPaused     = 5

# WMI ProtectionStatus values
$script:PS_Off     = 0
$script:PS_On      = 1
$script:PS_Unknown = 2

#endregion

#region --- Helpers ---

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')]$Level = 'INFO')
    Write-Output ("[{0}][{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message)
}

function Get-BitLockerWmiVolumes {
    <#
    .SYNOPSIS
        Returns all encryptable volumes from WMI with their protection and conversion status.
        Uses Win32_EncryptableVolume — the same source N-central queries, and reliable
        without a user session (SYSTEM context, pre-login).
    #>
    try {
        $volumes = Get-CimInstance -Namespace $script:BitLockerWmiNs `
                                   -ClassName  $script:BitLockerWmiClass `
                                   -ErrorAction Stop

        foreach ($vol in $volumes) {
            try {
                $prot = Invoke-CimMethod -InputObject $vol -MethodName 'GetProtectionStatus' -ErrorAction Stop
                $conv = Invoke-CimMethod -InputObject $vol -MethodName 'GetConversionStatus'  -ErrorAction Stop

                [PSCustomObject]@{
                    Drive            = $vol.DriveLetter
                    ProtectionStatus = $prot.ProtectionStatus   # 0=Off, 1=On, 2=Unknown
                    ConversionStatus = $conv.ConversionStatus   # 0=FullyDecrypted … 5=DecryptionPaused
                    EncryptionPct    = $conv.EncryptionPercentage
                    IsProtected      = ($prot.ProtectionStatus -eq $script:PS_On)
                    IsEncrypted      = ($conv.ConversionStatus -ne $script:CS_FullyDecrypted)
                    IsInProgress     = ($conv.ConversionStatus -in @($script:CS_EncryptionInProgress,
                                                                      $script:CS_EncryptionPaused,
                                                                      $script:CS_DecryptionInProgress,
                                                                      $script:CS_DecryptionPaused))
                    WmiVolume        = $vol
                }
            }
            catch {
                Write-Log "Could not query status for $($vol.DriveLetter): $_" WARN
            }
        }
    }
    catch {
        Write-Log "Win32_EncryptableVolume WMI query failed: $_" ERROR
    }
}

function Resume-SuspendedProtection {
    <#
    .SYNOPSIS
        If a volume is encrypted but protection is suspended, re-enable the protectors.
        This is the common post-ImmyBot / post-maintenance state.
    #>
    param([PSCustomObject[]]$Volumes)

    foreach ($v in $Volumes) {
        if ($v.IsEncrypted -and -not $v.IsProtected) {
            Write-Log "Drive $($v.Drive): encrypted but protection is Off — re-enabling protectors..."
            try {
                # manage-bde -protectors -enable works pre-login as SYSTEM
                $output = manage-bde.exe -protectors -enable $v.Drive 2>&1
                Write-Log "  manage-bde output: $($output -join ' ')"

                if ($LASTEXITCODE -eq 0) {
                    Write-Log "  Protectors re-enabled on $($v.Drive)."
                }
                else {
                    Write-Log "  manage-bde exited $LASTEXITCODE for $($v.Drive)." WARN
                }
            }
            catch {
                Write-Log "  Failed to re-enable protectors on $($v.Drive): $_" WARN
            }
        }
        elseif ($v.IsInProgress) {
            Write-Log "Drive $($v.Drive): conversion in progress ($($v.EncryptionPct)% encrypted) — no action needed."
        }
        elseif ($v.IsProtected) {
            Write-Log "Drive $($v.Drive): protection is On — no action needed."
        }
        else {
            Write-Log "Drive $($v.Drive): fully decrypted — BitLocker not enabled." WARN
        }
    }
}

function Restart-ServiceSafely {
    param([string]$ServiceName, [int]$TimeoutSeconds = $script:ServiceTimeoutSeconds)

    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Log "Service '$ServiceName' not found — skipping." WARN
        return $false
    }

    Write-Log "Restarting service: $ServiceName (current state: $($svc.Status))"
    try {
        Restart-Service -Name $ServiceName -Force -ErrorAction Stop
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        do { Start-Sleep -Seconds 2; $svc.Refresh() } while ($svc.Status -ne 'Running' -and (Get-Date) -lt $deadline)

        if ($svc.Status -eq 'Running') {
            Write-Log "Service '$ServiceName' is Running."
            return $true
        }
        Write-Log "Service '$ServiceName' did not reach Running within ${TimeoutSeconds}s." WARN
        return $false
    }
    catch {
        Write-Log "Failed to restart '$ServiceName': $_" ERROR
        return $false
    }
}

function Invoke-ManageBdePoll {
    <#
    .SYNOPSIS
        Polls manage-bde -status on every encryptable drive letter to flush the stale cache.
    #>
    param([PSCustomObject[]]$Volumes)

    foreach ($v in $Volumes) {
        if ($v.Drive) {
            Write-Log "  Polling manage-bde -status $($v.Drive)"
            manage-bde.exe -status $v.Drive | Out-Null
        }
    }
}

#endregion

#region --- Main ---

Write-Log "=== Fix-BitLockerDetection starting ==="
$sysDrive = $env:SystemDrive   # e.g. "C:"

try {

    # -------------------------------------------------------------------------
    # Step 1: Check current state via WMI (pre-login safe, same source N-central uses)
    # -------------------------------------------------------------------------
    Write-Log "--- BitLocker status BEFORE remediation (WMI source) ---"
    $volumesBefore = @(Get-BitLockerWmiVolumes)

    if ($volumesBefore.Count -eq 0) {
        Write-Log "No BitLocker-capable volumes found. BitLocker may not be supported on this OS edition." ERROR
        exit 2
    }

    foreach ($v in $volumesBefore) {
        $convDesc = switch ($v.ConversionStatus) {
            0 { 'FullyDecrypted' }       1 { 'FullyEncrypted' }
            2 { 'EncryptionInProgress' } 3 { 'DecryptionInProgress' }
            4 { 'EncryptionPaused' }     5 { 'DecryptionPaused' }
            default { "Unknown($_)" }
        }
        Write-Log ("  Drive={0}  Protected={1}  Conversion={2}  Encrypted={3}%" -f `
            $v.Drive, $v.IsProtected, $convDesc, $v.EncryptionPct)
    }

    # -------------------------------------------------------------------------
    # Step 2: Resume protection on encrypted-but-suspended volumes
    #         Common after ImmyBot maintenance or a Windows Update reboot
    # -------------------------------------------------------------------------
    Write-Log "--- Checking for suspended BitLocker protection ---"
    Resume-SuspendedProtection -Volumes $volumesBefore

    # -------------------------------------------------------------------------
    # Step 3: Restart BDESVC to flush any stale state
    # -------------------------------------------------------------------------
    Write-Log "--- Restarting BitLocker Drive Encryption Service (BDESVC) ---"
    $null = Restart-ServiceSafely -ServiceName 'BDESVC'

    # Allow service to settle before re-polling
    Write-Log "Waiting $($script:ServiceSettleSeconds)s for BDESVC to settle..."
    Start-Sleep -Seconds $script:ServiceSettleSeconds

    # -------------------------------------------------------------------------
    # Step 4: Force manage-bde status poll to flush the WMI/agent cache
    # -------------------------------------------------------------------------
    Write-Log "--- Forcing manage-bde status poll on all BitLocker volumes ---"
    Invoke-ManageBdePoll -Volumes $volumesBefore

    Start-Sleep -Seconds 2

    # -------------------------------------------------------------------------
    # Step 5: Re-check status after remediation
    # -------------------------------------------------------------------------
    Write-Log "--- BitLocker status AFTER remediation (WMI source) ---"
    $volumesAfter = @(Get-BitLockerWmiVolumes)

    foreach ($v in $volumesAfter) {
        $convDesc = switch ($v.ConversionStatus) {
            0 { 'FullyDecrypted' }       1 { 'FullyEncrypted' }
            2 { 'EncryptionInProgress' } 3 { 'DecryptionInProgress' }
            4 { 'EncryptionPaused' }     5 { 'DecryptionPaused' }
            default { "Unknown($_)" }
        }
        Write-Log ("  Drive={0}  Protected={1}  Conversion={2}  Encrypted={3}%" -f `
            $v.Drive, $v.IsProtected, $convDesc, $v.EncryptionPct)
    }

    # -------------------------------------------------------------------------
    # Step 6: Restart N-central Windows Agent so it re-reads the updated state
    #         Skip if not found — the agent will self-correct on its next poll cycle
    # -------------------------------------------------------------------------
    Write-Log "--- Restarting N-central Windows Agent ---"
    $nCentralServices = @(
        'Windows Agent',           # N-central (most common)
        'N-able Windows Agent',    # N-able rebranded versions
        'Windows Agent Service',   # alternate naming
        'SolarWindsMSP RMMAgent',  # legacy SolarWinds MSP
        'Advanced Monitoring Agent'# older GFI/LogicNow
    )

    $agentRestarted = $false
    foreach ($svcName in $nCentralServices) {
        if (Get-Service -Name $svcName -ErrorAction SilentlyContinue) {
            Write-Log "Found N-central agent service: '$svcName'"
            $agentRestarted = Restart-ServiceSafely -ServiceName $svcName
            break
        }
    }

    if (-not $agentRestarted) {
        Write-Log ("N-central agent service not found under known names. " +
                   "The agent will pick up the corrected state on its next polling cycle.") WARN
    }

    # -------------------------------------------------------------------------
    # Step 7: Final pass/fail based on OS drive status
    #         EncryptionInProgress counts as OK — ImmyBot may have just started it
    # -------------------------------------------------------------------------
    $sysVol = $volumesAfter | Where-Object { $_.Drive -eq $sysDrive } | Select-Object -First 1

    if (-not $sysVol) {
        Write-Log "Could not determine BitLocker status for system drive ($sysDrive)." ERROR
        exit 2
    }

    $encOk = $sysVol.IsProtected -or $sysVol.IsInProgress

    if ($encOk) {
        if ($sysVol.IsInProgress) {
            Write-Log ("SUCCESS: Encryption is in progress on $sysDrive ($($sysVol.EncryptionPct)% complete). " +
                       "N-central will report correctly once encryption finishes.")
        }
        else {
            Write-Log "SUCCESS: BitLocker Protection On confirmed for $sysDrive. N-central should now report correctly."
        }
        exit 0
    }
    else {
        Write-Log ("WARNING: BitLocker still reports Protection Off for $sysDrive after remediation. " +
                   "Verify that ImmyBot successfully completed BitLocker configuration on this device.") WARN
        exit 1
    }

}
catch {
    Write-Log "Unhandled exception: $_" ERROR
    exit 2
}

#endregion
