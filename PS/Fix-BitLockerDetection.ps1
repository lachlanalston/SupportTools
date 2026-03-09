<#
.SYNOPSIS
    Fixes BitLocker detection reporting in N-central after ImmyBot maintenance.
.DESCRIPTION
    After ImmyBot maintenance windows, the N-central agent can incorrectly report
    BitLocker as not enabled until a user logs in or a manual encryption check is run.
    This script forces a BitLocker status refresh by restarting the BitLocker service,
    triggering a manage-bde status poll, and restarting the N-central agent so it
    re-reads the correct encryption state from WMI/manage-bde.
.NOTES
    Run as SYSTEM / with local administrator rights.
    Tested against N-able N-central agent.
    Safe to run remotely via N-central script deployment.
#>

#region --- Helpers ---

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Output "[$ts][$Level] $Message"
}

function Get-BitLockerStatusRaw {
    <#
    .SYNOPSIS
        Returns BitLocker protection status for each fixed drive using manage-bde.
        Falls back to Get-BitLockerVolume (requires RSAT/BitLocker module) if available.
    #>
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    # Primary: manage-bde (always present on supported Windows)
    try {
        $drives = (Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -match '^[A-Z]:\\$' }).Root
        foreach ($drive in $drives) {
            $letter = $drive.TrimEnd('\')
            $raw = manage-bde.exe -status $letter 2>&1
            if ($LASTEXITCODE -ne 0) { continue }

            $statusLine  = ($raw | Where-Object { $_ -match 'Protection Status' } | Select-Object -First 1)
            $pctLine     = ($raw | Where-Object { $_ -match 'Percentage Encrypted' } | Select-Object -First 1)

            $protected   = $statusLine  -match 'Protection On'
            $pct         = if ($pctLine -match '(\d+(\.\d+)?)%') { [double]$Matches[1] } else { $null }

            $results.Add([PSCustomObject]@{
                Drive      = $letter
                Protected  = $protected
                PctEncrypted = $pct
                Source     = 'manage-bde'
            })
        }
    }
    catch {
        Write-Log "manage-bde query failed: $_" WARN
    }

    # Secondary: Get-BitLockerVolume (may not be available on all SKUs)
    if (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue) {
        try {
            Get-BitLockerVolume | ForEach-Object {
                $results.Add([PSCustomObject]@{
                    Drive        = $_.MountPoint
                    Protected    = ($_.ProtectionStatus -eq 'On')
                    PctEncrypted = $_.EncryptionPercentage
                    Source       = 'Get-BitLockerVolume'
                })
            }
        }
        catch {
            Write-Log "Get-BitLockerVolume query failed: $_" WARN
        }
    }

    return $results
}

function Restart-ServiceSafely {
    param(
        [string]$ServiceName,
        [int]$TimeoutSeconds = 30
    )
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Log "Service '$ServiceName' not found — skipping." WARN
        return $false
    }

    Write-Log "Restarting service: $ServiceName (current state: $($svc.Status))"
    try {
        Restart-Service -Name $ServiceName -Force -ErrorAction Stop
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        do {
            Start-Sleep -Seconds 2
            $svc.Refresh()
        } while ($svc.Status -ne 'Running' -and (Get-Date) -lt $deadline)

        if ($svc.Status -eq 'Running') {
            Write-Log "Service '$ServiceName' is Running."
            return $true
        }
        else {
            Write-Log "Service '$ServiceName' did not reach Running state within ${TimeoutSeconds}s." WARN
            return $false
        }
    }
    catch {
        Write-Log "Failed to restart '$ServiceName': $_" ERROR
        return $false
    }
}

#endregion

#region --- Main ---

Write-Log "=== Fix-BitLockerDetection starting ==="

# 1. Show current (potentially stale) BitLocker status before any changes
Write-Log "--- BitLocker status BEFORE refresh ---"
$statusBefore = Get-BitLockerStatusRaw
if ($statusBefore.Count -eq 0) {
    Write-Log "No fixed drives returned a BitLocker status." WARN
}
else {
    $statusBefore | ForEach-Object {
        Write-Log ("  Drive={0}  Protected={1}  Encrypted={2}%  Source={3}" -f `
            $_.Drive, $_.Protected, $_.PctEncrypted, $_.Source)
    }
}

# 2. Restart the BitLocker Drive Encryption Service (BDESVC)
#    ImmyBot maintenance can leave BDESVC in a stale state, causing WMI/manage-bde
#    to return incorrect protection-off results until the service is cycled.
Write-Log "--- Restarting BitLocker Drive Encryption Service (BDESVC) ---"
$bdesvcRestarted = Restart-ServiceSafely -ServiceName 'BDESVC'

# 3. Force manage-bde status poll on every fixed drive to flush the stale cache
Write-Log "--- Forcing manage-bde status poll on all fixed drives ---"
$drives = (Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -match '^[A-Z]:\\$' }).Root
foreach ($drive in $drives) {
    $letter = $drive.TrimEnd('\')
    Write-Log "  Polling manage-bde -status $letter"
    manage-bde.exe -status $letter | Out-Null
}

# Small pause to let the service settle before re-querying
Start-Sleep -Seconds 3

# 4. Show BitLocker status after the BDESVC restart / manage-bde poll
Write-Log "--- BitLocker status AFTER refresh ---"
$statusAfter = Get-BitLockerStatusRaw
$statusAfter | ForEach-Object {
    Write-Log ("  Drive={0}  Protected={1}  Encrypted={2}%  Source={3}" -f `
        $_.Drive, $_.Protected, $_.PctEncrypted, $_.Source)
}

# 5. Restart the N-central Windows Agent so it re-reads the refreshed BitLocker state.
#    N-central caches device property data; a service restart forces a clean re-poll.
#    Known service names across N-able / N-central agent versions:
$nCentralServiceNames = @(
    'Windows Agent',          # N-central agent (common)
    'Windows Agent Service',  # alternate naming
    'SolarWindsMSP RMMAgent', # legacy SolarWinds MSP branding
    'Advanced Monitoring Agent' # older GFI/LogicNow branding
)

$agentRestarted = $false
foreach ($svcName in $nCentralServiceNames) {
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Log "--- Found N-central agent service: '$svcName' ---"
        $agentRestarted = Restart-ServiceSafely -ServiceName $svcName
        break
    }
}

if (-not $agentRestarted) {
    Write-Log ("N-central agent service not found under known names. " +
               "The agent will pick up the corrected BitLocker state on its next polling cycle.") WARN
}

# 6. Summary / exit code for N-central AM check compatibility
$sysDrive   = $env:SystemDrive          # e.g. C:
$sysStatus  = $statusAfter | Where-Object { $_.Drive -eq $sysDrive } | Select-Object -First 1

if (-not $sysStatus) {
    Write-Log "Could not determine BitLocker status for system drive ($sysDrive)." ERROR
    exit 2
}

if ($sysStatus.Protected) {
    Write-Log "SUCCESS: BitLocker is Protection On for $sysDrive ($($sysStatus.PctEncrypted)% encrypted)."
    Write-Log "N-central should now report the correct status."
    exit 0
}
else {
    Write-Log ("WARNING: BitLocker still reports Protection Off for $sysDrive after refresh. " +
               "Verify that BitLocker is actually enabled on this device.") WARN
    exit 1
}

#endregion
