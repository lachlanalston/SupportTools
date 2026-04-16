<#
.SYNOPSIS
    Checks Windows Time service health, NTP configuration, and time offset.

.DESCRIPTION
    Collects all time synchronisation data silently first, then reasons across the findings
    to surface actionable issues. Outputs a clean header, a FINDINGS block with
    interpreted results, and a compact DETAIL block for raw reference.
    Designed to fit in one ticket note or terminal screenshot.

.PARAMETER Fix
    Stops the Windows Time service, re-registers it, picks the fastest reachable NTP server
    from an AU + global pool, reconfigures w32time, and forces a resync.
    Without this switch the script is read-only.

.EXAMPLE
    .\Get-TimeSyncHealth.ps1

.EXAMPLE
    .\Get-TimeSyncHealth.ps1 -Fix

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

# Windows Time service
$w32timeStatus  = '(unknown)'
$w32timeRunning = $false
try {
    $svc            = Get-Service -Name w32time -ErrorAction Stop
    $w32timeStatus  = $svc.Status.ToString()
    $w32timeRunning = ($svc.Status -eq 'Running')
} catch { $w32timeStatus = '(not found)' }

# w32tm status (Last Sync Time, Source, Stratum)
$lastSyncTime  = '(unknown)'
$ntpSource     = '(unknown)'
$stratum       = '(unknown)'
$syncError     = $false

try {
    $statusLines = (& w32tm /query /status 2>&1) -join "`n"
    if ($statusLines -match 'Last Successful Sync Time:\s*(.+)') {
        $lastSyncTime = $matches[1].Trim()
    }
    if ($statusLines -match 'Source:\s*(.+)') {
        $ntpSource = ($matches[1] -replace ',0x\w+', '').Trim()
    }
    if ($statusLines -match 'Stratum:\s*(\d+)') {
        $stratum = $matches[1]
    }
} catch { $syncError = $true }

# Time offset via stripchart (best-effort)
$offsetSeconds = $null
$offsetServer  = if ($ntpSource -ne '(unknown)' -and $ntpSource -notmatch 'Local') { $ntpSource } else { 'time.windows.com' }

try {
    if ($w32timeRunning) {
        $chart      = (& w32tm /stripchart /computer:$offsetServer /samples:1 /dataonly 2>&1)
        $lastLine   = ($chart | Where-Object { $_ -match '^\d' } | Select-Object -Last 1)
        if ($lastLine -and $lastLine -match ',\s*([+-]?\d+\.\d+)s') {
            $offsetSeconds = [double]$matches[1]
        }
    }
} catch { }

# -Fix action
$fixLog    = [System.Collections.Generic.List[string]]::new()
$fixServer = ''

if ($Fix) {
    $ntpCandidates = @(
        '0.au.pool.ntp.org', '1.au.pool.ntp.org', '2.au.pool.ntp.org',
        'time.cloudflare.com', 'time.google.com', 'time.windows.com'
    )

    # Find fastest reachable server
    $latencies = foreach ($srv in $ntpCandidates) {
        try {
            $ping = Test-Connection -ComputerName $srv -Count 1 -ErrorAction SilentlyContinue
            if ($ping) { [PSCustomObject]@{ Server = $srv; RTT = $ping.ResponseTime } }
        } catch { }
    }
    $fixServer = ($latencies | Sort-Object RTT | Select-Object -First 1).Server

    if (-not $fixServer) {
        $fixLog.Add('No NTP servers reachable — fix aborted. Check network connectivity.')
    } else {
        $fixLog.Add("Selected NTP server: $fixServer")
        try {
            Stop-Service w32time -Force -ErrorAction SilentlyContinue
            & w32tm /unregister 2>&1 | Out-Null
            & w32tm /register 2>&1 | Out-Null
            Start-Service w32time -ErrorAction Stop
            & w32tm /config /manualpeerlist:"$fixServer,0x1" /syncfromflags:manual /reliable:yes /update 2>&1 | Out-Null
            & w32tm /resync /nowait 2>&1 | Out-Null
            Start-Sleep -Seconds 3
            $fixLog.Add('w32time re-registered, configured, and resynced.')

            # Re-read offset post-fix
            $chartAfter   = (& w32tm /stripchart /computer:$fixServer /samples:1 /dataonly 2>&1)
            $lastLineAfter = ($chartAfter | Where-Object { $_ -match '^\d' } | Select-Object -Last 1)
            if ($lastLineAfter -and $lastLineAfter -match ',\s*([+-]?\d+\.\d+)s') {
                $offsetSeconds = [double]$matches[1]
                $fixLog.Add("Post-fix offset: $offsetSeconds s")
            }
            $w32timeStatus  = 'Running'
            $w32timeRunning = $true
            $ntpSource      = $fixServer
        } catch {
            $fixLog.Add("Fix error: $($_.Exception.Message)")
        }
    }
}

# ─────────────────────────────────────────────────────────────
#  REASON
# ─────────────────────────────────────────────────────────────

if (-not $w32timeRunning -and $w32timeStatus -ne 'Running') {
    Add-Finding 'CRIT' 'Windows Time service is not running' `
        "Start it via: net start w32time  — or run with -Fix to re-register and start automatically."
}

if ($null -ne $offsetSeconds -and [Math]::Abs($offsetSeconds) -gt 5) {
    Add-Finding 'WARN' "Time offset is $offsetSeconds s — exceeds 5 s threshold" `
        "Run with -Fix to resync time. Large offsets can break Kerberos auth and certificate validation."
}

if ($w32timeRunning -and $ntpSource -match 'Local|Free-running') {
    Add-Finding 'WARN' 'Windows Time is not syncing from an external NTP source' `
        "Run with -Fix to configure a reliable NTP server. Source currently: $ntpSource"
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
Write-Host '  ┌─ TIME SYNC HEALTH ─────────────────────────────────────┐' -ForegroundColor Cyan
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
        $color = if ($line -like '*error*' -or $line -like '*aborted*') { 'Red' } else { 'Green' }
        Write-Host "  [>>] $line" -ForegroundColor $color
    }
    Write-Host ''
}

# FINDINGS
Write-Divider 'FINDINGS'

if ($findings.Count -eq 0) {
    Write-Host '  [OK] Windows Time service is healthy and syncing normally.' -ForegroundColor Green
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

$svcColor    = if ($w32timeRunning) { 'White' } else { 'Red' }
$offsetStr   = if ($null -ne $offsetSeconds) { "$offsetSeconds s" } else { '(unavailable)' }
$offsetColor = if ($null -ne $offsetSeconds -and [Math]::Abs($offsetSeconds) -gt 5) { 'Yellow' } else { 'White' }

Write-KV 'w32time'      $w32timeStatus $svcColor
Write-KV 'NTP source'   $ntpSource
Write-KV 'Stratum'      $stratum
Write-KV 'Last sync'    $lastSyncTime
Write-KV 'Offset'       $offsetStr $offsetColor

Write-Host ''
$elapsed = [Math]::Round(((Get-Date) - $scriptStart).TotalSeconds, 1)
$modeStr = if ($Fix) { 'Fix mode' } else { 'Read-only' }
Write-Host "  Done in ${elapsed}s  |  $currentUser  |  $modeStr" -ForegroundColor DarkGray
Write-Host ''
