<#
.SYNOPSIS
    Reports Windows Update install history — last success date, recent failures, and entry list.

.DESCRIPTION
    Collects all Windows Update history data silently first, then reasons across the findings
    to surface actionable issues. Outputs a clean header, a FINDINGS block with
    interpreted results, and a compact DETAIL block for raw reference.
    Designed to fit in one ticket note or terminal screenshot.

.EXAMPLE
    .\Get-UpdateHistory.ps1

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

# Windows Update history via COM API
$historyError    = $false
$historyErrorMsg = ''
$historyEntries  = @()
$lastSuccessDate = $null
$daysSinceLast   = $null
$recentFails     = 0

try {
    $session  = [activator]::CreateInstance([type]::GetTypeFromProgID('Microsoft.Update.Session'))
    $searcher = $session.CreateUpdateSearcher()
    $total    = $searcher.GetTotalHistoryCount()

    if ($total -gt 0) {
        $raw = $searcher.QueryHistory(0, [Math]::Min($total, 50))

        $historyEntries = foreach ($h in $raw) {
            # ResultCode: 1=In Progress, 2=Succeeded, 3=SucceededWithErrors, 4=Failed, 5=Aborted
            $resultText = switch ($h.ResultCode) {
                1 { 'In Progress' }
                2 { 'Succeeded' }
                3 { 'Succeeded (errors)' }
                4 { 'Failed' }
                5 { 'Aborted' }
                default { "Unknown ($($h.ResultCode))" }
            }
            [PSCustomObject]@{
                Date   = $h.Date
                Title  = $h.Title
                Result = $resultText
                HResult = if ($h.HResult -ne 0) { "0x{0:X8}" -f $h.HResult } else { '' }
            }
        }

        # Last successful install
        $lastSuccess = $historyEntries |
            Where-Object { $_.Result -eq 'Succeeded' -or $_.Result -eq 'Succeeded (errors)' } |
            Sort-Object Date -Descending |
            Select-Object -First 1

        if ($lastSuccess) {
            $lastSuccessDate = $lastSuccess.Date
            $daysSinceLast   = [Math]::Round(((Get-Date) - $lastSuccessDate).TotalDays, 0)
        }

        # Recent failures (last 30 days)
        $cutoff       = (Get-Date).AddDays(-30)
        $recentFails  = @($historyEntries |
            Where-Object { $_.Result -eq 'Failed' -and $_.Date -ge $cutoff }).Count
    }
} catch {
    $historyError    = $true
    $historyErrorMsg = $_.Exception.Message
}

# ─────────────────────────────────────────────────────────────
#  REASON
# ─────────────────────────────────────────────────────────────

if ($historyError) {
    Add-Finding 'WARN' 'Windows Update COM API unavailable' `
        "Check wuauserv service is running. Error: $historyErrorMsg"
} else {
    if ($null -eq $lastSuccessDate) {
        Add-Finding 'WARN' 'No successful updates found in history' `
            "Query returned no successful installs — run Windows Update manually or check wuauserv."
    } elseif ($daysSinceLast -gt 30) {
        Add-Finding 'WARN' "No updates installed in $daysSinceLast days" `
            "Trigger a manual sync via Settings → Windows Update or wuauclt /detectnow /updatenow."
    }

    if ($recentFails -gt 0) {
        Add-Finding 'WARN' "$recentFails update failure(s) in the last 30 days" `
            "Check HResult codes in DETAIL — search Microsoft error code lookup for remediation steps."
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
Write-Host '  ┌─ WINDOWS UPDATE HISTORY ───────────────────────────────┐' -ForegroundColor Cyan
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
    Write-Host '  [OK] Update history looks healthy — recent successful installs found.' -ForegroundColor Green
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

if ($historyError) {
    Write-KV 'Status' 'Query failed' 'Red'
    Write-KV 'Error' $historyErrorMsg 'DarkGray'
} else {
    $lastDateStr = if ($lastSuccessDate) { $lastSuccessDate.ToString('yyyy-MM-dd HH:mm') } else { '(none)' }
    $daysStr     = if ($null -ne $daysSinceLast) { "$daysSinceLast days ago" } else { '(unknown)' }

    Write-KV 'Last success'   $lastDateStr $(if ($daysSinceLast -gt 30) { 'Yellow' } else { 'White' })
    Write-KV 'Days since'     $daysStr     $(if ($daysSinceLast -gt 30) { 'Yellow' } else { 'White' })
    Write-KV 'Recent fails'   "$recentFails (last 30d)" $(if ($recentFails -gt 0) { 'Red' } else { 'White' })
    Write-KV 'History queried' "$([Math]::Min($historyEntries.Count, 50)) entries"
    Write-Host ''

    if ($historyEntries.Count -eq 0) {
        Write-Host '  No update history entries found.' -ForegroundColor DarkGray
    } else {
        $display = $historyEntries | Select-Object -First 10
        foreach ($h in $display) {
            $dateStr = $h.Date.ToString('yyyy-MM-dd')
            $status  = $h.Result
            $color   = switch ($h.Result) {
                'Failed'   { 'Red' }
                'Aborted'  { 'Yellow' }
                default    { 'White' }
            }
            $hresultSuffix = if ($h.HResult) { "  [$($h.HResult)]" } else { '' }
            $title = if ($h.Title.Length -gt 55) { $h.Title.Substring(0, 52) + '...' } else { $h.Title }
            Write-Host ("  {0}  {1,-10}  {2}{3}" -f $dateStr, $status, $title, $hresultSuffix) -ForegroundColor $color
        }
        if ($historyEntries.Count -gt 10) {
            Write-Host "  ... and $($historyEntries.Count - 10) more entries not shown." -ForegroundColor DarkGray
        }
    }
}

Write-Host ''
$elapsed = [Math]::Round(((Get-Date) - $scriptStart).TotalSeconds, 1)
Write-Host "  Done in ${elapsed}s  |  $currentUser" -ForegroundColor DarkGray
Write-Host ''
