<#
.SYNOPSIS
    Checks print spooler health, stuck jobs, and printer states on the endpoint.

.DESCRIPTION
    Collects all print health data silently first, then reasons across the findings
    to surface actionable issues. Outputs a clean header, a FINDINGS block with
    interpreted results, and a compact DETAIL block for raw reference.
    Designed to fit in one ticket note or terminal screenshot.

.PARAMETER Fix
    Clears all pending print jobs and restarts the Print Spooler service.
    Without this switch the script is read-only.

.EXAMPLE
    .\Get-PrintHealth.ps1

.EXAMPLE
    .\Get-PrintHealth.ps1 -Fix

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

# Spooler service
$spoolerStatus   = '(unknown)'
$spoolerRunning  = $false
try {
    $spooler       = Get-Service -Name Spooler -ErrorAction Stop
    $spoolerStatus = $spooler.Status.ToString()
    $spoolerRunning = ($spooler.Status -eq 'Running')
} catch { $spoolerStatus = '(error)' }

# Printers and jobs
$printerError = $false
$printerRows  = @()
$totalJobs    = 0
$stuckCount   = 0
$offlineCount = 0

try {
    $printers = Get-Printer -ErrorAction Stop
    $printerRows = foreach ($p in $printers) {
        $jobs = @()
        try { $jobs = @(Get-PrintJob -PrinterName $p.Name -ErrorAction SilentlyContinue) } catch {}
        $jobCount  = $jobs.Count
        $totalJobs += $jobCount

        # PrinterStatus: 0=Idle, 3=Printing, 4=Warming Up, 5=StopPrinting, 7=Offline, 8=Error...
        $isOffline = ($p.PrinterStatus -in @(7, 8, 9, 10, 11)) -or ($p.Name -match 'offline' -and $jobCount -gt 0)
        if ($isOffline) { $offlineCount++ }
        if ($jobCount -gt 0) { $stuckCount++ }

        [PSCustomObject]@{
            Name      = $p.Name
            Status    = $p.PrinterStatus.ToString()
            Jobs      = $jobCount
            IsOffline = $isOffline
            IsDefault = $p.Default
            Driver    = $p.DriverName
        }
    }
} catch {
    $printerError = $true
}

# -Fix action: clear jobs and restart spooler
$fixLog = [System.Collections.Generic.List[string]]::new()
if ($Fix) {
    try {
        Stop-Service -Name Spooler -Force -ErrorAction Stop
        $spoolPath = "$env:SystemRoot\System32\spool\PRINTERS"
        if (Test-Path $spoolPath) {
            Get-ChildItem -Path $spoolPath -File -ErrorAction SilentlyContinue |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
        Start-Service -Name Spooler -ErrorAction Stop
        $fixLog.Add('Spooler stopped, print job files cleared, spooler restarted.')

        # Refresh counts after fix
        Start-Sleep -Milliseconds 500
        $totalJobs  = 0
        $stuckCount = 0
        foreach ($row in $printerRows) {
            try {
                $jobs      = @(Get-PrintJob -PrinterName $row.Name -ErrorAction SilentlyContinue)
                $row.Jobs  = $jobs.Count
                $totalJobs += $jobs.Count
                if ($jobs.Count -gt 0) { $stuckCount++ }
            } catch {}
        }
        $spoolerStatus  = 'Running'
        $spoolerRunning = $true
    } catch {
        $fixLog.Add("Fix failed: $($_.Exception.Message)")
    }
}

# ─────────────────────────────────────────────────────────────
#  REASON
# ─────────────────────────────────────────────────────────────

if (-not $spoolerRunning) {
    Add-Finding 'CRIT' 'Print Spooler service is not running' `
        "Start via: net start spooler  (or services.msc → Print Spooler → Start)."
}

if ($printerError) {
    Add-Finding 'WARN' 'Could not query printers' `
        "Get-Printer failed — check that Print Spooler is running and this session has permission."
} else {
    if ($stuckCount -gt 0 -and -not $Fix) {
        $jobWord = if ($totalJobs -eq 1) { 'job' } else { 'jobs' }
        Add-Finding 'WARN' "$totalJobs stuck print $jobWord across $stuckCount printer(s)" `
            "Run with -Fix to stop spooler, wipe job files, and restart. Or clear manually via Devices."
    }

    if ($offlineCount -gt 0) {
        Add-Finding 'WARN' "$offlineCount printer(s) reporting offline or error state" `
            "Check cable/network connection, then right-click printer → See what's printing → Printer → Use Printer Online."
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
Write-Host '  ┌─ PRINT HEALTH ─────────────────────────────────────────┐' -ForegroundColor Cyan
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
        Write-Host "  [>>] $line" -ForegroundColor Green
    }
    Write-Host ''
}

# FINDINGS
Write-Divider 'FINDINGS'

if ($findings.Count -eq 0) {
    $okMsg = if ($Fix) { '[OK] Spooler healthy and all print queues clear after fix.' } `
             else      { '[OK] Print spooler is running and no stuck jobs detected.' }
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

$spoolerColor = if ($spoolerRunning) { 'White' } else { 'Red' }
Write-KV 'Spooler' $spoolerStatus $spoolerColor
Write-KV 'Total jobs' "$totalJobs" $(if ($totalJobs -gt 0) { 'Yellow' } else { 'White' })
Write-KV 'Printers' "$(@($printerRows).Count)"
Write-Host ''

if ($printerRows.Count -gt 0) {
    foreach ($row in $printerRows) {
        $label = $row.Name
        if ($row.IsDefault) { $label += ' [default]' }
        $driver = if ($row.Driver) { $row.Driver } else { '(unknown)' }
        $detail = "$($row.Jobs) job(s)  |  $driver"
        $color  = if ($row.IsOffline) { 'Red' } elseif ($row.Jobs -gt 0) { 'Yellow' } else { 'White' }
        Write-KV $label $detail $color
    }
} else {
    Write-Host '  No printers found.' -ForegroundColor DarkGray
}

Write-Host ''
$elapsed = [Math]::Round(((Get-Date) - $scriptStart).TotalSeconds, 1)
$modeStr = if ($Fix) { 'Fix mode' } else { 'Read-only' }
Write-Host "  Done in ${elapsed}s  |  $currentUser  |  $modeStr" -ForegroundColor DarkGray
Write-Host ''
