<#
.SYNOPSIS
    Checks installed GPU driver versions and dates across all video controllers.

.DESCRIPTION
    Collects all graphics driver data silently first, then reasons across the findings
    to surface actionable issues. Outputs a clean header, a FINDINGS block with
    interpreted results, and a compact DETAIL block for raw reference.
    Designed to fit in one ticket note or terminal screenshot.

.EXAMPLE
    .\Get-GraphicsDriverHealth.ps1

.NOTES
    Author:  Lachlan Alston
    Version: v1
    Updated: 2026-04-16
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

# GPU driver info
$gpuError = $false
$gpuRows  = @()

try {
    $controllers = Get-CimInstance Win32_VideoController -ErrorAction Stop |
                   Where-Object { $_.Name -notmatch 'Microsoft.*Display|Remote Desktop' }

    $gpuRows = foreach ($gpu in $controllers) {
        $driverDate = $null
        $daysOld    = $null
        $dateStr    = '(unknown)'

        if ($gpu.DriverDate) {
            $driverDate = $gpu.DriverDate
            $daysOld    = [Math]::Round(((Get-Date) - $driverDate).TotalDays, 0)
            $dateStr    = $driverDate.ToString('yyyy-MM-dd')
        }

        [PSCustomObject]@{
            Name          = $gpu.Name
            DriverVersion = $gpu.DriverVersion
            DriverDate    = $dateStr
            DaysOld       = $daysOld
            Status        = $gpu.Status
        }
    }
} catch {
    $gpuError = $true
}

# ─────────────────────────────────────────────────────────────
#  REASON
# ─────────────────────────────────────────────────────────────

if ($gpuError) {
    Add-Finding 'WARN' 'Could not query GPU driver information' `
        "Win32_VideoController query failed — check WMI service is running."
} else {
    $staleGpus = @($gpuRows | Where-Object { $_.DaysOld -ne $null -and $_.DaysOld -gt 365 })
    foreach ($g in $staleGpus) {
        Add-Finding 'WARN' "$($g.Name) driver is $($g.DaysOld) days old" `
            "Update via Device Manager → Display adapters, or via the manufacturer's software (NVIDIA App / AMD Software / Intel DSA)."
    }
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
Write-Host '  ┌─ GRAPHICS DRIVER HEALTH ───────────────────────────────┐' -ForegroundColor Cyan
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

# FINDINGS
Write-Divider 'FINDINGS'

if ($findings.Count -eq 0) {
    Write-Host '  [OK] All GPU drivers are current (within 365 days).' -ForegroundColor Green
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

if ($gpuRows.Count -eq 0) {
    Write-Host '  No video controllers found.' -ForegroundColor DarkGray
} else {
    foreach ($g in $gpuRows) {
        $daysStr  = if ($null -ne $g.DaysOld) { "$($g.DaysOld)d old" } else { '(unknown)' }
        $color    = if ($null -ne $g.DaysOld -and $g.DaysOld -gt 365) { 'Yellow' } else { 'White' }
        $nameShort = if ($g.Name.Length -gt 40) { $g.Name.Substring(0, 37) + '...' } else { $g.Name }
        Write-Host ''
        Write-KV 'GPU'     $nameShort
        Write-KV 'Driver'  $g.DriverVersion
        Write-KV 'Date'    "$($g.DriverDate)  ($daysStr)" $color
        Write-KV 'Status'  $g.Status $(if ($g.Status -ne 'OK') { 'Yellow' } else { 'White' })
    }
}

Write-Host ''
$elapsed = [Math]::Round(((Get-Date) - $scriptStart).TotalSeconds, 1)
Write-Host "  Done in ${elapsed}s  |  $currentUser" -ForegroundColor DarkGray
Write-Host ''
