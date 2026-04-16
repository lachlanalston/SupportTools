<#
.SYNOPSIS
    Reports all notable changes on a Windows endpoint in the last 72 hours.

.DESCRIPTION
    Collects all change data silently first, then reasons across the findings
    to surface actionable issues. Outputs a clean header, a FINDINGS block with
    interpreted results, a DETAIL block with a categorised change timeline, and
    a plain-text TICKET NOTE ready for copy-paste into a PSA.
    Designed to fit in one ticket note or terminal screenshot.

.EXAMPLE
    .\Get-RecentChanges.ps1

.NOTES
    Author:  Lachlan Alston
    Version: v1
    Updated: 2026-04-14
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
$cutoff      = $scriptStart.AddHours(-72)
$cutoffLabel = $cutoff.ToString('yyyy-MM-dd HH:mm')

# Box header
try {
    $rawUser     = (Get-CimInstance Win32_ComputerSystem).UserName
    $currentUser = if ($rawUser) { $rawUser.Split('\')[-1] } else { '(none logged in)' }
} catch { $currentUser = '(unknown)' }

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
    $os         = Get-CimInstance Win32_OperatingSystem
    $osCaption  = $os.Caption -replace 'Microsoft Windows', 'Windows' -replace 'Professional', 'Pro'
    $osBuild    = $os.BuildNumber
    $uptime     = $scriptStart - $os.LastBootUpTime
    $uptimeStr  = if ($uptime.Days -gt 0) { "$($uptime.Days)d $($uptime.Hours)h" } else { "$($uptime.Hours)h $($uptime.Minutes)m" }
} catch {
    $osCaption = '(unknown)'; $osBuild = '?'; $uptimeStr = '(unknown)'
}

# Windows Updates installed (Event ID 19)
$wuUpdates = @()
try {
    $wuUpdates = Get-WinEvent -FilterHashtable @{
        LogName      = 'System'
        ProviderName = 'Microsoft-Windows-WindowsUpdateClient'
        Id           = 19
        StartTime    = $cutoff
    } -ErrorAction Stop | Sort-Object TimeCreated -Descending
} catch {}

# Software installs (MSI Event ID 11707)
$swInstalls = @()
try {
    $swInstalls = Get-WinEvent -FilterHashtable @{
        LogName      = 'Application'
        ProviderName = 'MsiInstaller'
        Id           = 11707
        StartTime    = $cutoff
    } -ErrorAction Stop | Sort-Object TimeCreated -Descending
} catch {}

# Software uninstalls (MSI Event ID 11724)
$swUninstalls = @()
try {
    $swUninstalls = Get-WinEvent -FilterHashtable @{
        LogName      = 'Application'
        ProviderName = 'MsiInstaller'
        Id           = 11724
        StartTime    = $cutoff
    } -ErrorAction Stop | Sort-Object TimeCreated -Descending
} catch {}

# Driver installations (UserPnP Event ID 20001)
$driverChanges = @()
try {
    $driverChanges = Get-WinEvent -FilterHashtable @{
        LogName      = 'System'
        ProviderName = 'Microsoft-Windows-UserPnP'
        Id           = 20001
        StartTime    = $cutoff
    } -ErrorAction Stop | Sort-Object TimeCreated -Descending
} catch {}

# New services installed (Service Control Manager Event ID 7045)
$newServices = @()
try {
    $newServices = Get-WinEvent -FilterHashtable @{
        LogName      = 'System'
        ProviderName = 'Service Control Manager'
        Id           = 7045
        StartTime    = $cutoff
    } -ErrorAction Stop | Sort-Object TimeCreated -Descending
} catch {}

# Reboots and shutdowns (6005=startup, 6008=unexpected shutdown, 1074=initiated restart)
$rebootEvents = @()
try {
    $rebootEvents = Get-WinEvent -FilterHashtable @{
        LogName   = 'System'
        Id        = @(6005, 6008, 1074)
        StartTime = $cutoff
    } -ErrorAction Stop | Sort-Object TimeCreated -Descending
} catch {}

# Application crashes (Application Error Event ID 1000)
$crashEvents = @()
try {
    $crashEvents = Get-WinEvent -FilterHashtable @{
        LogName      = 'Application'
        ProviderName = 'Application Error'
        Id           = 1000
        StartTime    = $cutoff
    } -ErrorAction Stop | Sort-Object TimeCreated -Descending
} catch {}

# User logons — interactive (type 2) and RDP (type 10) only, suppress machine/built-in accounts
$logonEvents = @()
try {
    $rawLogons = Get-WinEvent -FilterHashtable @{
        LogName   = 'Security'
        Id        = 4624
        StartTime = $cutoff
    } -ErrorAction Stop

    $logonEvents = foreach ($evt in $rawLogons) {
        try {
            $xml       = [xml]$evt.ToXml()
            $data      = $xml.Event.EventData.Data
            $logonType = ($data | Where-Object { $_.Name -eq 'LogonType' }).'#text'
            $username  = ($data | Where-Object { $_.Name -eq 'TargetUserName' }).'#text'

            if ($logonType -notin @('2', '10')) { continue }
            if ($username -match '\$$')         { continue }
            if ($username -in @('SYSTEM', 'LOCAL SERVICE', 'NETWORK SERVICE',
                                'DWM-1', 'DWM-2', 'DWM-3', 'UMFD-0', 'UMFD-1', 'UMFD-2')) { continue }

            [PSCustomObject]@{
                TimeCreated = $evt.TimeCreated
                Username    = $username
                LogonType   = if ($logonType -eq '2') { 'Interactive' } else { 'RDP' }
            }
        } catch {}
    }
    $logonEvents = @($logonEvents | Sort-Object TimeCreated -Descending)
} catch {}

# ─────────────────────────────────────────────────────────────
#  REASON
# ─────────────────────────────────────────────────────────────

# Unexpected shutdown
$unexpectedShutdowns = @($rebootEvents | Where-Object { $_.Id -eq 6008 })
if ($unexpectedShutdowns.Count -gt 0) {
    $ts = $unexpectedShutdowns[0].TimeCreated.ToString('yyyy-MM-dd HH:mm')
    Add-Finding 'WARN' "Unexpected shutdown detected ($ts)" `
        "Check Event ID 41 (Kernel-Power) and 1001 (BugCheck) near this time — power loss or BSOD."
}

# Multiple reboots suggest instability (3+ startups excluding the first boot of the 72h window)
$startupCount = @($rebootEvents | Where-Object { $_.Id -eq 6005 }).Count
if ($startupCount -ge 3) {
    Add-Finding 'WARN' "Machine started up $startupCount times in the last 72 hours" `
        "Review Event ID 41 for unexpected reboots — may indicate update loops, BSOD, or power issues."
}

# App crashes — group by application name, flag repeated crashes
$crashGroups = @{}
foreach ($crash in $crashEvents) {
    $appName = if ($crash.Message -match 'Faulting application name:\s*([^,\r\n]+)') {
        $matches[1].Trim().ToLower()
    } else { '(unknown)' }

    if (-not $crashGroups.ContainsKey($appName)) { $crashGroups[$appName] = 0 }
    $crashGroups[$appName]++
}
foreach ($app in $crashGroups.Keys) {
    $count = $crashGroups[$app]
    if ($count -ge 3) {
        Add-Finding 'WARN' "$app crashed $count time(s) in the last 72h" `
            "Check for pending updates, corrupt profile, or conflicting add-ins. Repair or reinstall."
    } elseif ($count -ge 1) {
        Add-Finding 'INFO' "$app crashed $count time(s) in the last 72h" `
            "Monitor — if it recurs, check for updates or run a repair."
    }
}

# Sort: CRIT → WARN → INFO
$findings = $findings | Sort-Object { switch ($_.Severity) { 'CRIT' { 0 } 'WARN' { 1 } default { 2 } } }

# ─────────────────────────────────────────────────────────────
#  OUTPUT
# ─────────────────────────────────────────────────────────────

# Terminal width check
$termWidth = $Host.UI.RawUI.WindowSize.Width
if ($termWidth -gt 0 -and $termWidth -lt 90) {
    Write-Host "  [WARN] Terminal is $termWidth cols wide — output may wrap. Recommended: 90+ cols." -ForegroundColor Yellow
}

# Box header
$runAt = $scriptStart.ToString('yyyy-MM-dd HH:mm')
Write-Host ""
Write-Host "  ┌─ RECENT CHANGES ───────────────────────────────────────┐" -ForegroundColor Cyan
Write-Host ("  │  {0,-58}│" -f "Host    $env:COMPUTERNAME")                -ForegroundColor Cyan
Write-Host ("  │  {0,-58}│" -f "User    $currentUser")                     -ForegroundColor Cyan
Write-Host ("  │  {0,-58}│" -f "Model   $model")                           -ForegroundColor Cyan
Write-Host ("  │  {0,-58}│" -f "S/N     $serial")                          -ForegroundColor Cyan
Write-Host ("  │  {0,-58}│" -f "OS      $osCaption  Build $osBuild")       -ForegroundColor Cyan
Write-Host ("  │  {0,-58}│" -f "Domain  $domain")                          -ForegroundColor Cyan
Write-Host ("  │  {0,-58}│" -f "IP      $localIP")                         -ForegroundColor Cyan
Write-Host ("  │  {0,-58}│" -f "Uptime  $uptimeStr")                       -ForegroundColor Cyan
Write-Host ("  │  {0,-58}│" -f "Run     $runAt  (since $cutoffLabel)")     -ForegroundColor Cyan
Write-Host "  └────────────────────────────────────────────────────────┘" -ForegroundColor Cyan
Write-Host ""

# FINDINGS
Write-Divider 'FINDINGS'
if ($findings.Count -eq 0) {
    Write-Host "  [OK] No notable issues in the last 72 hours." -ForegroundColor Green
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
Write-Host ""
Write-Divider "$issueCount issue(s) found"
Write-Host ""

# DETAIL — helper renders a named change section
function Write-ChangeSection {
    param([string]$Title, [string[]]$Items)
    Write-Host "  $Title" -ForegroundColor White
    if ($Items.Count -eq 0) {
        Write-Host "    (none in last 72h)" -ForegroundColor DarkGray
    } else {
        foreach ($item in $Items) {
            Write-Host "    $item" -ForegroundColor White
        }
    }
    Write-Host ""
}

Write-Divider 'DETAIL'
Write-Host ""

# Build display lines per category
$rebootLines = @(foreach ($r in $rebootEvents) {
    $ts    = $r.TimeCreated.ToString('yyyy-MM-dd HH:mm')
    $label = switch ($r.Id) {
        6005 { 'System startup' }
        6008 { 'Unexpected shutdown  [!!]' }
        1074 {
            if ($r.Message -match 'restart|reboot') { 'Restart (user/process initiated)' }
            else { 'Shutdown (user/process initiated)' }
        }
        default { "Event $($r.Id)" }
    }
    "$ts  $label"
})

$wuLines = @(foreach ($u in $wuUpdates) {
    $ts   = $u.TimeCreated.ToString('yyyy-MM-dd HH:mm')
    $desc = if ($u.Message -match 'update[:\s]+"?(.+?)"?\s*$') { $matches[1].Trim() }
            elseif ($u.Message -match '"([^"]+)"')              { $matches[1].Trim() }
            else { ($u.Message -split "`n")[0].Trim() }
    "$ts  $desc"
})

$installLines = @(foreach ($i in $swInstalls) {
    $ts   = $i.TimeCreated.ToString('yyyy-MM-dd HH:mm')
    $name = if ($i.Message -match 'Product: ([^–\-]+?)[\s]*(?:--|–)') { $matches[1].Trim() }
            elseif ($i.Message -match 'Product: ([^\r\n]+)')           { $matches[1].Trim() }
            else { ($i.Message -split "`n")[0].Trim() }
    "$ts  $name  [installed]"
})

$uninstallLines = @(foreach ($u in $swUninstalls) {
    $ts   = $u.TimeCreated.ToString('yyyy-MM-dd HH:mm')
    $name = if ($u.Message -match 'Product: ([^–\-]+?)[\s]*(?:--|–)') { $matches[1].Trim() }
            elseif ($u.Message -match 'Product: ([^\r\n]+)')           { $matches[1].Trim() }
            else { ($u.Message -split "`n")[0].Trim() }
    "$ts  $name  [removed]"
})

$driverLines = @(foreach ($d in $driverChanges) {
    $ts   = $d.TimeCreated.ToString('yyyy-MM-dd HH:mm')
    $desc = if ($d.Message -match "Device '([^']+)'")  { $matches[1].Trim() }
            elseif ($d.Message -match 'Device ([^\(]+)') { $matches[1].Trim() }
            else { ($d.Message -split "`n")[0].Trim() }
    "$ts  $desc"
})

$serviceLines = @(foreach ($s in $newServices) {
    $ts      = $s.TimeCreated.ToString('yyyy-MM-dd HH:mm')
    $svcName = if ($s.Message -match 'Service Name:\s*([^\r\n]+)') { $matches[1].Trim() } else { '(unknown)' }
    "$ts  $svcName"
})

$crashLines = @(foreach ($c in $crashEvents) {
    $ts      = $c.TimeCreated.ToString('yyyy-MM-dd HH:mm')
    $appName = if ($c.Message -match 'Faulting application name:\s*([^,\r\n]+)') { $matches[1].Trim() } else { '(unknown)' }
    "$ts  $appName"
})

$logonLines = @(foreach ($l in $logonEvents) {
    $ts = $l.TimeCreated.ToString('yyyy-MM-dd HH:mm')
    "$ts  $($l.Username)  ($($l.LogonType))"
})

Write-ChangeSection 'REBOOTS / STARTUPS'    $rebootLines
Write-ChangeSection 'WINDOWS UPDATES'       $wuLines
Write-ChangeSection 'SOFTWARE INSTALLS'     $installLines
Write-ChangeSection 'SOFTWARE REMOVALS'     $uninstallLines
Write-ChangeSection 'DRIVER CHANGES'        $driverLines
Write-ChangeSection 'NEW SERVICES'          $serviceLines
Write-ChangeSection 'APPLICATION CRASHES'   $crashLines
Write-ChangeSection 'USER LOGONS'           $logonLines

# TICKET NOTE — plain text, copy-paste ready
Write-Divider 'TICKET NOTE'
Write-Host ""

$noteLines = [System.Collections.Generic.List[string]]::new()
$noteLines.Add("=== RECENT CHANGES — $env:COMPUTERNAME ===")
$noteLines.Add("Period: $cutoffLabel  to  $runAt")
$noteLines.Add("")

function Add-NoteSection {
    param([string]$Title, [string[]]$Items)
    $noteLines.Add("[$Title]")
    if ($Items.Count -eq 0) { $noteLines.Add("  (none)") }
    else { foreach ($item in $Items) { $noteLines.Add("  $item") } }
    $noteLines.Add("")
}

Add-NoteSection 'REBOOTS / STARTUPS'  $rebootLines
Add-NoteSection 'WINDOWS UPDATES'     $wuLines
Add-NoteSection 'SOFTWARE INSTALLS'   $installLines
Add-NoteSection 'SOFTWARE REMOVALS'   $uninstallLines
Add-NoteSection 'DRIVER CHANGES'      $driverLines
Add-NoteSection 'NEW SERVICES'        $serviceLines
Add-NoteSection 'APPLICATION CRASHES' $crashLines
Add-NoteSection 'USER LOGONS'         $logonLines

if ($issueCount -gt 0) {
    $noteLines.Add('[FLAGGED]')
    foreach ($f in ($findings | Where-Object { $_.Severity -in 'CRIT', 'WARN' })) {
        $noteLines.Add("  [!!] $($f.Title)")
        $noteLines.Add("       $($f.Detail)")
    }
    $noteLines.Add("")
}

foreach ($line in $noteLines) {
    Write-Host $line -ForegroundColor White
}

# Footer
$elapsed = [Math]::Round(((Get-Date) - $scriptStart).TotalSeconds, 1)
Write-Host ""
Write-Host "  Done in ${elapsed}s  |  $currentUser" -ForegroundColor DarkGray
Write-Host ""
