<#
.SYNOPSIS
    Checks the Windows security baseline: Secure Boot, TPM, Fast Startup, and Firewall profiles.

.DESCRIPTION
    Collects all security baseline data silently first, then reasons across the findings
    to surface actionable issues. Outputs a clean header, a FINDINGS block with
    interpreted results, and a compact DETAIL block for raw reference.
    Designed to fit in one ticket note or terminal screenshot.

.EXAMPLE
    .\Get-SecurityBaseline.ps1

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

# Secure Boot
$secureBootEnabled   = $false
$secureBootSupported = $true
try {
    $secureBootEnabled = [bool](Confirm-SecureBootUEFI -ErrorAction Stop)
} catch [System.InvalidOperationException] {
    $secureBootSupported = $false
} catch {
    $secureBootSupported = $false
}

# TPM
$tpmPresent  = $false
$tpmReady    = $false
$tpmVersion  = '(unknown)'
try {
    $tpm        = Get-Tpm -ErrorAction Stop
    $tpmPresent = $tpm.TpmPresent
    $tpmReady   = $tpm.TpmReady
    if ($tpmPresent) {
        $specVer = $tpm.SpecVersion
        if (-not $specVer) {
            $tpmCim  = Get-CimInstance -Namespace 'Root\CIMv2\Security\MicrosoftTpm' `
                           -ClassName Win32_Tpm -ErrorAction SilentlyContinue
            $specVer = if ($tpmCim) { $tpmCim.SpecVersion } else { '' }
        }
        $tpmVersion = if ($specVer) { $specVer.Trim() } else { '(unreadable)' }
    }
} catch { }

# Fast Startup (HiberbootEnabled = 0 means disabled)
$fastStartupEnabled = $false
$fastStartupKnown   = $false
try {
    $regVal = Get-ItemProperty `
        -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' `
        -Name 'HiberbootEnabled' -ErrorAction Stop
    $fastStartupKnown   = $true
    $fastStartupEnabled = ($regVal.HiberbootEnabled -ne 0)
} catch { }

# Windows Defender Firewall profiles
$fwDomain  = '(unknown)'
$fwPrivate = '(unknown)'
$fwPublic  = '(unknown)'
$fwDomainOff  = $false
$fwPrivateOff = $false
$fwPublicOff  = $false
try {
    $profiles = Get-NetFirewallProfile -ErrorAction Stop
    foreach ($p in $profiles) {
        switch ($p.Name) {
            'Domain'  { $fwDomain  = $p.Enabled.ToString(); $fwDomainOff  = (-not $p.Enabled) }
            'Private' { $fwPrivate = $p.Enabled.ToString(); $fwPrivateOff = (-not $p.Enabled) }
            'Public'  { $fwPublic  = $p.Enabled.ToString(); $fwPublicOff  = (-not $p.Enabled) }
        }
    }
} catch { }

# ─────────────────────────────────────────────────────────────
#  REASON
# ─────────────────────────────────────────────────────────────

# Secure Boot
if (-not $secureBootSupported) {
    Add-Finding 'WARN' 'Secure Boot not supported — legacy BIOS detected' `
        "UEFI with Secure Boot is required for Windows 11 and modern security standards."
} elseif (-not $secureBootEnabled) {
    Add-Finding 'CRIT' 'Secure Boot is disabled' `
        "Enable Secure Boot in BIOS/UEFI firmware settings. Required for Windows 11 compliance."
}

# TPM
if (-not $tpmPresent) {
    Add-Finding 'WARN' 'TPM chip not detected' `
        "Enable TPM in BIOS/UEFI settings. Required for BitLocker and Windows Hello."
} elseif (-not $tpmReady) {
    Add-Finding 'WARN' 'TPM is present but not ready' `
        "Clear and re-initialize TPM via Settings → Windows Security → Device Security → Security processor details."
}

# Fast Startup
if ($fastStartupKnown -and $fastStartupEnabled) {
    Add-Finding 'WARN' 'Fast Startup is enabled' `
        "Disable via Control Panel → Power Options → Choose what the power buttons do → uncheck 'Turn on fast startup'."
}

# Firewall
$disabledProfiles = @(
    if ($fwDomainOff)  { 'Domain' }
    if ($fwPrivateOff) { 'Private' }
    if ($fwPublicOff)  { 'Public' }
)
if ($disabledProfiles.Count -gt 0) {
    Add-Finding 'CRIT' "Windows Firewall disabled on: $($disabledProfiles -join ', ') profile(s)" `
        "Re-enable via: Set-NetFirewallProfile -Profile $($disabledProfiles -join ',') -Enabled True"
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
Write-Host '  ┌─ SECURITY BASELINE ────────────────────────────────────┐' -ForegroundColor Cyan
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
    Write-Host '  [OK] Security baseline checks all passed.' -ForegroundColor Green
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

$sbLabel  = if (-not $secureBootSupported) { 'Not supported (legacy BIOS)' } `
            elseif ($secureBootEnabled)     { 'Enabled' } else { 'DISABLED' }
$sbColor  = if ($secureBootEnabled) { 'White' } else { 'Red' }

$tpmLabel = if (-not $tpmPresent) { 'Not detected' } `
            elseif (-not $tpmReady) { "Present ($tpmVersion) — NOT READY" } `
            else { "Present ($tpmVersion) — Ready" }
$tpmColor = if ($tpmPresent -and $tpmReady) { 'White' } else { 'Yellow' }

$fsLabel  = if ($fastStartupKnown) { if ($fastStartupEnabled) { 'ENABLED (should be disabled)' } else { 'Disabled' } } `
            else { '(unknown)' }
$fsColor  = if ($fastStartupEnabled) { 'Yellow' } else { 'White' }

$fwDColor = if ($fwDomainOff)  { 'Red' } else { 'White' }
$fwPColor = if ($fwPrivateOff) { 'Red' } else { 'White' }
$fwUColor = if ($fwPublicOff)  { 'Red' } else { 'White' }

Write-KV 'Secure Boot'   $sbLabel  $sbColor
Write-KV 'TPM'           $tpmLabel $tpmColor
Write-KV 'Fast Startup'  $fsLabel  $fsColor
Write-Host ''
Write-KV 'FW Domain'     $fwDomain  $fwDColor
Write-KV 'FW Private'    $fwPrivate $fwPColor
Write-KV 'FW Public'     $fwPublic  $fwUColor

Write-Host ''
$elapsed = [Math]::Round(((Get-Date) - $scriptStart).TotalSeconds, 1)
Write-Host "  Done in ${elapsed}s  |  $currentUser" -ForegroundColor DarkGray
Write-Host ''
