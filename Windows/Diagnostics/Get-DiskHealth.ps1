<#
.SYNOPSIS
    Checks disk space, temp folder bloat, and recycle bin size across all fixed drives.

.DESCRIPTION
    Collects all disk health data silently first, then reasons across the findings
    to surface actionable issues. Outputs a clean header, a FINDINGS block with
    interpreted results, and a compact DETAIL block for raw reference.
    Designed to fit in one ticket note or terminal screenshot.

.PARAMETER Fix
    Clears Windows Temp, all per-user Temp folders, and empties the Recycle Bin.
    Without this switch the script is read-only.

.EXAMPLE
    .\Get-DiskHealth.ps1

.EXAMPLE
    .\Get-DiskHealth.ps1 -Fix

.NOTES
    Author:  Lachlan Alston
    Version: v1
    Updated: 2026-04-17
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

function Get-FolderSizeMB { param([string]$Path)
    if (-not (Test-Path $Path)) { return 0 }
    try {
        $sum = (Get-ChildItem $Path -Recurse -Force -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
        return [Math]::Round(($sum ?? 0) / 1MB, 1)
    } catch { return 0 }
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

# Fixed drives
$driveRows = @()
try {
    $disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop |
             Where-Object { $_.Size -gt 0 }
    $driveRows = foreach ($d in $disks) {
        $pctFree = [Math]::Round(($d.FreeSpace / $d.Size) * 100, 0)
        $gbFree  = [Math]::Round($d.FreeSpace / 1GB, 1)
        $gbTotal = [Math]::Round($d.Size / 1GB, 1)
        [PSCustomObject]@{ Drive = $d.DeviceID; PctFree = $pctFree; GbFree = $gbFree; GbTotal = $gbTotal }
    }
} catch { }

# Temp folder sizes
$winTempMB    = Get-FolderSizeMB 'C:\Windows\Temp'
$userTempMB   = 0
$userTempCount = 0
try {
    Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $tp = "$($_.FullName)\AppData\Local\Temp"
        if (Test-Path $tp) {
            $userTempCount++
            $userTempMB += Get-FolderSizeMB $tp
        }
    }
} catch { }
$totalTempMB = $winTempMB + $userTempMB

# Recycle Bin
$recycleMB = Get-FolderSizeMB 'C:\$Recycle.Bin'

# -Fix action
$fixLog = [System.Collections.Generic.List[string]]::new()

if ($Fix) {
    # Clear Windows Temp
    try {
        Get-ChildItem 'C:\Windows\Temp' -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        $fixLog.Add('Cleared C:\Windows\Temp')
    } catch { $fixLog.Add("Windows\Temp error: $($_.Exception.Message)") }

    # Clear per-user Temp folders
    try {
        Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $tp = "$($_.FullName)\AppData\Local\Temp"
            if (Test-Path $tp) {
                Get-ChildItem $tp -Force -ErrorAction SilentlyContinue |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        $fixLog.Add('Cleared per-user Temp folders')
    } catch { $fixLog.Add("User Temp error: $($_.Exception.Message)") }

    # Empty Recycle Bin
    try {
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
        $fixLog.Add('Emptied Recycle Bin')
    } catch { $fixLog.Add("Recycle Bin error: $($_.Exception.Message)") }

    # Re-measure post-fix
    $winTempMB  = Get-FolderSizeMB 'C:\Windows\Temp'
    $userTempMB = 0
    try {
        Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $tp = "$($_.FullName)\AppData\Local\Temp"
            if (Test-Path $tp) { $userTempMB += Get-FolderSizeMB $tp }
        }
    } catch { }
    $totalTempMB = $winTempMB + $userTempMB
    $recycleMB   = Get-FolderSizeMB 'C:\$Recycle.Bin'

    try {
        $disks2 = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop |
                  Where-Object { $_.Size -gt 0 }
        $driveRows = foreach ($d in $disks2) {
            $pctFree = [Math]::Round(($d.FreeSpace / $d.Size) * 100, 0)
            $gbFree  = [Math]::Round($d.FreeSpace / 1GB, 1)
            $gbTotal = [Math]::Round($d.Size / 1GB, 1)
            [PSCustomObject]@{ Drive = $d.DeviceID; PctFree = $pctFree; GbFree = $gbFree; GbTotal = $gbTotal }
        }
    } catch { }
}

# ─────────────────────────────────────────────────────────────
#  REASON
# ─────────────────────────────────────────────────────────────

foreach ($d in @($driveRows | Where-Object { $_.PctFree -le 5 })) {
    Add-Finding 'CRIT' "$($d.Drive) critically low — $($d.PctFree)% free ($($d.GbFree) GB remaining)" `
        "Free space on $($d.Drive) immediately — delete large files, extend the partition, or migrate data."
}
foreach ($d in @($driveRows | Where-Object { $_.PctFree -gt 5 -and $_.PctFree -le 15 })) {
    Add-Finding 'WARN' "$($d.Drive) is low — $($d.PctFree)% free ($($d.GbFree) GB remaining)" `
        "Run with -Fix to clear temp files, or manually remove large files to free space."
}

if ($totalTempMB -gt 1024) {
    $totalTempGB = [Math]::Round($totalTempMB / 1024, 1)
    Add-Finding 'WARN' "Temp folders are using $totalTempGB GB" `
        "Run with -Fix to safely clear Windows\Temp and per-user Temp folders."
}

if ($recycleMB -gt 500) {
    Add-Finding 'WARN' "Recycle Bin contains $([Math]::Round($recycleMB, 0)) MB" `
        "Run with -Fix to empty the Recycle Bin, or right-click it on the desktop → Empty Recycle Bin."
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
Write-Host '  ┌─ DISK HEALTH ──────────────────────────────────────────┐' -ForegroundColor Cyan
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
        $color = if ($line -like '*error*') { 'Red' } else { 'Green' }
        Write-Host "  [>>] $line" -ForegroundColor $color
    }
    Write-Host ''
}

# FINDINGS
Write-Divider 'FINDINGS'

if ($findings.Count -eq 0) {
    Write-Host '  [OK] All drives have healthy free space and temp usage is normal.' -ForegroundColor Green
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

# Drives table
if ($driveRows.Count -gt 0) {
    Write-Host ("  {0,-6} {1,10} {2,10} {3,8}" -f 'Drive', 'Total GB', 'Free GB', '% Free') `
        -ForegroundColor DarkGray
    Write-Host ("  {0}" -f ('─' * 38)) -ForegroundColor DarkGray
    foreach ($d in $driveRows) {
        $color = if ($d.PctFree -le 5) { 'Red' } elseif ($d.PctFree -le 15) { 'Yellow' } else { 'White' }
        Write-Host ("  {0,-6} {1,10} {2,10} {3,8}" -f $d.Drive, $d.GbTotal, $d.GbFree, "$($d.PctFree)%") `
            -ForegroundColor $color
    }
} else {
    Write-Host '  No fixed drives found.' -ForegroundColor DarkGray
}

Write-Host ''

$winTempColor  = if ($winTempMB -gt 512) { 'Yellow' } else { 'White' }
$userTempColor = if ($userTempMB -gt 512) { 'Yellow' } else { 'White' }
$recColor      = if ($recycleMB -gt 500) { 'Yellow' } else { 'White' }

Write-KV 'Windows\Temp'  "$winTempMB MB"  $winTempColor
Write-KV 'User Temps'    "$userTempMB MB  ($userTempCount profile(s))" $userTempColor
Write-KV 'Recycle Bin'   "$([Math]::Round($recycleMB, 0)) MB" $recColor

Write-Host ''
$elapsed = [Math]::Round(((Get-Date) - $scriptStart).TotalSeconds, 1)
$modeStr = if ($Fix) { 'Fix mode' } else { 'Read-only' }
Write-Host "  Done in ${elapsed}s  |  $currentUser  |  $modeStr" -ForegroundColor DarkGray
Write-Host ''
