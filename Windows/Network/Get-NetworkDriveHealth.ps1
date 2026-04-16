<#
.SYNOPSIS
    Reports mapped network drives and their connectivity state on the endpoint.

.DESCRIPTION
    Collects all network drive data silently first, then reasons across the findings
    to surface actionable issues. Outputs a clean header, a FINDINGS block with
    interpreted results, and a compact DETAIL block for raw reference.
    Designed to fit in one ticket note or terminal screenshot.

.PARAMETER Fix
    Removes all mapped network drives using net use /delete.
    Without this switch the script is read-only.

.EXAMPLE
    .\Get-NetworkDriveHealth.ps1

.EXAMPLE
    .\Get-NetworkDriveHealth.ps1 -Fix

.NOTES
    Author:  Lachlan Alston
    Version: v1
    Updated: 2026-04-16
#>

[CmdletBinding()]
param(
    [switch]$Fix
)

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

# Logged-in user — SYSTEM-safe
try {
    $rawUser     = (Get-CimInstance Win32_ComputerSystem).UserName
    $currentUser = if ($rawUser) { $rawUser.Split('\')[-1] } else { '(unknown)' }
} catch { $currentUser = '(unknown)' }

# Detect execution context (SYSTEM vs user)
$runningAsSystem = $false
try {
    $identity       = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $runningAsSystem = $identity.IsSystem
} catch {}

# Box header data
try {
    $cs     = Get-CimInstance Win32_ComputerSystem
    $model  = $cs.Model
    $domain = $cs.Domain
} catch { $model = '(unknown)'; $domain = '(unknown)' }

try { $serial = (Get-CimInstance Win32_BIOS).SerialNumber } catch { $serial = '(unknown)' }

try {
    $osObj     = Get-CimInstance Win32_OperatingSystem
    $osCaption = $osObj.Caption -replace 'Microsoft Windows', 'Windows' `
                                -replace 'Professional', 'Pro'
    $osBuild   = $osObj.BuildNumber
    $upDelta   = (Get-Date) - $osObj.LastBootUpTime
    $uptime    = if ($upDelta.Days -gt 0) { "$($upDelta.Days)d $($upDelta.Hours)h" } `
                 else { "$($upDelta.Hours)h $($upDelta.Minutes)m" }
} catch { $osCaption = '(unknown)'; $osBuild = '?'; $uptime = '(unknown)' }

try {
    $localIP = (Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" |
        Where-Object { $_.IPAddress -match '^\d+\.\d+\.\d+\.\d+$' } |
        Select-Object -First 1).IPAddress |
        Where-Object { $_ -match '^\d' } |
        Select-Object -First 1
    if (-not $localIP) { $localIP = '(unknown)' }
} catch { $localIP = '(unknown)' }

# Mapped network drives
$driveRows        = @()
$disconnectedCount = 0

try {
    $mapped = Get-PSDrive -PSProvider FileSystem -ErrorAction Stop |
              Where-Object { $_.DisplayRoot -like '\\*' }

    $driveRows = foreach ($d in $mapped) {
        $letter   = "$($d.Name):"
        $unc      = $d.DisplayRoot
        $reachable = Test-Path -Path $unc -ErrorAction SilentlyContinue
        if (-not $reachable) { $disconnectedCount++ }
        [PSCustomObject]@{
            Letter    = $letter
            UNC       = $unc
            Reachable = $reachable
        }
    }
} catch {}

# -Fix action: remove all mapped drives
$fixLog = [System.Collections.Generic.List[string]]::new()
if ($Fix) {
    if ($driveRows.Count -eq 0) {
        $fixLog.Add('No network drives found to remove.')
    } else {
        foreach ($row in $driveRows) {
            try {
                $out = & net use $row.Letter /delete /yes 2>&1
                $fixLog.Add("Removed $($row.Letter) → $($row.UNC)")
            } catch {
                $fixLog.Add("Failed to remove $($row.Letter): $($_.Exception.Message)")
            }
        }
        # Refresh after fix
        $driveRows         = @()
        $disconnectedCount = 0
    }
}

# ─────────────────────────────────────────────────────────────
#  REASON
# ─────────────────────────────────────────────────────────────

if ($runningAsSystem -and $driveRows.Count -eq 0 -and -not $Fix) {
    Add-Finding 'INFO' 'Running as SYSTEM — user-mapped drives not visible' `
        "Re-run in user context or via ImmyBot user-context task to see drives mapped to the logged-in user."
}

if ($disconnectedCount -gt 0 -and -not $Fix) {
    Add-Finding 'WARN' "$disconnectedCount disconnected network drive(s)" `
        "Run with -Fix to remove all mapped drives, or open File Explorer → This PC → right-click → Disconnect."
}

$findings = $findings | Sort-Object { switch ($_.Severity) { 'CRIT' { 0 } 'WARN' { 1 } default { 2 } } }

# ─────────────────────────────────────────────────────────────
#  OUTPUT
# ─────────────────────────────────────────────────────────────

$termWidth = $Host.UI.RawUI.WindowSize.Width
if ($termWidth -gt 0 -and $termWidth -lt 90) {
    Write-Host "  [WARN] Terminal is $termWidth cols wide — output may wrap. Recommended: 90+ cols." `
        -ForegroundColor Yellow
}

$runAt = Get-Date -Format 'yyyy-MM-dd HH:mm'

Write-Host ''
Write-Host '  ┌─ NETWORK DRIVE HEALTH ─────────────────────────────────┐' -ForegroundColor Cyan
Write-Host ("  │  {0,-58}│" -f "Host    $($env:COMPUTERNAME)")            -ForegroundColor Cyan
Write-Host ("  │  {0,-58}│" -f "User    $currentUser")                    -ForegroundColor Cyan
Write-Host ("  │  {0,-58}│" -f "Model   $model")                          -ForegroundColor Cyan
Write-Host ("  │  {0,-58}│" -f "S/N     $serial")                         -ForegroundColor Cyan
Write-Host ("  │  {0,-58}│" -f "OS      $osCaption  Build $osBuild")      -ForegroundColor Cyan
Write-Host ("  │  {0,-58}│" -f "Domain  $domain")                         -ForegroundColor Cyan
Write-Host ("  │  {0,-58}│" -f "IP      $localIP")                        -ForegroundColor Cyan
Write-Host ("  │  {0,-58}│" -f "Uptime  $uptime")                         -ForegroundColor Cyan
Write-Host ("  │  {0,-58}│" -f "Run     $runAt")                          -ForegroundColor Cyan
Write-Host '  └────────────────────────────────────────────────────────┘' -ForegroundColor Cyan
Write-Host ''

if ($Fix -and $fixLog.Count -gt 0) {
    Write-Divider 'FIX ACTIONS'
    foreach ($line in $fixLog) {
        $color = if ($line -like 'Failed*') { 'Red' } else { 'Green' }
        Write-Host "  [>>] $line" -ForegroundColor $color
    }
    Write-Host ''
}

# FINDINGS
Write-Divider 'FINDINGS'

if ($findings.Count -eq 0) {
    $okMsg = if ($Fix -and $fixLog.Count -gt 0 -and $fixLog[0] -notlike 'No network*') {
        '[OK] All network drives removed successfully.'
    } elseif ($driveRows.Count -eq 0) {
        '[OK] No mapped network drives found.'
    } else {
        '[OK] All mapped network drives are reachable.'
    }
    Write-Host "  $okMsg" -ForegroundColor Green
} else {
    foreach ($f in $findings) {
        $icon  = if ($f.Severity -eq 'INFO') { '[--]' } else { '[!!]' }
        $color = switch ($f.Severity) { 'CRIT' { 'Red' } 'WARN' { 'Yellow' } default { 'Cyan' } }
        Write-Host "  $icon $($f.Title)" -ForegroundColor $color
        Write-Host "       $($f.Detail)" -ForegroundColor DarkGray
    }
}

$issueCount = ($findings | Where-Object { $_.Severity -in 'CRIT', 'WARN' }).Count
Write-Divider "$issueCount issue(s) found"
Write-Host ''

# DETAIL
Write-Divider 'DETAIL'

$contextLabel = if ($runningAsSystem) { 'SYSTEM' } else { 'User' }
Write-KV 'Context'      $contextLabel $(if ($runningAsSystem) { 'Yellow' } else { 'White' })
Write-KV 'Drives found' "$(@($driveRows).Count)"
Write-KV 'Disconnected' "$disconnectedCount" $(if ($disconnectedCount -gt 0) { 'Yellow' } else { 'White' })
Write-Host ''

if ($driveRows.Count -gt 0) {
    foreach ($row in $driveRows) {
        $state = if ($row.Reachable) { 'OK       ' } else { 'OFFLINE  ' }
        $color = if ($row.Reachable) { 'White' } else { 'Yellow' }
        $unc   = if ($row.UNC.Length -gt 50) { $row.UNC.Substring(0, 47) + '...' } else { $row.UNC }
        Write-Host ("  {0}  {1}  {2}" -f $row.Letter, $state, $unc) -ForegroundColor $color
    }
} elseif (-not $Fix) {
    Write-Host '  No mapped network drives.' -ForegroundColor DarkGray
}

Write-Host ''
$elapsed = [Math]::Round(((Get-Date) - $scriptStart).TotalSeconds, 1)
$modeStr = if ($Fix) { 'Fix mode' } else { 'Read-only' }
Write-Host "  Done in ${elapsed}s  |  $currentUser  |  $modeStr" -ForegroundColor DarkGray
Write-Host ''
