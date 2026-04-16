<#
.SYNOPSIS
    Checks Netskope client installation state and service health. Optionally removes all Netskope components.

.DESCRIPTION
    Collects all Netskope health data silently first, then reasons across the findings
    to surface actionable issues. Outputs a clean header, a FINDINGS block with
    interpreted results, and a compact DETAIL block for raw reference.
    Designed to fit in one ticket note or terminal screenshot.

.PARAMETER Remove
    Performs a full Netskope removal: stops the service, uninstalls via MSI product code,
    removes data folders, deletes certificates, and cleans up user roaming data.
    Without this switch the script is read-only.

.EXAMPLE
    .\Get-NetskopeHealth.ps1

.EXAMPLE
    .\Get-NetskopeHealth.ps1 -Remove

.NOTES
    Author:  Lachlan Alston
    Version: v1
    Updated: 2026-04-16
#>

[CmdletBinding()]
param(
    [switch]$Remove
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

# Netskope install state via registry (faster than Win32_Product)
$nsInstalled  = $false
$nsVersion    = '(unknown)'
$nsGuid       = $null
$nsPaths      = @(
    'C:\Program Files (x86)\Netskope\STAgent',
    'C:\ProgramData\Netskope'
)

try {
    $uninstallPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $nsReg = Get-ItemProperty $uninstallPaths -ErrorAction SilentlyContinue |
             Where-Object { $_.DisplayName -like '*Netskope*' } |
             Select-Object -First 1

    if ($nsReg) {
        $nsInstalled = $true
        $nsVersion   = $nsReg.DisplayVersion
        $nsGuid      = $nsReg.PSChildName
    }
} catch { }

# Netskope service
$svcName    = 'stAgentSvc'
$svcStatus  = '(not found)'
$svcRunning = $false
try {
    $svc        = Get-Service -Name $svcName -ErrorAction Stop
    $svcStatus  = $svc.Status.ToString()
    $svcRunning = ($svc.Status -eq 'Running')
} catch { }

# Netskope certs
$nsCertCount = 0
try {
    $nsCertCount = @(Get-ChildItem Cert:\LocalMachine\Root -ErrorAction SilentlyContinue |
        Where-Object { $_.Issuer -like '*Netskope*' -or $_.Subject -like '*Netskope*' }).Count
} catch { }

# Folder presence
$folderPresence = foreach ($p in $nsPaths) { [PSCustomObject]@{ Path = $p; Exists = (Test-Path $p) } }

# -Remove action
$removeLog     = [System.Collections.Generic.List[string]]::new()
$removeSuccess = $false

if ($Remove) {
    # Stop locking processes
    try {
        Get-Process | Where-Object { $_.Path -like '*Netskope*' } | ForEach-Object {
            try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch { }
        }
        $removeLog.Add('Stopped Netskope processes.')
    } catch { }

    # Stop service
    try {
        if (Get-Service -Name $svcName -ErrorAction SilentlyContinue) {
            Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
            & sc.exe delete $svcName 2>&1 | Out-Null
            $removeLog.Add("Stopped and deleted service: $svcName")
        }
    } catch { $removeLog.Add("Service removal error: $($_.Exception.Message)") }

    # MSI uninstall via product code from registry
    if ($nsGuid) {
        try {
            $proc = Start-Process msiexec.exe -ArgumentList "/x `"$nsGuid`" /qn" -Wait -PassThru -ErrorAction Stop
            $removeLog.Add("MSI uninstall ($nsGuid) exit code: $($proc.ExitCode)")
        } catch { $removeLog.Add("MSI uninstall error: $($_.Exception.Message)") }
        Start-Sleep -Seconds 5
    } else {
        $removeLog.Add('MSI product code not found — skipped MSI uninstall.')
    }

    # Remove data folders
    foreach ($p in $nsPaths) {
        if (Test-Path $p) {
            try {
                Remove-Item $p -Recurse -Force -ErrorAction Stop
                $removeLog.Add("Removed folder: $p")
            } catch { $removeLog.Add("Failed to remove $p : $($_.Exception.Message)") }
        }
    }

    # Remove certificates
    try {
        Get-ChildItem Cert:\LocalMachine\Root -ErrorAction SilentlyContinue |
            Where-Object { $_.Issuer -like '*Netskope*' -or $_.Subject -like '*Netskope*' } |
            ForEach-Object {
                Remove-Item "Cert:\LocalMachine\Root\$($_.Thumbprint)" -ErrorAction SilentlyContinue
            }
        $removeLog.Add('Removed Netskope root certificates.')
    } catch { $removeLog.Add("Certificate removal error: $($_.Exception.Message)") }

    # Remove user roaming data
    try {
        Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $rPath = "$($_.FullName)\AppData\Roaming\Netskope"
            if (Test-Path $rPath) {
                try { Remove-Item $rPath -Recurse -Force -ErrorAction Stop
                      $removeLog.Add("Removed roaming data: $rPath") } catch { }
            }
        }
    } catch { }

    # Re-check state after removal
    $nsInstalled = $false
    try {
        $nsReg2 = Get-ItemProperty @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        ) -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like '*Netskope*' } |
        Select-Object -First 1
        if ($nsReg2) { $nsInstalled = $true }
    } catch { }

    $svcStillExists = $null -ne (Get-Service -Name $svcName -ErrorAction SilentlyContinue)
    $folderPresence = foreach ($p in $nsPaths) { [PSCustomObject]@{ Path = $p; Exists = (Test-Path $p) } }
    $nsCertCount    = @(Get-ChildItem Cert:\LocalMachine\Root -ErrorAction SilentlyContinue |
        Where-Object { $_.Issuer -like '*Netskope*' -or $_.Subject -like '*Netskope*' }).Count

    $leftovers = @()
    if ($nsInstalled)         { $leftovers += 'MSI entry still present in registry' }
    if ($svcStillExists)      { $leftovers += "Service $svcName still exists" }
    if ($nsCertCount -gt 0)   { $leftovers += "$nsCertCount certificate(s) still in root store" }
    foreach ($fp in $folderPresence | Where-Object { $_.Exists }) { $leftovers += "Folder still exists: $($fp.Path)" }

    if ($leftovers.Count -eq 0) {
        $removeSuccess = $true
        $removeLog.Add('Removal complete — no Netskope remnants detected.')
    } else {
        $removeLog.Add("Remnants remaining: $($leftovers -join '; ')")
    }

    $svcStatus  = if ($svcStillExists) { 'Still present' } else { 'Removed' }
    $svcRunning = $false
}

# ─────────────────────────────────────────────────────────────
#  REASON
# ─────────────────────────────────────────────────────────────

if (-not $Remove) {
    if ($nsInstalled -and -not $svcRunning) {
        Add-Finding 'WARN' 'Netskope installed but service is not running' `
            "Check stAgentSvc — start it via services.msc or contact Netskope admin. Agent may not be enforcing policy."
    }
} else {
    if ($nsInstalled -or ($svcStatus -eq 'Still present') -or $nsCertCount -gt 0) {
        Add-Finding 'WARN' 'Netskope remnants detected after removal attempt' `
            "Check DETAIL for specifics. A reboot may be required to release file locks before re-running."
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
Write-Host '  ┌─ NETSKOPE HEALTH ──────────────────────────────────────┐' -ForegroundColor Cyan
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

if ($Remove -and $removeLog.Count -gt 0) {
    Write-Divider 'REMOVE ACTIONS'
    foreach ($line in $removeLog) {
        $color = if ($line -like '*error*' -or $line -like '*remnant*' -or $line -like '*Failed*') { 'Yellow' } `
                 elseif ($line -like '*complete*') { 'Green' } else { 'White' }
        Write-Host "  [>>] $line" -ForegroundColor $color
    }
    Write-Host ''
}

# FINDINGS
Write-Divider 'FINDINGS'

if ($findings.Count -eq 0) {
    if ($Remove -and $removeSuccess) {
        Write-Host '  [OK] Netskope fully removed — no remnants detected.' -ForegroundColor Green
    } elseif (-not $nsInstalled) {
        Write-Host '  [OK] Netskope is not installed on this endpoint.' -ForegroundColor Green
    } else {
        Write-Host '  [OK] Netskope is installed and the agent service is running.' -ForegroundColor Green
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

$instColor = if ($nsInstalled) { 'White' } elseif ($Remove) { 'Green' } else { 'DarkGray' }
$svcColor  = if ($svcRunning) { 'White' } elseif ($svcStatus -eq '(not found)' -or $svcStatus -eq 'Removed') { 'DarkGray' } else { 'Yellow' }

Write-KV 'Installed'   $(if ($nsInstalled) { "Yes  v$nsVersion" } else { 'No' }) $instColor
Write-KV 'Agent GUID'  $(if ($nsGuid) { $nsGuid } else { '(none)' })
Write-KV 'Service'     $svcStatus $svcColor
Write-KV 'Certs (root)' "$nsCertCount" $(if ($nsCertCount -gt 0) { 'Yellow' } else { 'White' })
Write-Host ''
foreach ($fp in $folderPresence) {
    $fColor = if ($fp.Exists) { 'Yellow' } else { 'DarkGray' }
    $fState = if ($fp.Exists) { 'Present' } else { 'Not found' }
    $fLabel = if ($fp.Path.Length -gt 40) { '...' + $fp.Path.Substring($fp.Path.Length - 37) } else { $fp.Path }
    Write-KV $fLabel $fState $fColor
}

Write-Host ''
$elapsed = [Math]::Round(((Get-Date) - $scriptStart).TotalSeconds, 1)
$modeStr = if ($Remove) { 'Remove mode' } else { 'Read-only' }
Write-Host "  Done in ${elapsed}s  |  $currentUser  |  $modeStr" -ForegroundColor DarkGray
Write-Host ''
