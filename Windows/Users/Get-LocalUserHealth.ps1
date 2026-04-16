<#
.SYNOPSIS
    Reports local user accounts, their state, admin membership, and password settings.

.DESCRIPTION
    Collects all local user data silently first, then reasons across the findings
    to surface actionable issues. Outputs a clean header, a FINDINGS block with
    interpreted results, and a compact DETAIL block for raw reference.
    Designed to fit in one ticket note or terminal screenshot.

.PARAMETER Fix
    Applies changes to the target user specified by -Username:
    - If the user exists: enables the account, sets password to never expire,
      and adds to the local Administrators group.
    - If the user does not exist: requires -Password to create the account first,
      then applies the same configuration.

.PARAMETER Username
    The local user account name to target when using -Fix.

.PARAMETER Password
    The password for the account when -Fix creates a new user.
    Accepts a SecureString. If the user already exists, this parameter is ignored.

.EXAMPLE
    .\Get-LocalUserHealth.ps1

.EXAMPLE
    .\Get-LocalUserHealth.ps1 -Fix -Username "support"

.EXAMPLE
    $pw = Read-Host "Password" -AsSecureString
    .\Get-LocalUserHealth.ps1 -Fix -Username "support" -Password $pw

.NOTES
    Author:  Lachlan Alston
    Version: v1
    Updated: 2026-04-16
#>

[CmdletBinding()]
param(
    [switch]$Fix,
    [string]$Username,
    [securestring]$Password
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

# -Fix action: create/configure target user
$fixLog      = [System.Collections.Generic.List[string]]::new()
$fixAborted  = $false

if ($Fix) {
    if (-not $Username) {
        $fixAborted = $true
        $fixLog.Add('Fix aborted — -Username is required with -Fix.')
    } else {
        $userExists = $null -ne (Get-LocalUser -Name $Username -ErrorAction SilentlyContinue)

        if (-not $userExists) {
            if (-not $Password) {
                $fixAborted = $true
                $fixLog.Add("Fix aborted — user '$Username' does not exist and -Password was not supplied.")
            } else {
                try {
                    New-LocalUser -Name $Username -Password $Password -PasswordNeverExpires $true -ErrorAction Stop
                    $fixLog.Add("Created local user: $Username")
                    $userExists = $true
                } catch {
                    $fixAborted = $true
                    $fixLog.Add("Failed to create '$Username': $($_.Exception.Message)")
                }
            }
        }

        if ($userExists -and -not $fixAborted) {
            try { Enable-LocalUser -Name $Username -ErrorAction Stop; $fixLog.Add("Enabled: $Username") } `
            catch { $fixLog.Add("Enable failed: $($_.Exception.Message)") }

            try { Set-LocalUser -Name $Username -PasswordNeverExpires $true -AccountNeverExpires -ErrorAction Stop
                  $fixLog.Add("Set password never expires, account never expires.") } `
            catch { $fixLog.Add("Set-LocalUser failed: $($_.Exception.Message)") }

            try {
                $alreadyAdmin = (Get-LocalGroupMember -Group 'Administrators' -ErrorAction Stop |
                    Where-Object { $_.Name -match "\\$Username$" })
                if (-not $alreadyAdmin) {
                    Add-LocalGroupMember -Group 'Administrators' -Member $Username -ErrorAction Stop
                    $fixLog.Add("Added to Administrators group.")
                } else {
                    $fixLog.Add("Already a member of Administrators — no change.")
                }
            } catch { $fixLog.Add("Group membership update failed: $($_.Exception.Message)") }
        }
    }
}

# Read all local users
$userError = $false
$userRows  = @()
try {
    $adminMembers = @()
    try {
        $adminMembers = Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue |
                        ForEach-Object { $_.Name -replace '.*\\', '' }
    } catch { }

    $userRows = Get-LocalUser -ErrorAction Stop | ForEach-Object {
        [PSCustomObject]@{
            Name               = $_.Name
            Enabled            = $_.Enabled
            PasswordNeverExpires = $_.PasswordNeverExpires
            IsAdmin            = ($adminMembers -contains $_.Name)
            LastLogon          = if ($_.LastLogon) { $_.LastLogon.ToString('yyyy-MM-dd') } else { 'Never' }
        }
    }
} catch {
    $userError = $true
}

# ─────────────────────────────────────────────────────────────
#  REASON
# ─────────────────────────────────────────────────────────────

if ($fixAborted) {
    Add-Finding 'WARN' 'Fix action could not complete' `
        ($fixLog | Select-Object -Last 1)
}

if ($userError) {
    Add-Finding 'WARN' 'Could not query local user accounts' `
        "Get-LocalUser failed — check execution context has sufficient permissions."
} else {
    $enabledAdmins = @($userRows | Where-Object { $_.IsAdmin -and $_.Enabled })
    if ($enabledAdmins.Count -eq 0) {
        Add-Finding 'CRIT' 'No enabled local administrator accounts found' `
            "Run with -Fix -Username <name> to create or enable a local admin account."
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
Write-Host '  ┌─ LOCAL USER HEALTH ────────────────────────────────────┐' -ForegroundColor Cyan
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
        $color = if ($line -like '*failed*' -or $line -like '*aborted*') { 'Red' } else { 'Green' }
        Write-Host "  [>>] $line" -ForegroundColor $color
    }
    Write-Host ''
}

# FINDINGS
Write-Divider 'FINDINGS'

if ($findings.Count -eq 0) {
    Write-Host '  [OK] Local user accounts look healthy — at least one enabled admin found.' -ForegroundColor Green
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

if ($userError) {
    Write-Host '  Could not retrieve user list.' -ForegroundColor Red
} elseif ($userRows.Count -eq 0) {
    Write-Host '  No local user accounts found.' -ForegroundColor DarkGray
} else {
    Write-Host ("  {0,-20} {1,-8} {2,-7} {3,-11} {4}" -f 'Name', 'Enabled', 'Admin', 'Pw Expires', 'Last Logon') `
        -ForegroundColor DarkGray
    Write-Host ("  {0}" -f ('─' * 60)) -ForegroundColor DarkGray
    foreach ($u in $userRows | Sort-Object { -not $_.IsAdmin }, Name) {
        $pwExp  = if ($u.PasswordNeverExpires) { 'Never    ' } else { 'Yes      ' }
        $admin  = if ($u.IsAdmin) { 'Yes    ' } else { 'No     ' }
        $en     = if ($u.Enabled) { 'Yes     ' } else { 'No      ' }
        $color  = if ($u.IsAdmin -and $u.Enabled) { 'White' } elseif ($u.IsAdmin) { 'Yellow' } else { 'DarkGray' }
        Write-Host ("  {0,-20} {1,-8} {2,-7} {3,-11} {4}" -f $u.Name, $en, $admin, $pwExp, $u.LastLogon) `
            -ForegroundColor $color
    }
}

Write-Host ''
$elapsed = [Math]::Round(((Get-Date) - $scriptStart).TotalSeconds, 1)
$modeStr = if ($Fix) { 'Fix mode' } else { 'Read-only' }
Write-Host "  Done in ${elapsed}s  |  $currentUser  |  $modeStr" -ForegroundColor DarkGray
Write-Host ''
