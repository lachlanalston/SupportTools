<#
.SYNOPSIS
    Checks if the endpoint meets Windows 11 hardware requirements.

.DESCRIPTION
    Collects all Windows 11 readiness data silently first, then reasons across the findings
    to surface actionable issues. Outputs a clean header, a FINDINGS block with
    interpreted results, and a compact DETAIL block for raw reference.
    Designed to fit in one ticket note or terminal screenshot.

.EXAMPLE
    .\Get-Win11Readiness.ps1

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

# TPM
$tpmPresent  = $false
$tpmVersion  = '(unknown)'
$tpmIs20     = $false
try {
    $tpm = Get-Tpm -ErrorAction Stop
    $tpmPresent = $tpm.TpmPresent
    if ($tpmPresent) {
        $specVer = $tpm.SpecVersion
        if (-not $specVer) {
            # Fallback via CIM
            $tpmCim  = Get-CimInstance -Namespace 'Root\CIMv2\Security\MicrosoftTpm' `
                           -ClassName Win32_Tpm -ErrorAction SilentlyContinue
            $specVer = if ($tpmCim) { $tpmCim.SpecVersion } else { '' }
        }
        $tpmVersion = if ($specVer) { $specVer.Trim() } else { '(unreadable)' }
        $tpmIs20    = ($tpmVersion -match '2\.0')
    }
} catch { }

# Secure Boot
$secureBoot        = $false
$secureBootSupported = $true
try {
    $secureBoot = Confirm-SecureBootUEFI -ErrorAction Stop
} catch {
    $secureBootSupported = $false
}

# CPU
$cpuName     = '(unknown)'
$cpuMfr      = '(unknown)'
$cpuApproved = $false   # advisory — based on name regex only
try {
    $cpu     = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
    $cpuName = $cpu.Name.Trim()
    $cpuMfr  = $cpu.Manufacturer

    # Intel 8th Gen+ (i3/i5/i7/i9 starting 8xxx, 10xxx, 11xxx, 12xxx, 13xxx, 14xxx...)
    $intelOK  = $cpuName -match 'Intel.*Core.*i[3579]-([89]\d{2,}|1[0-9]\d{3,})'
    # AMD Ryzen 2000 series and above, plus Threadripper/EPYC (generally supported)
    $amdOK    = $cpuName -match 'AMD Ryzen [2-9]\d{3,}' -or $cpuName -match 'AMD Ryzen \d+ [2-9]'
    $cpuApproved = $intelOK -or $amdOK
} catch { }

# RAM
$ramGB = 0
try {
    $ramGB = [Math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
} catch { }

# Disk — C: free space (minimum 64 GB for upgrade)
$cDriveFreeGB  = 0
$cDriveTotalGB = 0
try {
    $cDisk         = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
    $cDriveFreeGB  = [Math]::Round($cDisk.FreeSpace / 1GB, 1)
    $cDriveTotalGB = [Math]::Round($cDisk.Size / 1GB, 1)
} catch { }

# Already on Windows 11?
$alreadyWin11 = $osBuild -ge 22000

# ─────────────────────────────────────────────────────────────
#  REASON
# ─────────────────────────────────────────────────────────────

if ($alreadyWin11) {
    Add-Finding 'INFO' 'Already running Windows 11' `
        "OS build $osBuild is Windows 11 — no upgrade action needed."
} else {
    if (-not $tpmPresent) {
        Add-Finding 'CRIT' 'TPM not detected' `
            "Enable TPM in BIOS/UEFI settings. If hardware lacks TPM chip, device is not upgradeable."
    } elseif (-not $tpmIs20) {
        Add-Finding 'CRIT' "TPM present but not version 2.0 (found: $tpmVersion)" `
            "Upgrade TPM firmware in BIOS if available, or enable TPM 2.0 mode in UEFI. Device may not be upgradeable."
    }

    if (-not $secureBootSupported) {
        Add-Finding 'CRIT' 'Secure Boot not supported on this hardware' `
            "UEFI Secure Boot is required for Windows 11 — legacy BIOS systems cannot be upgraded."
    } elseif (-not $secureBoot) {
        Add-Finding 'CRIT' 'Secure Boot is disabled' `
            "Enable Secure Boot in BIOS/UEFI firmware settings before upgrading."
    }

    if ($ramGB -gt 0 -and $ramGB -lt 4) {
        Add-Finding 'CRIT' "RAM is $ramGB GB — minimum 4 GB required" `
            "Install additional RAM before attempting the Windows 11 upgrade."
    }

    if ($cDriveFreeGB -gt 0 -and $cDriveFreeGB -lt 64) {
        Add-Finding 'CRIT' "C: has $cDriveFreeGB GB free — 64 GB minimum required for upgrade" `
            "Free up disk space or expand C: before running the Windows 11 upgrade."
    }

    if (-not $cpuApproved) {
        Add-Finding 'WARN' 'CPU may not meet Windows 11 requirements' `
            "Verify against the official Microsoft CPU list at aka.ms/CPUlist before upgrading."
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
Write-Host '  ┌─ WINDOWS 11 READINESS ─────────────────────────────────┐' -ForegroundColor Cyan
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
    Write-Host '  [OK] All Windows 11 requirements met — device is ready to upgrade.' -ForegroundColor Green
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

$tpmLabel  = if ($tpmPresent) { "Present  Version: $tpmVersion" } else { 'Not detected' }
$tpmColor  = if ($tpmIs20) { 'White' } elseif ($tpmPresent) { 'Yellow' } else { 'Red' }
$sbLabel   = if (-not $secureBootSupported) { 'Not supported' } elseif ($secureBoot) { 'Enabled' } else { 'Disabled' }
$sbColor   = if ($secureBoot) { 'White' } else { 'Red' }
$ramColor  = if ($ramGB -ge 4) { 'White' } else { 'Red' }
$diskColor = if ($cDriveFreeGB -ge 64) { 'White' } else { 'Red' }
$cpuColor  = if ($cpuApproved) { 'White' } else { 'Yellow' }

Write-KV 'TPM'          $tpmLabel $tpmColor
Write-KV 'Secure Boot'  $sbLabel  $sbColor
Write-KV 'CPU'          $cpuName  $cpuColor
Write-KV 'RAM'          "$ramGB GB" $ramColor
Write-KV 'C: free'      "$cDriveFreeGB GB of $cDriveTotalGB GB" $diskColor
Write-Host ''
Write-Host '       Tip: CPU check is name-based — verify against aka.ms/CPUlist for certainty.' `
    -ForegroundColor DarkGray

Write-Host ''
$elapsed = [Math]::Round(((Get-Date) - $scriptStart).TotalSeconds, 1)
Write-Host "  Done in ${elapsed}s  |  $currentUser" -ForegroundColor DarkGray
Write-Host ''
