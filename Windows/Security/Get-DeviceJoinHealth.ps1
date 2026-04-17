<#
.SYNOPSIS
    Checks device join health — Entra ID, domain, hybrid, PRT, cert, and MDM state.

.DESCRIPTION
    Collects all join and identity data silently first, then reasons across the findings
    to surface actionable issues. Outputs a clean header, a FINDINGS block with
    interpreted results, and a compact DETAIL block for raw reference.
    Designed to fit in one ticket note or terminal screenshot.

.EXAMPLE
    .\Get-DeviceJoinHealth.ps1

.NOTES
    Author:  Lachlan Alston
    Version: v1
    Updated: 2026-04-17
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

try {
    $cs          = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    $rawUser     = $cs.UserName
    $currentUser = if ($rawUser) { $rawUser.Split('\')[-1] } else { '(unknown)' }
    $model       = if ($cs.Model) { $cs.Model } else { '(unknown)' }
} catch {
    $currentUser = '(unknown)'; $model = '(unknown)'
}

try { $serial = (Get-CimInstance Win32_BIOS -ErrorAction Stop).SerialNumber } catch { $serial = '(unknown)' }

try {
    $os        = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $osCaption = $os.Caption -replace 'Microsoft Windows', 'Windows' -replace 'Professional', 'Pro'
    $osBuild   = $os.BuildNumber
    $uptime    = (Get-Date) - $os.LastBootUpTime
    $uptimeStr = if ($uptime.Days -gt 0) { "$($uptime.Days)d $($uptime.Hours)h" } else { "$($uptime.Hours)h $($uptime.Minutes)m" }
} catch {
    $osCaption = '(unknown)'; $osBuild = '(unknown)'; $uptimeStr = '(unknown)'
}

# dsregcmd — primary data source
$dsregRaw    = @(& dsregcmd /status 2>&1)
$dsregData   = @{}
$dsregErrors = [System.Collections.Generic.List[string]]::new()
$inDiag      = $false

foreach ($line in $dsregRaw) {
    if ($line -match '\|\s*Diagnostic') { $inDiag = $true }
    if ($inDiag -and $line -match 'Error\s*:') { $dsregErrors.Add($line.Trim()); continue }
    if ($line -match '^\s+([^:\|+\-\s][^:]+?)\s*:\s*(.+)$') {
        $key = $matches[1].Trim(); $val = $matches[2].Trim()
        if (-not $dsregData.ContainsKey($key)) { $dsregData[$key] = $val }
    }
}

function Get-Dreg { param([string]$K, [string]$D = '(unknown)')
    if ($dsregData.ContainsKey($K)) { return $dsregData[$K] }; return $D
}

# Join state
$aadJoined    = (Get-Dreg 'AzureAdJoined') -eq 'YES'
$domainJoined = (Get-Dreg 'DomainJoined') -eq 'YES'
$wpJoined     = (Get-Dreg 'WorkplaceJoined') -eq 'YES'

$joinType = if ($aadJoined -and $domainJoined) { 'Hybrid' }
            elseif ($aadJoined)                  { 'Entra ID' }
            elseif ($domainJoined)               { 'Domain Only' }
            elseif ($wpJoined)                   { 'Workplace Registered' }
            else                                 { 'Not Joined' }

$deviceId   = Get-Dreg 'DeviceId'
$tenantName = Get-Dreg 'TenantName'
$tenantId   = Get-Dreg 'TenantId'

$domainName = Get-Dreg 'DomainName' ''
if (-not $domainName) {
    try { $domainName = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).Domain } catch { }
}

# PRT
$prtPresent       = (Get-Dreg 'AzureAdPrt') -eq 'YES'
$prtUpdateStr     = Get-Dreg 'AzureAdPrtUpdateTime' ''
$prtExpiryStr     = Get-Dreg 'AzureAdPrtExpiryTime' ''
$prtAge           = $null
$prtExpired       = $false
$prtUpdateDisplay = '(unknown)'
$prtExpiryDisplay = '(unknown)'
$prtAgeStr        = '(unknown)'

try {
    if ($prtUpdateStr -and $prtUpdateStr -notin '(unknown)', '') {
        $prtUpdate        = [datetime]::Parse($prtUpdateStr.Replace(' UTC', '').Trim(), [System.Globalization.CultureInfo]::InvariantCulture)
        $prtAge           = (Get-Date).ToUniversalTime() - $prtUpdate.ToUniversalTime()
        $prtUpdateDisplay = $prtUpdate.ToString('yyyy-MM-dd HH:mm') + ' UTC'
        $prtAgeStr        = if ($prtAge.TotalHours -ge 24) { "$([int]$prtAge.TotalDays)d $($prtAge.Hours)h" }
                            elseif ($prtAge.TotalMinutes -ge 60) { "$($prtAge.Hours)h $($prtAge.Minutes)m" }
                            else { "$($prtAge.Minutes)m" }
    }
} catch { }

try {
    if ($prtExpiryStr -and $prtExpiryStr -notin '(unknown)', '') {
        $prtExpiryDt      = [datetime]::Parse($prtExpiryStr.Replace(' UTC', '').Trim(), [System.Globalization.CultureInfo]::InvariantCulture)
        $prtExpired       = (Get-Date).ToUniversalTime() -gt $prtExpiryDt.ToUniversalTime()
        $prtExpiryDisplay = $prtExpiryDt.ToString('yyyy-MM-dd HH:mm') + ' UTC'
    }
} catch { }

# Device certificate
$devCert        = $null
$certThumbprint = '(none)'
$certExpiryStr  = '(none)'
$certDaysLeft   = $null

try {
    $devCert = Get-ChildItem 'Cert:\LocalMachine\My' -ErrorAction Stop |
               Where-Object { $_.Subject -match 'MS-Organization-Access' } |
               Sort-Object NotAfter -Descending |
               Select-Object -First 1
    if ($devCert) {
        $certThumbprint = $devCert.Thumbprint
        $certDaysLeft   = [int]($devCert.NotAfter - (Get-Date)).TotalDays
        $certExpiryStr  = $devCert.NotAfter.ToString('yyyy-MM-dd')
    }
} catch { }

# MDM enrollment
$mdmUrl      = Get-Dreg 'MdmUrl' ''
$mdmEnrolled = $mdmUrl -ne '' -and $mdmUrl -ne '(unknown)'
$mdmIsIntune = $mdmUrl -match 'microsoft' -or $mdmUrl -match 'intune'

# IME service
$imeInstalled = $false
$imeRunning   = $false
try {
    $imeSvc       = Get-Service 'IntuneManagementExtension' -ErrorAction Stop
    $imeInstalled = $true
    $imeRunning   = $imeSvc.Status -eq 'Running'
} catch { }

# Last MDM sync
$lastMdmSync    = $null
$mdmSyncAge     = $null
$lastMdmSyncStr = '(unknown)'
$mdmSyncAgeStr  = '(unknown)'

try {
    $enrollBase = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction Stop
    foreach ($key in $enrollBase) {
        $dmPath  = "$($key.PSPath)\DMClient\MS DM Server"
        $syncVal = (Get-ItemProperty $dmPath -Name 'LastSuccessfulSyncTime' -ErrorAction SilentlyContinue).LastSuccessfulSyncTime
        if ($syncVal) {
            $lastMdmSync    = [datetime]::Parse($syncVal, [System.Globalization.CultureInfo]::InvariantCulture)
            $mdmSyncAge     = (Get-Date) - $lastMdmSync
            $lastMdmSyncStr = $lastMdmSync.ToString('yyyy-MM-dd HH:mm')
            $mdmSyncAgeStr  = if ($mdmSyncAge.TotalHours -ge 24) { "$([int]$mdmSyncAge.TotalDays)d $($mdmSyncAge.Hours)h ago" }
                              else { "$([int]$mdmSyncAge.TotalHours)h $($mdmSyncAge.Minutes)m ago" }
            break
        }
    }
} catch { }

# Domain health (domain/hybrid only)
$netlogonRunning    = $false
$secureChannel      = $null
$dcReachable        = $null
$machAcctPwdAge     = $null
$machAcctPwdAgeStr  = '(requires RSAT)'

if ($domainJoined) {
    try {
        $netlogonSvc     = Get-Service 'Netlogon' -ErrorAction Stop
        $netlogonRunning = $netlogonSvc.Status -eq 'Running'
    } catch { }

    try { $secureChannel = Test-ComputerSecureChannel -ErrorAction Stop } catch { $secureChannel = $false }

    try {
        $dcReachable = [bool](Resolve-DnsName "_ldap._tcp.$domainName" -Type SRV -ErrorAction Stop | Select-Object -First 1)
    } catch { $dcReachable = $false }

    try {
        if (Get-Command Get-ADComputer -ErrorAction SilentlyContinue) {
            $adComp = Get-ADComputer $env:COMPUTERNAME -Properties PasswordLastSet -ErrorAction Stop
            if ($adComp.PasswordLastSet) {
                $machAcctPwdAge    = [int]((Get-Date) - $adComp.PasswordLastSet).TotalDays
                $machAcctPwdAgeStr = "$machAcctPwdAge days"
            }
        }
    } catch { }

    # Fallback: read LSA secret last-write time — works as SYSTEM without RSAT
    if ($null -eq $machAcctPwdAge) {
        try {
            $lsaKey = Get-Item 'HKLM:\SECURITY\Policy\Secrets\$MACHINE.ACC' -ErrorAction Stop
            $machAcctPwdAge    = [int]((Get-Date) - $lsaKey.LastWriteTime).TotalDays
            $machAcctPwdAgeStr = "$machAcctPwdAge days"
        } catch { }
    }
}

# Hybrid Kerberos + WHfB
$cloudTgt  = (Get-Dreg 'CloudTgt') -eq 'YES'
$onPremTgt = (Get-Dreg 'OnPremTgt') -eq 'YES'
$ngcSet    = (Get-Dreg 'NgcSet') -eq 'YES'

# ─────────────────────────────────────────────────────────────
#  REASON
# ─────────────────────────────────────────────────────────────

# Not joined at all
if ($joinType -eq 'Not Joined') {
    Add-Finding 'CRIT' 'Device is not joined to any directory' `
        'Enrol via Settings > Accounts > Access work or school, or re-run Autopilot / Intune enrolment.'
}

# Workplace registered only
if ($joinType -eq 'Workplace Registered') {
    Add-Finding 'WARN' 'Device is workplace registered only — not fully joined' `
        'Workplace registration does not satisfy Entra ID Joined Conditional Access policies — full Azure AD Join or Hybrid Join required.'
}

# Partial hybrid — domain joined but not synced to Entra ID
if ($domainJoined -and -not $aadJoined) {
    Add-Finding 'WARN' 'Device is domain joined but not synced to Entra ID (partial hybrid)' `
        'Check Azure AD Connect sync health and confirm the device object exists in Entra ID — trigger a delta sync if missing.'
}

# PRT missing
if ($aadJoined -and -not $prtPresent) {
    Add-Finding 'CRIT' 'Primary Refresh Token (PRT) is missing' `
        'Sign the user out and back in — if issue persists, run dsregcmd /forcerecovery or re-join the device to Entra ID.'
}

# PRT expired
if ($aadJoined -and $prtPresent -and $prtExpired) {
    Add-Finding 'CRIT' 'Primary Refresh Token (PRT) has expired' `
        'Sign the user out and back in to force a refresh — if issue persists, check connectivity to login.microsoftonline.com.'
}

# PRT stale (>4 hours, not expired)
if ($aadJoined -and $prtPresent -and -not $prtExpired -and $null -ne $prtAge -and $prtAge.TotalHours -gt 4) {
    Add-Finding 'WARN' "PRT has not refreshed in $prtAgeStr — SSO and Conditional Access may be affected" `
        'Ensure the device can reach login.microsoftonline.com — sign the user out and back in if issue persists.'
}

# Device cert missing
if ($aadJoined -and -not $devCert) {
    Add-Finding 'CRIT' 'MS-Organization-Access device certificate is missing' `
        'Required for Entra ID join health — re-join the device via dsregcmd /leave then dsregcmd /join to regenerate.'
}

# Device cert expiring within 30 days
if ($null -ne $certDaysLeft -and $certDaysLeft -gt 0 -and $certDaysLeft -le 30) {
    Add-Finding 'WARN' "Device certificate expires in $certDaysLeft day(s) ($certExpiryStr)" `
        'Certificate should auto-renew — if not, re-join the device or check the certificate auto-enrolment policy in Intune.'
}

# Device cert expired
if ($null -ne $certDaysLeft -and $certDaysLeft -le 0) {
    Add-Finding 'CRIT' "Device certificate has expired ($certExpiryStr)" `
        'Re-join the device to Entra ID to regenerate the certificate — Settings > Accounts > Access work or school > Disconnect, then re-join.'
}

# Not MDM enrolled
if ($aadJoined -and -not $mdmEnrolled) {
    Add-Finding 'WARN' 'Device is not enrolled in MDM' `
        'Enrol via Settings > Accounts > Access work or school > Connect, or check the Intune automatic enrolment policy for this tenant.'
}

# MDM URL not Intune
if ($mdmEnrolled -and -not $mdmIsIntune) {
    Add-Finding 'WARN' "MDM URL does not appear to be Intune ($mdmUrl)" `
        'Device may be enrolled in a different MDM — verify intended MDM provider and re-enrol if required.'
}

# IME service not running (only if Intune enrolled and service installed)
if ($mdmEnrolled -and $mdmIsIntune -and $imeInstalled -and -not $imeRunning) {
    Add-Finding 'WARN' 'Intune Management Extension (IME) service is not running' `
        'Start via: Start-Service IntuneManagementExtension — if it fails, check Event Viewer > Application for errors.'
}

# MDM sync stale (>8 hours)
if ($mdmEnrolled -and $null -ne $mdmSyncAge -and $mdmSyncAge.TotalHours -gt 8) {
    Add-Finding 'WARN' "Last MDM sync was $mdmSyncAgeStr — policies may be stale" `
        'Trigger a manual sync via Settings > Accounts > Access work or school > Info > Sync, or restart the IME service.'
}

# Netlogon not running
if ($domainJoined -and -not $netlogonRunning) {
    Add-Finding 'CRIT' 'Netlogon service is not running' `
        'Start via: Start-Service Netlogon — if it fails, check Event Viewer > System for errors and verify DC connectivity.'
}

# Secure channel broken (only flag if Netlogon is running — otherwise Netlogon finding covers it)
if ($domainJoined -and $netlogonRunning -and $secureChannel -eq $false) {
    Add-Finding 'CRIT' 'Domain secure channel is broken' `
        'Run: Test-ComputerSecureChannel -Repair (requires domain admin creds) — or rejoin the device to the domain.'
}

# DC unreachable
if ($domainJoined -and $dcReachable -eq $false) {
    Add-Finding 'WARN' "Domain controller unreachable for $domainName" `
        'Check DNS resolution and network path to the domain — run Get-TimeSyncHealth if Kerberos or time sync is suspected.'
}

# Machine account password age
if ($domainJoined -and $null -ne $machAcctPwdAge -and $machAcctPwdAge -gt 45) {
    Add-Finding 'WARN' "Machine account password is $machAcctPwdAge days old (expected ≤30)" `
        'Auto-rotation may have stalled — run: Test-ComputerSecureChannel -Repair to force a reset, then verify in AD.'
}

# Hybrid Kerberos tickets
if ($joinType -eq 'Hybrid' -and -not $cloudTgt) {
    Add-Finding 'WARN' 'Cloud Kerberos ticket is unavailable' `
        'Required for cloud resource access with hybrid identity — sign the user out and back in, or check the Entra ID Kerberos server object in AD.'
}

if ($joinType -eq 'Hybrid' -and -not $onPremTgt) {
    Add-Finding 'WARN' 'On-premises Kerberos ticket is unavailable' `
        'Required for on-prem resource access — check DC connectivity and confirm Netlogon is running.'
}

# WHfB not configured (INFO)
if ($aadJoined -and -not $ngcSet) {
    Add-Finding 'INFO' 'Windows Hello for Business PIN is not configured' `
        'WHfB provides phishing-resistant auth and supports PRT refresh — enable via Intune policy or Settings > Sign-in options.'
}

# dsregcmd diagnostic errors (INFO)
if ($dsregErrors.Count -gt 0) {
    $errSummary = ($dsregErrors | Select-Object -First 2) -join ' | '
    Add-Finding 'INFO' "dsregcmd reported $($dsregErrors.Count) diagnostic error(s)" `
        "Codes: $errSummary — run dsregcmd /status manually for full output."
}

# ─────────────────────────────────────────────────────────────
#  OUTPUT
# ─────────────────────────────────────────────────────────────

$termWidth = $Host.UI.RawUI.WindowSize.Width
if ($termWidth -gt 0 -and $termWidth -lt 90) {
    Write-Host "  [WARN] Terminal is $termWidth cols wide — output may wrap. Recommended: 90+ cols." -ForegroundColor Yellow
}

$runAt = Get-Date -Format 'yyyy-MM-dd HH:mm'

Write-Host ""
Write-Host ("  ┌─ DEVICE JOIN HEALTH " + ('─' * 39) + "┐") -ForegroundColor Cyan
Write-Host ("  │  {0,-58}│" -f "Host    $env:COMPUTERNAME") -ForegroundColor Cyan
Write-Host ("  │  {0,-58}│" -f "User    $currentUser") -ForegroundColor Cyan
Write-Host ("  │  {0,-58}│" -f "Model   $model") -ForegroundColor Cyan
Write-Host ("  │  {0,-58}│" -f "S/N     $serial") -ForegroundColor Cyan
Write-Host ("  │  {0,-58}│" -f "OS      $osCaption  Build $osBuild") -ForegroundColor Cyan
Write-Host ("  │  {0,-58}│" -f "Uptime  $uptimeStr") -ForegroundColor Cyan
Write-Host ("  │  {0,-58}│" -f "Run     $runAt") -ForegroundColor Cyan
Write-Host ("  └" + ('─' * 60) + "┘") -ForegroundColor Cyan
Write-Host ""

# Findings — CRIT → WARN → INFO
$findings = $findings | Sort-Object { switch ($_.Severity) { 'CRIT' { 0 } 'WARN' { 1 } default { 2 } } }

Write-Divider 'FINDINGS'
if ($findings.Count -eq 0) {
    Write-Host "  [OK] No issues found — device join and identity look healthy." -ForegroundColor Green
} else {
    foreach ($f in $findings) {
        $icon  = if ($f.Severity -eq 'INFO') { '[--]' } else { '[!!]' }
        $color = switch ($f.Severity) { 'CRIT' { 'Red' } 'WARN' { 'Yellow' } default { 'Cyan' } }
        Write-Host "  $icon $($f.Title)" -ForegroundColor $color
        Write-Host "       $($f.Detail)" -ForegroundColor DarkGray
    }
}

$issueCount = ($findings | Where-Object { $_.Severity -in 'CRIT', 'WARN' }).Count
$countLabel = "$issueCount issue(s) found"
$countColor = if ($issueCount -gt 0) { 'Yellow' } else { 'Green' }
Write-Host ""
Write-Host "── $countLabel " -ForegroundColor $countColor -NoNewline
Write-Host ('─' * [Math]::Max(1, 56 - $countLabel.Length)) -ForegroundColor $countColor

# Detail — Join State
Write-Host ""
Write-Divider 'DETAIL — JOIN STATE'
$joinColor = switch ($joinType) { 'Not Joined' { 'Red' } 'Workplace Registered' { 'Yellow' } default { 'White' } }
Write-KV 'Join Type'   $joinType $joinColor
Write-KV 'Device ID'   $deviceId 'DarkGray'
Write-KV 'Tenant Name' $tenantName
Write-KV 'Tenant ID'   $tenantId 'DarkGray'

# Detail — Entra ID & PRT (Entra-joined devices only)
if ($aadJoined) {
    Write-Host ""
    Write-Divider 'DETAIL — ENTRA ID & PRT'
    if ($currentUser -eq '(unknown)') {
        Write-Host "  Note: No active user session detected — PRT data reflects last interactive session." -ForegroundColor DarkGray
    }
    Write-KV 'PRT Present'     $(if ($prtPresent) { 'Yes' } else { 'No' })    $(if (-not $prtPresent) { 'Red' } else { 'White' })
    Write-KV 'PRT Last Refresh' $prtUpdateDisplay
    Write-KV 'PRT Age'         $prtAgeStr $(if ($null -ne $prtAge -and $prtAge.TotalHours -gt 4) { 'Yellow' } else { 'White' })
    Write-KV 'PRT Expiry'      $prtExpiryDisplay $(if ($prtExpired) { 'Red' } else { 'White' })
    Write-KV 'Device Cert'     $(if ($devCert) { 'Present' } else { 'Missing' }) $(if (-not $devCert) { 'Red' } else { 'White' })
    $certColor = if ($null -ne $certDaysLeft -and $certDaysLeft -le 0) { 'Red' } elseif ($null -ne $certDaysLeft -and $certDaysLeft -le 30) { 'Yellow' } else { 'White' }
    Write-KV 'Cert Expiry'     $certExpiryStr $certColor
    Write-KV 'Cert Thumbprint' $certThumbprint 'DarkGray'
    Write-KV 'WHfB PIN'        $(if ($ngcSet) { 'Configured' } else { 'Not configured' }) $(if (-not $ngcSet) { 'DarkGray' } else { 'White' })
}

# Detail — MDM / Intune
Write-Host ""
Write-Divider 'DETAIL — MDM / INTUNE'
Write-KV 'Enrolled'    $(if ($mdmEnrolled) { 'Yes' } else { 'No' })             $(if (-not $mdmEnrolled) { 'Yellow' } else { 'White' })
Write-KV 'MDM URL'     $(if ($mdmUrl) { $mdmUrl } else { '(none)' })             $(if ($mdmEnrolled -and -not $mdmIsIntune) { 'Yellow' } else { 'DarkGray' })
$imeStr   = if (-not $imeInstalled) { 'Not installed' } elseif ($imeRunning) { 'Running' } else { 'Stopped' }
$imeColor = if ($imeInstalled -and -not $imeRunning) { 'Yellow' } else { 'White' }
Write-KV 'IME Service' $imeStr $imeColor
Write-KV 'Last Sync'   $lastMdmSyncStr $(if ($null -ne $mdmSyncAge -and $mdmSyncAge.TotalHours -gt 8) { 'Yellow' } else { 'White' })
Write-KV 'Sync Age'    $mdmSyncAgeStr  $(if ($null -ne $mdmSyncAge -and $mdmSyncAge.TotalHours -gt 8) { 'Yellow' } else { 'White' })

# Detail — Domain (domain/hybrid only)
if ($domainJoined) {
    Write-Host ""
    Write-Divider 'DETAIL — DOMAIN'
    Write-KV 'Domain'         $(if ($domainName) { $domainName } else { '(unknown)' })
    Write-KV 'Netlogon'       $(if ($netlogonRunning) { 'Running' } else { 'Stopped' })          $(if (-not $netlogonRunning) { 'Red' } else { 'White' })
    $scStr   = if ($null -eq $secureChannel) { '(unknown)' } elseif ($secureChannel) { 'Healthy' } else { 'Broken' }
    $scColor = if ($secureChannel -eq $false) { 'Red' } else { 'White' }
    Write-KV 'Secure Channel' $scStr $scColor
    $dcStr   = if ($null -eq $dcReachable) { '(unknown)' } elseif ($dcReachable) { 'Yes' } else { 'No' }
    $dcColor = if ($dcReachable -eq $false) { 'Yellow' } else { 'White' }
    Write-KV 'DC Reachable'   $dcStr $dcColor
    $pwdColor = if ($null -ne $machAcctPwdAge -and $machAcctPwdAge -gt 45) { 'Yellow' } elseif ($machAcctPwdAgeStr -eq '(requires RSAT)') { 'DarkGray' } else { 'White' }
    Write-KV 'Acct Pwd Age'   $machAcctPwdAgeStr $pwdColor

    if ($joinType -eq 'Hybrid') {
        Write-KV 'Cloud Kerberos'   $(if ($cloudTgt) { 'Available' } else { 'Unavailable' })  $(if (-not $cloudTgt)  { 'Yellow' } else { 'White' })
        Write-KV 'On-Prem Kerberos' $(if ($onPremTgt) { 'Available' } else { 'Unavailable' }) $(if (-not $onPremTgt) { 'Yellow' } else { 'White' })
    }
    Write-Host "  Tip: Run Get-TimeSyncHealth if Kerberos or DC auth issues are suspected." -ForegroundColor DarkGray
}

# Detail — dsregcmd errors (only shown when present)
if ($dsregErrors.Count -gt 0) {
    Write-Host ""
    Write-Divider 'DETAIL — DSREGCMD ERRORS'
    foreach ($err in $dsregErrors) {
        Write-Host "  $err" -ForegroundColor Yellow
    }
}

Write-Host ""
$elapsed = [Math]::Round(((Get-Date) - $scriptStart).TotalSeconds, 1)
Write-Host "  Done in ${elapsed}s  |  $currentUser" -ForegroundColor DarkGray
Write-Host ""
