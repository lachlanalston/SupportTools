<#
.SYNOPSIS
    Checks browser cache sizes for Chrome, Edge, and Firefox across all user profiles.

.DESCRIPTION
    Collects all browser cache data silently first, then reasons across the findings
    to surface actionable issues. Outputs a clean header, a FINDINGS block with
    interpreted results, and a compact DETAIL block for raw reference.
    Designed to fit in one ticket note or terminal screenshot.

.PARAMETER Fix
    Clears cache folders for all detected browsers across all user profiles.
    Browsers must be closed before running with -Fix for a complete clear.
    Without this switch the script is read-only.

.EXAMPLE
    .\Get-BrowserCacheHealth.ps1

.EXAMPLE
    .\Get-BrowserCacheHealth.ps1 -Fix

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

function Clear-FolderContents { param([string]$Path)
    if (-not (Test-Path $Path)) { return }
    Get-ChildItem $Path -Force -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
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

# Browser cache path definitions per user
# Each entry: Name, relative path(s) under C:\Users\<user>\AppData\Local
$browserDefs = @(
    @{
        Name  = 'Chrome'
        Paths = @(
            'Google\Chrome\User Data\Default\Cache',
            'Google\Chrome\User Data\Default\Code Cache'
        )
    },
    @{
        Name  = 'Edge'
        Paths = @(
            'Microsoft\Edge\User Data\Default\Cache',
            'Microsoft\Edge\User Data\Default\Code Cache'
        )
    },
    @{
        Name  = 'Firefox'
        Paths = @(
            'Mozilla\Firefox\Profiles'   # scanned below with profile wildcard
        )
        IsFirefox = $true
    }
)

# Measure cache per browser
$browserRows = foreach ($b in $browserDefs) {
    $totalMB  = 0
    $profiles = 0
    $cachePaths = [System.Collections.Generic.List[string]]::new()

    try {
        $userDirs = Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue

        foreach ($ud in $userDirs) {
            $localApp = "$($ud.FullName)\AppData\Local"

            if ($b.IsFirefox) {
                # Firefox: profiles under AppData\Local\Mozilla\Firefox\Profiles\<name>\cache2
                $ffBase = "$localApp\Mozilla\Firefox\Profiles"
                if (Test-Path $ffBase) {
                    Get-ChildItem $ffBase -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                        $c2 = "$($_.FullName)\cache2"
                        if (Test-Path $c2) {
                            $mb = Get-FolderSizeMB $c2
                            if ($mb -gt 0) { $totalMB += $mb; $profiles++; $cachePaths.Add($c2) }
                        }
                    }
                }
            } else {
                $found = $false
                foreach ($rel in $b.Paths) {
                    $p = "$localApp\$rel"
                    if (Test-Path $p) {
                        $mb = Get-FolderSizeMB $p
                        $totalMB += $mb
                        $cachePaths.Add($p)
                        $found = $true
                    }
                }
                if ($found) { $profiles++ }
            }
        }
    } catch { }

    [PSCustomObject]@{
        Name       = $b.Name
        TotalMB    = [Math]::Round($totalMB, 1)
        Profiles   = $profiles
        CachePaths = $cachePaths
    }
}

# Running browser processes (warn if -Fix is used while browsers are open)
$openBrowsers = @()
try {
    $openBrowsers = @(Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in @('chrome', 'msedge', 'firefox') } |
        Select-Object -ExpandProperty Name -Unique)
} catch { }

# -Fix action
$fixLog = [System.Collections.Generic.List[string]]::new()

if ($Fix) {
    if ($openBrowsers.Count -gt 0) {
        $fixLog.Add("[WARN] Browsers still open: $($openBrowsers -join ', ') — cache may be partially locked.")
    }

    foreach ($b in $browserRows) {
        $cleared = 0
        foreach ($p in $b.CachePaths) {
            try { Clear-FolderContents $p; $cleared++ } catch { }
        }
        if ($cleared -gt 0) {
            $fixLog.Add("Cleared $($b.Name) cache ($cleared folder(s))")
        }
    }

    # Re-measure post-fix
    $browserRows = foreach ($b in $browserDefs) {
        $totalMB  = 0
        $profiles = 0
        $cachePaths = [System.Collections.Generic.List[string]]::new()

        try {
            $userDirs = Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue
            foreach ($ud in $userDirs) {
                $localApp = "$($ud.FullName)\AppData\Local"
                if ($b.IsFirefox) {
                    $ffBase = "$localApp\Mozilla\Firefox\Profiles"
                    if (Test-Path $ffBase) {
                        Get-ChildItem $ffBase -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                            $c2 = "$($_.FullName)\cache2"
                            if (Test-Path $c2) {
                                $mb = Get-FolderSizeMB $c2
                                $totalMB += $mb; $profiles++; $cachePaths.Add($c2)
                            }
                        }
                    }
                } else {
                    $found = $false
                    foreach ($rel in $b.Paths) {
                        $p = "$localApp\$rel"
                        if (Test-Path $p) { $totalMB += Get-FolderSizeMB $p; $cachePaths.Add($p); $found = $true }
                    }
                    if ($found) { $profiles++ }
                }
            }
        } catch { }

        [PSCustomObject]@{
            Name     = $b.Name
            TotalMB  = [Math]::Round($totalMB, 1)
            Profiles = $profiles
            CachePaths = $cachePaths
        }
    }
}

# ─────────────────────────────────────────────────────────────
#  REASON
# ─────────────────────────────────────────────────────────────

foreach ($b in $browserRows | Where-Object { $_.TotalMB -gt 500 }) {
    $gbStr = [Math]::Round($b.TotalMB / 1024, 1)
    $sizeStr = if ($b.TotalMB -ge 1024) { "$gbStr GB" } else { "$($b.TotalMB) MB" }
    Add-Finding 'WARN' "$($b.Name) cache is $sizeStr across $($b.Profiles) profile(s)" `
        "Run with -Fix to clear (close $($b.Name) first), or clear manually via browser Settings → Privacy → Clear browsing data."
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
Write-Host '  ┌─ BROWSER CACHE HEALTH ─────────────────────────────────┐' -ForegroundColor Cyan
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
        $color = if ($line -like '*WARN*' -or $line -like '*locked*') { 'Yellow' } else { 'Green' }
        Write-Host "  [>>] $line" -ForegroundColor $color
    }
    Write-Host ''
}

# FINDINGS
Write-Divider 'FINDINGS'

if ($findings.Count -eq 0) {
    $detected = @($browserRows | Where-Object { $_.Profiles -gt 0 })
    if ($detected.Count -eq 0) {
        Write-Host '  [OK] No browser cache folders detected on this endpoint.' -ForegroundColor Green
    } else {
        Write-Host '  [OK] All browser caches are within normal size limits.' -ForegroundColor Green
    }
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

$totalAllMB = ($browserRows | Measure-Object -Property TotalMB -Sum).Sum
Write-KV 'Total cache' "$([Math]::Round($totalAllMB, 1)) MB" $(if ($totalAllMB -gt 500) { 'Yellow' } else { 'White' })
Write-KV 'Open browsers' $(if ($openBrowsers.Count -gt 0) { $openBrowsers -join ', ' } else { 'None detected' }) `
    $(if ($openBrowsers.Count -gt 0) { 'Yellow' } else { 'White' })
Write-Host ''

foreach ($b in $browserRows) {
    $sizeColor = if ($b.TotalMB -gt 500) { 'Yellow' } else { 'White' }
    $detected  = if ($b.Profiles -gt 0) { "$($b.TotalMB) MB  ($($b.Profiles) profile(s))" } else { 'Not detected' }
    $detColor  = if ($b.Profiles -eq 0) { 'DarkGray' } else { $sizeColor }
    Write-KV $b.Name $detected $detColor
}

if ($Fix) {
    Write-Host ''
    Write-Host '       Tip: Re-run without -Fix to confirm caches are cleared.' -ForegroundColor DarkGray
}

Write-Host ''
$elapsed = [Math]::Round(((Get-Date) - $scriptStart).TotalSeconds, 1)
$modeStr = if ($Fix) { 'Fix mode' } else { 'Read-only' }
Write-Host "  Done in ${elapsed}s  |  $currentUser  |  $modeStr" -ForegroundColor DarkGray
Write-Host ''
