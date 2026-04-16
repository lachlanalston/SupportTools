<#
.SYNOPSIS
    Checks Outlook process state, DNS resolution for Office 365, and internet connectivity.

.DESCRIPTION
    Collects all Outlook health data silently first, then reasons across the findings
    to surface actionable issues. Outputs a clean header, a FINDINGS block with
    interpreted results, and a compact DETAIL block for raw reference.
    Designed to fit in one ticket note or terminal screenshot.

.EXAMPLE
    .\Get-OutlookHealth.ps1

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

# Outlook process
$outlookRunning = $false
$outlookPid     = $null
$outlookVersion = '(unknown)'
try {
    $proc = Get-Process -Name 'OUTLOOK' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc) {
        $outlookRunning = $true
        $outlookPid     = $proc.Id
        $outlookVersion = $proc.FileVersion
    }
} catch { }

# Outlook install path
$outlookInstalled = $false
$outlookPath      = '(not installed)'
try {
    $reg = Get-ItemProperty `
        -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\OUTLOOK.EXE' `
        -ErrorAction SilentlyContinue
    if ($reg -and $reg.'(Default)') {
        $outlookInstalled = $true
        $outlookPath      = $reg.'(Default)'
    }
} catch { }

# DNS resolution for outlook.office365.com
$dnsOk     = $false
$dnsResult = '(unknown)'
try {
    $dns    = Resolve-DnsName -Name 'outlook.office365.com' -ErrorAction Stop | Select-Object -First 1
    $dnsOk  = $true
    $dnsResult = if ($dns.IPAddress) { $dns.IPAddress } else { 'Resolved (CNAME)' }
} catch {
    $dnsResult = $_.Exception.Message
}

# Internet connectivity (ping Microsoft)
$internetOk = $false
try {
    $internetOk = Test-Connection -ComputerName 'www.microsoft.com' -Count 1 -Quiet -ErrorAction Stop
} catch { }

# ─────────────────────────────────────────────────────────────
#  REASON
# ─────────────────────────────────────────────────────────────

if (-not $outlookInstalled) {
    Add-Finding 'CRIT' 'Outlook does not appear to be installed' `
        "Check Apps → Installed apps for Microsoft 365. Reinstall via M365 Admin Center if missing."
} elseif (-not $outlookRunning) {
    Add-Finding 'WARN' 'Outlook is not currently running' `
        "Ask the user to open Outlook, or launch it via the Start menu. This may be expected if user is away."
}

if (-not $internetOk) {
    Add-Finding 'CRIT' 'No internet connectivity detected' `
        "Ping to www.microsoft.com failed — check network adapter, cable/Wi-Fi, and default gateway."
} elseif (-not $dnsOk) {
    Add-Finding 'WARN' 'DNS resolution failed for outlook.office365.com' `
        "Check DNS server settings — try flushing DNS: ipconfig /flushdns then retry. May indicate split-DNS issue."
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
Write-Host '  ┌─ OUTLOOK HEALTH ───────────────────────────────────────┐' -ForegroundColor Cyan
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
    Write-Host '  [OK] Outlook is running and Office 365 connectivity looks healthy.' -ForegroundColor Green
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

$procStr   = if ($outlookRunning) { "Running (PID $outlookPid  v$outlookVersion)" } else { 'Not running' }
$procColor = if ($outlookRunning) { 'White' } elseif ($outlookInstalled) { 'Yellow' } else { 'Red' }
$dnsColor  = if ($dnsOk) { 'White' } else { 'Red' }
$netColor  = if ($internetOk) { 'White' } else { 'Red' }

Write-KV 'Install path'  $outlookPath
Write-KV 'Process'       $procStr $procColor
Write-KV 'DNS O365'      $(if ($dnsOk) { "OK  ($dnsResult)" } else { "FAILED  $dnsResult" }) $dnsColor
Write-KV 'Internet'      $(if ($internetOk) { 'OK' } else { 'FAILED' }) $netColor

Write-Host ''
$elapsed = [Math]::Round(((Get-Date) - $scriptStart).TotalSeconds, 1)
Write-Host "  Done in ${elapsed}s  |  $currentUser" -ForegroundColor DarkGray
Write-Host ''
