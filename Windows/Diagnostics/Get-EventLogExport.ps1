<#
.SYNOPSIS
    Exports System, Application, Security, and Setup event logs (last 48h) to a ZIP of .evtx files.

.DESCRIPTION
    Collects all event log data silently first, then reasons across the findings
    to surface actionable issues. Outputs a clean header, a FINDINGS block with
    interpreted results, and a compact DETAIL block for raw reference.
    Designed to fit in one ticket note or terminal screenshot.

    Output: C:\Temp\EventLogs_<HOSTNAME>_<YYYYMMDD-HHmm>.zip

.EXAMPLE
    .\Get-EventLogExport.ps1

.NOTES
    Author:  Lachlan Alston
    Version: v4
    Updated: 2026-05-02
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

# Logged-in user — SYSTEM-safe (RMM tools run as SYSTEM)
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
    $localIP = (Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" |
        Where-Object { $_.IPAddress -match '^\d+\.\d+\.\d+\.\d+$' } |
        Select-Object -First 1).IPAddress |
        Where-Object { $_ -match '^\d' } |
        Select-Object -First 1
    if (-not $localIP) { $localIP = '(unknown)' }
} catch { $localIP = '(unknown)' }

try {
    $osObj     = Get-CimInstance Win32_OperatingSystem
    $osCaption = $osObj.Caption -replace 'Microsoft Windows', 'Windows' `
                                -replace 'Professional', 'Pro'
    $osBuild   = $osObj.BuildNumber
    $upDelta   = (Get-Date) - $osObj.LastBootUpTime
    $uptime    = if ($upDelta.Days -gt 0) { "$($upDelta.Days)d $($upDelta.Hours)h" } `
                 else { "$($upDelta.Hours)h $($upDelta.Minutes)m" }
} catch {
    $osCaption = '(unknown)'; $osBuild = '?'; $uptime = '(unknown)'
}

# Output paths — timestamped so repeated runs never collide
$ts        = Get-Date -Format 'yyyyMMdd-HHmm'
$exportDir = "C:\Temp\EventLogs_$($env:COMPUTERNAME)_$ts"
$zipPath   = "C:\Temp\EventLogs_$($env:COMPUTERNAME)_$ts.zip"
$dirOk     = $false
$dirError  = ''

try {
    if (-not (Test-Path 'C:\Temp')) {
        New-Item -ItemType Directory -Path 'C:\Temp' -Force | Out-Null
    }
    New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
    $dirOk = $true
} catch {
    $dirError = $_.Exception.Message
}

# XPath filter — last 48 hours (172,800,000 ms)
$xpQuery = '*[System[TimeCreated[timediff(@SystemTime) <= 172800000]]]'

# Export each log via wevtutil — preserves native .evtx format
$logs   = @('System', 'Application', 'Security', 'Setup')
$result = @{}

foreach ($log in $logs) {
    if (-not $dirOk) {
        $result[$log] = @{ Status = 'SKIP' }
        continue
    }
    $outFile = Join-Path $exportDir "$log.xml"
    try {
        $xmlContent = & wevtutil qe $log /q:$xpQuery /f:XML /e:Events /rd:true 2>&1
        if ($LASTEXITCODE -eq 0 -and $xmlContent) {
            [System.IO.File]::WriteAllText($outFile, ($xmlContent -join "`n"), [System.Text.Encoding]::UTF8)
            $sizeKB        = [Math]::Round((Get-Item $outFile).Length / 1KB, 1)
            $result[$log]  = @{ Status = 'OK'; SizeKB = $sizeKB }
        } else {
            $result[$log]  = @{ Status = 'FAIL'; Error = ($xmlContent -join ' ').Trim() }
        }
    } catch {
        $result[$log] = @{ Status = 'FAIL'; Error = $_.Exception.Message }
    }
}

# Reliability Monitor history — collected before ZIP so it is bundled automatically
$reliabilityOk    = $false
$reliabilityCount = 0
$reliabilityError = ''

if ($dirOk) {
    try {
        $relRecords = @(Get-WmiObject -Class Win32_ReliabilityRecords -ErrorAction Stop |
            Sort-Object TimeGenerated -Descending)
        $reliabilityCount = $relRecords.Count

        $htmlRows = ($relRecords | ForEach-Object {
            try   { $dt = [Management.ManagementDateTimeConverter]::ToDateTime($_.TimeGenerated).ToString('yyyy-MM-dd HH:mm') }
            catch { $dt = $_.TimeGenerated }
            $src  = $_.SourceName  -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;'
            $prod = $_.ProductName -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;'
            $msg  = ($_.Message    -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;') -replace '\r?\n',' '
            $cls  = if ($src -match 'Error|Hang|Failure') { ' class="err"' } else { '' }
            "<tr$cls><td>$dt</td><td>$src</td><td>$prod</td><td>$msg</td></tr>"
        }) -join "`n"

        $relHtml = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Reliability History — $($env:COMPUTERNAME)</title>
  <style>
    body  { font-family:'Segoe UI',sans-serif; background:#0d1117; color:#e6edf3; margin:0; padding:24px; }
    h1    { color:#58a6ff; font-size:1.1rem; margin:0 0 4px; }
    .meta { color:#8b949e; font-size:0.82rem; margin:0 0 20px; }
    table { border-collapse:collapse; width:100%; font-size:0.82rem; }
    th    { background:#161b22; color:#58a6ff; text-align:left; padding:8px 12px; border-bottom:2px solid #30363d; white-space:nowrap; }
    td    { padding:6px 12px; border-bottom:1px solid #21262d; vertical-align:top; }
    tr:hover td { background:#161b22; }
    tr.err td   { color:#f85149; }
  </style>
</head>
<body>
  <h1>Reliability Monitor History</h1>
  <p class="meta">Host: $($env:COMPUTERNAME) &nbsp;|&nbsp; Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm') &nbsp;|&nbsp; $reliabilityCount event(s)</p>
  <table>
    <thead><tr><th>Date / Time</th><th>Source</th><th>Product / Application</th><th>Description</th></tr></thead>
    <tbody>
$htmlRows
    </tbody>
  </table>
</body>
</html>
"@
        $relPath = Join-Path $exportDir 'ReliabilityHistory.html'
        [System.IO.File]::WriteAllText($relPath, $relHtml, [System.Text.Encoding]::UTF8)

        # XML export — structured format for Eventful Reliability Analyzer
        $xmlRecords = ($relRecords | ForEach-Object {
            try   { $dt = [Management.ManagementDateTimeConverter]::ToDateTime($_.TimeGenerated).ToString('yyyy-MM-dd HH:mm:ss') }
            catch { $dt = $_.TimeGenerated }
            $src  = $_.SourceName  -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;'
            $prod = $_.ProductName -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;'
            $msg  = ($_.Message    -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;') -replace '\r?\n',' '
            $user = if ($_.User)    { $_.User    -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' } else { '' }
            $eid  = if ($_.EventIdentifier) { $_.EventIdentifier } else { '' }
            "  <Record>`n    <TimeGenerated>$dt</TimeGenerated>`n    <SourceName>$src</SourceName>`n    <ProductName>$prod</ProductName>`n    <Message>$msg</Message>`n    <EventIdentifier>$eid</EventIdentifier>`n    <User>$user</User>`n  </Record>"
        }) -join "`n"

        $relXml = "<?xml version=`"1.0`" encoding=`"UTF-8`"?>`n<ReliabilityRecords computer=`"$($env:COMPUTERNAME)`" generated=`"$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`" count=`"$reliabilityCount`">`n$xmlRecords`n</ReliabilityRecords>"
        $xmlPath = Join-Path $exportDir 'ReliabilityHistory.xml'
        [System.IO.File]::WriteAllText($xmlPath, $relXml, [System.Text.Encoding]::UTF8)

        $reliabilityOk = $true
    } catch {
        $reliabilityError = $_.Exception.Message
    }
}

# Bundle into ZIP and remove staging folder
$zipOk     = $false
$zipSizeKB = 0
$zipError  = ''

try {
    if ($dirOk) {
        Compress-Archive -Path "$exportDir\*" -DestinationPath $zipPath -Force
        if (Test-Path $zipPath) {
            $zipOk     = $true
            $zipSizeKB = [Math]::Round((Get-Item $zipPath).Length / 1KB, 1)
            Remove-Item -Path $exportDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
} catch {
    $zipError = $_.Exception.Message
}

# ─────────────────────────────────────────────────────────────
#  REASON
# ─────────────────────────────────────────────────────────────

if (-not $dirOk) {
    Add-Finding 'CRIT' 'Output directory could not be created' `
        "Could not create C:\Temp — check local permissions. Error: $dirError"
}

foreach ($log in $logs) {
    if ($result[$log].Status -eq 'FAIL') {
        Add-Finding 'WARN' "$log log export failed" `
            "wevtutil error: $($result[$log].Error)"
    }
}

if ($dirOk -and -not $zipOk) {
    Add-Finding 'WARN' 'ZIP creation failed' `
        "Individual .evtx files remain at $exportDir — retrieve folder directly. Error: $zipError"
}

if ($dirOk -and -not $reliabilityOk) {
    Add-Finding 'WARN' 'Reliability history report unavailable' `
        "Win32_ReliabilityRecords could not be read — excluded from ZIP. Error: $reliabilityError"
}

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
Write-Host '  ┌─ EVENT LOG EXPORT ─────────────────────────────────────┐' -ForegroundColor Cyan
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
$findings = $findings | Sort-Object { switch ($_.Severity) { 'CRIT' { 0 } 'WARN' { 1 } default { 2 } } }
Write-Divider 'FINDINGS'

if ($findings.Count -eq 0) {
    Write-Host '  [OK] All logs exported successfully.' -ForegroundColor Green
} else {
    foreach ($f in $findings) {
        $color = if ($f.Severity -eq 'CRIT') { 'Red' } else { 'Yellow' }
        Write-Host "  [!!] $($f.Title)" -ForegroundColor $color
        Write-Host "       $($f.Detail)" -ForegroundColor DarkGray
    }
}

$issueCount  = ($findings | Where-Object { $_.Severity -in 'CRIT', 'WARN' }).Count
$countColor  = if ($issueCount -gt 0) { 'Yellow' } else { 'Green' }
Write-Divider "$issueCount issue(s) found"
Write-Host ''

# DETAIL
Write-Divider 'DETAIL'
Write-KV 'Range'  'Last 48 hours'
Write-KV 'Format' '.xml (rendered messages embedded — open in browser or text editor)'
Write-Host ''

foreach ($log in $logs) {

    $r = $result[$log]
    switch ($r.Status) {
        'OK'   { Write-KV $log "$($r.SizeKB) KB" }
        'FAIL' { Write-KV $log 'EXPORT FAILED' 'Red' }
        'SKIP' { Write-KV $log 'SKIPPED' 'Yellow' }
    }
}

Write-Host ''

if ($reliabilityOk) {
    Write-KV 'Reliability' "$reliabilityCount event(s) — ReliabilityHistory.html + .xml"
} elseif ($dirOk) {
    Write-KV 'Reliability' 'UNAVAILABLE' 'Yellow'
}

Write-Host ''

if ($zipOk) {
    Write-KV 'Output' $zipPath 'Green'
    Write-KV 'ZIP size' "$zipSizeKB KB"
    Write-Host "       Tip: Download $zipPath and open .evtx files in Event Viewer." `
        -ForegroundColor DarkGray
} elseif ($dirOk) {
    Write-KV 'Output' $exportDir 'Yellow'
    Write-Host '       Tip: ZIP failed — download the folder directly.' -ForegroundColor DarkGray
} else {
    Write-KV 'Output' 'UNAVAILABLE' 'Red'
}

Write-Host ''
$elapsed = [Math]::Round(((Get-Date) - $scriptStart).TotalSeconds, 1)
Write-Host "  Done in ${elapsed}s  |  $currentUser" -ForegroundColor DarkGray
Write-Host ''
