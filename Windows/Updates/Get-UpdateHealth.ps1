<#
.SYNOPSIS
    Checks for pending Windows updates on the endpoint.

.DESCRIPTION
    Collects all Windows Update data silently first, then reasons across the findings
    to surface actionable issues. Outputs a clean header, a FINDINGS block with
    interpreted results, and a compact DETAIL block for raw reference.
    Designed to fit in one ticket note or terminal screenshot.

.EXAMPLE
    .\Get-UpdateHealth.ps1

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

# Windows Update data via COM API
$updateError    = $false
$updateErrorMsg = ''
$pendingUpdates = @()
$totalCount     = 0
$mandatoryCount = 0

try {
    $session  = [activator]::CreateInstance([type]::GetTypeFromProgID('Microsoft.Update.Session'))
    $searcher = $session.CreateUpdateSearcher()
    $results  = $searcher.Search('IsInstalled=0 AND IsHidden=0')

    $pendingUpdates = foreach ($u in $results.Updates) {
        [PSCustomObject]@{ Title = $u.Title; IsMandatory = $u.IsMandatory }
    }
    $totalCount     = $results.Updates.Count
    $mandatoryCount = @($pendingUpdates | Where-Object { $_.IsMandatory }).Count
} catch {
    $updateError    = $true
    $updateErrorMsg = $_.Exception.Message
}

# ─────────────────────────────────────────────────────────────
#  REASON
# ─────────────────────────────────────────────────────────────

if ($updateError) {
    Add-Finding 'WARN' 'Windows Update COM API unavailable' `
        "Check wuauserv service is running. Error: $updateErrorMsg"
} elseif ($mandatoryCount -gt 0) {
    Add-Finding 'CRIT' "$mandatoryCount mandatory update(s) pending" `
        "Install via Settings → Windows Update or wuauclt /detectnow /updatenow. Restart likely required."
} elseif ($totalCount -gt 0) {
    Add-Finding 'WARN' "$totalCount update(s) pending installation" `
        "Install via Settings → Windows Update. Schedule restart in a maintenance window."
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
Write-Host '  ┌─ WINDOWS UPDATE HEALTH ────────────────────────────────┐' -ForegroundColor Cyan
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
    Write-Host '  [OK] Windows is fully up to date — no pending updates found.' -ForegroundColor Green
} else {
    foreach ($f in $findings) {
        $icon  = if ($f.Severity -eq 'INFO') { '[--]' } else { '[!!]' }
        $color = switch ($f.Severity) { 'CRIT' { 'Red' } 'WARN' { 'Yellow' } default { 'Cyan' } }
        Write-Host "  $icon $($f.Title)" -ForegroundColor $color
        Write-Host "       $($f.Detail)" -ForegroundColor DarkGray
    }
}

$issueCount = ($findings | Where-Object { $_.Severity -in 'CRIT', 'WARN' }).Count
$countColor = if ($issueCount -gt 0) { 'Yellow' } else { 'Green' }
Write-Divider "$issueCount issue(s) found"
Write-Host ''

# DETAIL
Write-Divider 'DETAIL'

if ($updateError) {
    Write-KV 'Status' 'Query failed' 'Red'
    Write-KV 'Error' $updateErrorMsg 'DarkGray'
} else {
    Write-KV 'Pending total'  "$totalCount"
    Write-KV 'Mandatory'      "$mandatoryCount" $(if ($mandatoryCount -gt 0) { 'Red' } else { 'White' })
    Write-KV 'Optional'       "$($totalCount - $mandatoryCount)"
    Write-Host ''

    if ($totalCount -eq 0) {
        Write-Host '  No pending updates.' -ForegroundColor DarkGray
    } else {
        $display = $pendingUpdates | Select-Object -First 10
        foreach ($u in $display) {
            $label = if ($u.IsMandatory) { '[MANDATORY]' } else { '[optional] ' }
            $color = if ($u.IsMandatory) { 'Red' } else { 'White' }
            Write-Host "  $label $($u.Title)" -ForegroundColor $color
        }
        if ($totalCount -gt 10) {
            Write-Host "  ... and $($totalCount - 10) more update(s) not shown." -ForegroundColor DarkGray
        }
        Write-Host ''
        Write-Host '       Tip: Run Windows Update or wuauclt /detectnow /updatenow to install.' `
            -ForegroundColor DarkGray
    }
}

Write-Host ''
$elapsed = [Math]::Round(((Get-Date) - $scriptStart).TotalSeconds, 1)
Write-Host "  Done in ${elapsed}s  |  $currentUser" -ForegroundColor DarkGray
Write-Host ''
