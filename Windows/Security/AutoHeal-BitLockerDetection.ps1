<#
.SYNOPSIS
    N-central AutoHeal: Refresh stale BitLocker detection after ImmyBot maintenance.
.DESCRIPTION
    Designed to be attached as an AutoHeal script to the N-central BitLocker / Drive
    Encryption monitoring check. When N-central reports BitLocker as disabled despite
    the drive being encrypted, this script restarts BDESVC and forces a manage-bde
    status poll to flush the stale state. N-central re-queries on its next cycle after
    the heal exits.

    IMPORTANT: This script intentionally does NOT restart the Windows Agent service.
    The agent is the process executing this script; restarting it would kill the heal
    mid-run and cause N-central to mark the remediation as failed.

.OUTPUTS
    Exit 0  – BitLocker protection confirmed On  → N-central monitor should clear.
    Exit 1  – BitLocker protection still Off after heal → genuine issue, alert stands.
    Exit 2  – Unexpected error during remediation.

.NOTES
    Runs as: SYSTEM (N-central default for AutoHeal scripts)
    Minimum rights: Local Administrator
    Compatible with: N-able N-central 2020.1+
    Attach to: Security > BitLocker (or equivalent Drive Encryption check)
#>

#region --- Config ---

# Seconds to wait after restarting BDESVC before re-checking status.
# Gives the service time to re-enumerate volumes before manage-bde is polled.
$script:ServiceSettleSeconds = 5

# Timeout waiting for BDESVC to return to Running state after restart.
$script:ServiceTimeoutSeconds = 45

#endregion

#region --- Helpers ---

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')]$Level = 'INFO')
    Write-Output ("[{0}][{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message)
}

function Get-SystemDriveBitLockerStatus {
    <#
    .SYNOPSIS
        Returns a PSCustomObject with Protected ([bool]) and PctEncrypted ([double])
        for the Windows system drive, using manage-bde as the primary source.
    #>
    param([string]$Drive = $env:SystemDrive)   # e.g. "C:"

    $result = [PSCustomObject]@{ Drive = $Drive; Protected = $false; PctEncrypted = $null }

    # manage-bde is available on all supported Windows editions (no extra modules needed)
    try {
        $raw = manage-bde.exe -status $Drive 2>&1
        $statusLine = $raw | Where-Object { $_ -match 'Protection Status' } | Select-Object -First 1
        $pctLine    = $raw | Where-Object { $_ -match 'Percentage Encrypted' } | Select-Object -First 1

        $result.Protected    = ($statusLine -match 'Protection On')
        $result.PctEncrypted = if ($pctLine -match '(\d+(\.\d+)?)%') { [double]$Matches[1] } else { $null }
    }
    catch {
        Write-Log "manage-bde query failed: $_" WARN
    }

    # Cross-check with Get-BitLockerVolume when the module is available
    if (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue) {
        try {
            $vol = Get-BitLockerVolume -MountPoint $Drive -ErrorAction Stop
            # If both sources disagree, prefer the one reporting Protection On
            # (manage-bde is more reliable post-reboot; GBLV can lag on first query)
            if ($vol.ProtectionStatus -eq 'On') { $result.Protected = $true }
        }
        catch {
            Write-Log "Get-BitLockerVolume cross-check failed: $_" WARN
        }
    }

    return $result
}

function Restart-BDESvc {
    $svc = Get-Service -Name 'BDESVC' -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Log "BDESVC not found — BitLocker may not be supported on this OS edition." ERROR
        return $false
    }

    Write-Log "BDESVC current state: $($svc.Status)"
    try {
        Restart-Service -Name 'BDESVC' -Force -ErrorAction Stop
    }
    catch {
        Write-Log "Failed to restart BDESVC: $_" ERROR
        return $false
    }

    # Wait up to $ServiceTimeoutSeconds for Running state
    $deadline = (Get-Date).AddSeconds($script:ServiceTimeoutSeconds)
    do {
        Start-Sleep -Seconds 2
        $svc.Refresh()
    } while ($svc.Status -ne 'Running' -and (Get-Date) -lt $deadline)

    if ($svc.Status -eq 'Running') {
        Write-Log "BDESVC restarted successfully."
        return $true
    }

    Write-Log ("BDESVC did not reach Running state within {0}s (current: {1})." -f `
        $script:ServiceTimeoutSeconds, $svc.Status) ERROR
    return $false
}

function Invoke-ManageBdePoll {
    <#
    .SYNOPSIS
        Runs manage-bde -status against every fixed drive to flush the stale status cache.
    #>
    $drives = (Get-PSDrive -PSProvider FileSystem |
               Where-Object { $_.Root -match '^[A-Z]:\\$' }).Root

    foreach ($drive in $drives) {
        $letter = $drive.TrimEnd('\')
        Write-Log "Polling manage-bde -status $letter"
        manage-bde.exe -status $letter | Out-Null
    }
}

#endregion

#region --- AutoHeal Main ---

Write-Log "=== AutoHeal-BitLockerDetection starting ==="
$sysDrive = $env:SystemDrive      # C:

try {
    # --- Step 1: Check status before doing anything (for logging context) ---
    $before = Get-SystemDriveBitLockerStatus -Drive $sysDrive
    Write-Log ("Pre-heal  : Drive={0}  Protected={1}  Encrypted={2}%" -f `
        $before.Drive, $before.Protected, $before.PctEncrypted)

    # --- Step 2: Restart BDESVC to flush stale encryption state ---
    Write-Log "Restarting BDESVC..."
    $svcOk = Restart-BDESvc
    if (-not $svcOk) {
        Write-Log "BDESVC restart failed — heal cannot continue." ERROR
        exit 2
    }

    # --- Step 3: Allow service to settle, then force a manage-bde status poll ---
    Write-Log "Waiting ${script:ServiceSettleSeconds}s for BDESVC to settle..."
    Start-Sleep -Seconds $script:ServiceSettleSeconds

    Write-Log "Forcing manage-bde status poll on all fixed drives..."
    Invoke-ManageBdePoll

    # Brief pause for the poll results to propagate before final check
    Start-Sleep -Seconds 2

    # --- Step 4: Verify the heal worked ---
    $after = Get-SystemDriveBitLockerStatus -Drive $sysDrive
    Write-Log ("Post-heal : Drive={0}  Protected={1}  Encrypted={2}%" -f `
        $after.Drive, $after.Protected, $after.PctEncrypted)

    if ($after.Protected) {
        Write-Log "SUCCESS: BitLocker Protection On confirmed for $sysDrive. Monitor should clear on next N-central check."
        exit 0
    }
    else {
        Write-Log ("FAILED: BitLocker still reports Protection Off for $sysDrive after heal. " +
                   "Verify the device is genuinely encrypted — manual investigation required.") WARN
        exit 1
    }
}
catch {
    Write-Log "Unhandled exception in AutoHeal: $_" ERROR
    exit 2
}

#endregion
