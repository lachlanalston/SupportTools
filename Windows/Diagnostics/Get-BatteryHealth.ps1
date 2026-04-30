<#
.SYNOPSIS
    Checks battery health, capacity, cycle count, charge state, and adapter info.

.DESCRIPTION
    Collects all battery data silently first, then reasons across findings to surface
    actionable issues. Outputs a clean header, a FINDINGS block with interpreted results,
    and a compact DETAIL block for raw reference.
    Designed to fit in one ticket note or terminal screenshot.

.EXAMPLE
    .\Get-BatteryHealth.ps1

.NOTES
    Author:  Lachlan Alston
    Version: v1
    Updated: 2026-04-30
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

# ── Header fields ──────────────────────────────────────────
$computerName = $env:COMPUTERNAME

try {
    $cs          = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    $rawUser     = $cs.UserName
    $currentUser = if ($rawUser) { $rawUser.Split('\')[-1] } else { '(unknown)' }
    $model       = $cs.Model
} catch { $currentUser = '(unknown)'; $model = '(unknown)' }

try { $serial = (Get-CimInstance Win32_BIOS -ErrorAction Stop).SerialNumber.Trim() } catch { $serial = '(unknown)' }

try {
    $os        = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $osShort   = $os.Caption -replace 'Microsoft ', '' -replace ' Professional', ' Pro' -replace ' Enterprise', ' Ent'
    $osBuild   = $os.BuildNumber
    $uptime    = (Get-Date) - $os.LastBootUpTime
    $uptimeStr = if ($uptime.Days -gt 0) { "$($uptime.Days)d $($uptime.Hours)h" } else { "$($uptime.Hours)h $($uptime.Minutes)m" }
} catch { $osShort = '(unknown)'; $osBuild = '(unknown)'; $uptimeStr = '(unknown)' }

$runAt = Get-Date -Format 'yyyy-MM-dd HH:mm'

# ── Battery WMI data ───────────────────────────────────────
# root\WMI classes give raw capacity/cycle data; Win32_Battery gives charge % and run time
$battStatic = @(try { Get-WmiObject -Namespace 'root\WMI' -Class BatteryStaticData          -ErrorAction SilentlyContinue } catch {})
$battFull   = @(try { Get-WmiObject -Namespace 'root\WMI' -Class BatteryFullChargedCapacity  -ErrorAction SilentlyContinue } catch {})
$battStatus = @(try { Get-WmiObject -Namespace 'root\WMI' -Class BatteryStatus               -ErrorAction SilentlyContinue } catch {})
$battCycle  = @(try { Get-WmiObject -Namespace 'root\WMI' -Class BatteryCycleCount           -ErrorAction SilentlyContinue } catch {})
$win32Batts = @(try { Get-WmiObject -Class Win32_Battery                                     -ErrorAction SilentlyContinue } catch {})

$battCount = [Math]::Max($battStatic.Count, $win32Batts.Count)
$batteries = [System.Collections.Generic.List[hashtable]]::new()

for ($i = 0; $i -lt $battCount; $i++) {
    $static = if ($i -lt $battStatic.Count) { $battStatic[$i] } else { $null }
    $full   = if ($i -lt $battFull.Count)   { $battFull[$i]   } else { $null }
    $status = if ($i -lt $battStatus.Count) { $battStatus[$i] } else { $null }
    $cycle  = if ($i -lt $battCycle.Count)  { $battCycle[$i]  } else { $null }
    $win32  = if ($i -lt $win32Batts.Count) { $win32Batts[$i] } else { $null }

    $designCap = if ($static -and $static.DesignedCapacity   -gt 0) { [int]$static.DesignedCapacity   } else { $null }
    $fullCap   = if ($full   -and $full.FullChargedCapacity   -gt 0) { [int]$full.FullChargedCapacity   } else { $null }

    $healthPct = if ($designCap -and $fullCap) {
        $h = [int]($fullCap * 100 / $designCap)
        if ($h -ge 1 -and $h -le 105) { $h } else { $null }
    } else { $null }

    $cycleCount  = if ($cycle -and $cycle.CycleCount -gt 0)                                                      { [int]$cycle.CycleCount                      } else { $null }
    $chargePct   = if ($win32 -and $win32.EstimatedChargeRemaining -ne $null)                                    { [int]$win32.EstimatedChargeRemaining         } else { $null }
    $timeRemMin  = if ($win32 -and $win32.EstimatedRunTime -ne $null -and [int]$win32.EstimatedRunTime -lt 71582) { [int]$win32.EstimatedRunTime                 } else { $null }

    $isCharging  = if ($status) { [bool]$status.Charging    } else { $false }
    $acOnline    = if ($status) { [bool]$status.PowerOnline } else { $false }
    $chargeRateW = if ($status -and $status.ChargeRate -gt 0) { [Math]::Round($status.ChargeRate / 1000.0, 1) } else { $null }

    # Assume fully charged when AC is on but charge % is unavailable — avoids false "not charging" findings
    $chargeState = if     ($isCharging)                                                            { 'Charging'                 }
                   elseif ($acOnline -and ($chargePct -eq $null -or $chargePct -ge 100))           { 'Fully charged'            }
                   elseif ($acOnline)                                                               { 'Plugged in (not charging)'}
                   else                                                                             { 'Discharging'              }

    $batteries.Add(@{
        Index       = $i
        DesignCap   = $designCap
        FullCap     = $fullCap
        HealthPct   = $healthPct
        CycleCount  = $cycleCount
        ChargePct   = $chargePct
        TimeRemMin  = $timeRemMin
        IsCharging  = $isCharging
        AcOnline    = $acOnline
        ChargeRateW = $chargeRateW
        ChargeState = $chargeState
    })
}

# ── powercfg /batteryreport — capacity trend and discharge history ──
# Written to a temp file, parsed, deleted immediately — no persistent change.
$brFlatDischarges = 0       # sessions where battery was at ≤5% capacity
$brCapHistory     = @()     # ordered array of {FullCap, DesignCap} from capacity history table
$brAvailable      = $false
$brReportPath     = Join-Path $env:TEMP "br_$(Get-Random).html"

try {
    $null = & powercfg /batteryreport /output "$brReportPath" 2>&1
    if (Test-Path $brReportPath) {
        $html        = Get-Content $brReportPath -Raw -ErrorAction Stop
        $brAvailable = $true

        # Capacity history — each row: date | full charge cap | design cap
        if ($html -match '(?is)Battery capacity history.*?<table[^>]*>(.*?)</table>') {
            [regex]::Matches($matches[1],
                '(?is)<tr>\s*<td>[^<]+</td>\s*<td>([\d,]+)\s*</td>\s*<td>([\d,]+)\s*</td>'
            ) | ForEach-Object {
                $fc = [int]($_.Groups[1].Value -replace ',')
                $dc = [int]($_.Groups[2].Value -replace ',')
                if ($fc -gt 100 -and $dc -gt 100) { $brCapHistory += @{ FullCap = $fc; DesignCap = $dc } }
            }
        }

        # Recent usage — Battery rows where CAPACITY REMAINING ≤ 5% = battery ran flat
        if ($html -match '(?is)Recent usage.*?<table[^>]*>(.*?)</table>') {
            $brFlatDischarges = ([regex]::Matches($matches[1],
                '(?is)<tr>\s*<td>[^<]+</td>\s*<td>[^<]+</td>\s*<td>Battery</td>\s*<td>([0-9]+)%</td>'
            ) | Where-Object { [int]$_.Groups[1].Value -le 5 }).Count
        }
    }
} catch {}
finally { Remove-Item $brReportPath -Force -ErrorAction SilentlyContinue }

# ─────────────────────────────────────────────────────────────
#  REASON
# ─────────────────────────────────────────────────────────────

if ($batteries.Count -gt 0) {
    foreach ($batt in $batteries) {
        $label = if ($batteries.Count -gt 1) { "Battery $($batt.Index + 1)" } else { "Battery" }

        if ($batt.HealthPct -ne $null) {
            if ($batt.HealthPct -lt 50) {
                Add-Finding 'CRIT' "$label capacity critically low ($($batt.HealthPct)%)" `
                    "Below 50% of design — replace immediately. Back up data; unexpected shutdowns likely."
            } elseif ($batt.HealthPct -lt 80) {
                Add-Finding 'WARN' "$label capacity degraded ($($batt.HealthPct)%)" `
                    "Below 80% — user will notice shorter run times. Plan replacement at next service window."
            }
        }

        if ($batt.AcOnline -and -not $batt.IsCharging -and $batt.ChargePct -ne $null -and $batt.ChargePct -lt 100) {
            Add-Finding 'WARN' "AC adapter connected but $($label.ToLower()) not charging ($($batt.ChargePct)%)" `
                "Try alternate port or adapter. Check OEM battery threshold setting in BIOS or vendor software."
        }
    }

    # Discharge sessions that ran the battery to ≤5% — direct evidence of battery exhaustion
    if ($brFlatDischarges -gt 0) {
        Add-Finding 'WARN' "$brFlatDischarges battery session(s) ran to ≤5% in recent usage history" `
            "Battery repeatedly exhausting — confirm user charges regularly or battery can no longer hold charge."
    }

    # Capacity trend — large drop between last two history readings signals accelerating wear
    if ($brCapHistory.Count -ge 2) {
        $drop    = $brCapHistory[-2].FullCap - $brCapHistory[-1].FullCap
        $dropPct = if ($brCapHistory[-1].DesignCap -gt 0) { [int]($drop * 100 / $brCapHistory[-1].DesignCap) } else { 0 }
        if ($dropPct -ge 5) {
            Add-Finding 'WARN' "Battery capacity dropped ${dropPct}% of design between last two report periods" `
                "Degradation accelerating — monitor closely and plan replacement before health hits 80%."
        }
    }
}

# ─────────────────────────────────────────────────────────────
#  OUTPUT
# ─────────────────────────────────────────────────────────────

try { $termWidth = $Host.UI.RawUI.WindowSize.Width } catch { $termWidth = 0 }
if ($termWidth -gt 0 -and $termWidth -lt 90) {
    Write-Host "  [WARN] Terminal is $termWidth cols wide — output may wrap. Recommended: 90+ cols." -ForegroundColor Yellow
}

# ── Box header ─────────────────────────────────────────────
$scriptTitle = 'BATTERY HEALTH'
$titleFill   = [Math]::Max(1, 64 - $scriptTitle.Length - 7)

Write-Host ''
Write-Host ("  ┌─ {0} {1}┐" -f $scriptTitle, ('─' * $titleFill)) -ForegroundColor Cyan
foreach ($line in @(
    "Host    $computerName",
    "User    $currentUser",
    "Model   $model",
    "S/N     $serial",
    "OS      $osShort  Build $osBuild",
    "Uptime  $uptimeStr",
    "Run     $runAt"
)) { Write-Host ("  │  {0,-58}│" -f $line) -ForegroundColor Cyan }
Write-Host ("  └{0}┘" -f ('─' * 60)) -ForegroundColor Cyan
Write-Host ''

# ── No battery — short exit ────────────────────────────────
if ($batteries.Count -eq 0) {
    Write-Divider 'FINDINGS'
    Write-Host '  [--] No battery detected — desktop or VM. No battery checks apply.' -ForegroundColor Cyan
    $elapsed = [Math]::Round(((Get-Date) - $scriptStart).TotalSeconds, 1)
    Write-Host ''
    Write-Host "  Done in ${elapsed}s  |  $currentUser" -ForegroundColor DarkGray
    Write-Host ''
    exit 0
}

# ── FINDINGS ───────────────────────────────────────────────
$findings = $findings | Sort-Object { switch ($_.Severity) { 'CRIT' { 0 } 'WARN' { 1 } default { 2 } } }
Write-Divider 'FINDINGS'

if ($findings.Count -eq 0) {
    Write-Host '  [OK] No issues found — battery looks healthy.' -ForegroundColor Green
} else {
    foreach ($f in $findings) {
        if     ($f.Severity -eq 'CRIT') { $icon = '[!!]'; $color = 'Red'    }
        elseif ($f.Severity -eq 'WARN') { $icon = '[!!]'; $color = 'Yellow' }
        else                            { $icon = '[--]'; $color = 'Cyan'   }
        Write-Host ("  {0} {1}" -f $icon, $f.Title) -ForegroundColor $color
        Write-Host ("       {0}" -f $f.Detail) -ForegroundColor DarkGray
    }
}

$issueCount = ($findings | Where-Object { $_.Severity -in 'CRIT', 'WARN' }).Count
$countLabel = "$issueCount issue(s) found"
$countFill  = [Math]::Max(1, 56 - $countLabel.Length)
Write-Host ''
Write-Host ("── {0} {1}" -f $countLabel, ('─' * $countFill)) -ForegroundColor $(if ($issueCount -gt 0) { 'Yellow' } else { 'Green' })

# ── DETAIL — BATTERY HEALTH (one section per battery) ─────
foreach ($batt in $batteries) {
    $sTitle = if ($batteries.Count -gt 1) { "DETAIL — BATTERY $($batt.Index + 1) HEALTH" } else { 'DETAIL — BATTERY HEALTH' }
    Write-Host ''
    Write-Divider $sTitle

    if ($batt.HealthPct -ne $null) {
        $condLabel = if ($batt.HealthPct -ge 80) { 'Normal'   } elseif ($batt.HealthPct -ge 50) { 'Degraded' } else { 'Critical' }
        $hpColor   = if ($batt.HealthPct -ge 80) { 'White'    } elseif ($batt.HealthPct -ge 50) { 'Yellow'   } else { 'Red'      }
        Write-KV 'Condition'    $condLabel  $hpColor
        Write-KV 'Capacity'     "$($batt.HealthPct)%" $hpColor
        if ($batt.FullCap -and $batt.DesignCap) {
            Write-KV 'Max / Design' "$($batt.FullCap) mWh / $($batt.DesignCap) mWh" 'DarkGray'
        }
    } else {
        Write-KV 'Condition' '(unavailable)' 'DarkGray'
        Write-KV 'Capacity'  '(unavailable)' 'DarkGray'
    }

    Write-KV 'Cycle Count' (if ($batt.CycleCount -ne $null) { "$($batt.CycleCount) cycles" } else { '(unavailable)' }) 'DarkGray'

    if ($brAvailable -and $brCapHistory.Count -ge 2) {
        $drop    = $brCapHistory[-2].FullCap - $brCapHistory[-1].FullCap
        $dropPct = if ($brCapHistory[-1].DesignCap -gt 0) { [int]($drop * 100 / $brCapHistory[-1].DesignCap) } else { 0 }
        $trendStr   = if ($drop -gt 0) { "-${dropPct}% last period" } elseif ($drop -lt 0) { "+${dropPct}% last period" } else { 'Stable' }
        $trendColor = if ($dropPct -ge 5) { 'Yellow' } else { 'DarkGray' }
        Write-KV 'Cap. Trend' $trendStr $trendColor
    } elseif ($brAvailable) {
        Write-KV 'Cap. Trend' '(insufficient history)' 'DarkGray'
    } else {
        Write-KV 'Cap. Trend' '(report unavailable)' 'DarkGray'
    }
}

# ── DETAIL — CHARGE STATE ──────────────────────────────────
$primary = $batteries[0]
Write-Host ''
Write-Divider 'DETAIL — CHARGE STATE'

Write-KV 'Charge' (if ($primary.ChargePct -ne $null) { "$($primary.ChargePct)%" } else { '(unknown)' })
Write-KV 'State'  $primary.ChargeState

if ($primary.ChargeState -eq 'Discharging') {
    if ($primary.TimeRemMin -ne $null) {
        $h = [Math]::Floor($primary.TimeRemMin / 60)
        $m = $primary.TimeRemMin % 60
        Write-KV 'Time Remaining' "${h}h ${m}m" 'DarkGray'
    } else {
        Write-KV 'Time Remaining' '(calculating)' 'DarkGray'
    }
}

if ($primary.AcOnline) {
    $adapterStr = 'Connected'
    if ($primary.ChargeRateW) { $adapterStr += " ($($primary.ChargeRateW)W)" }
    Write-KV 'Adapter' $adapterStr
} else {
    Write-KV 'Adapter' 'Not connected' 'DarkGray'
}

if ($brAvailable) {
    $flatColor = if ($brFlatDischarges -gt 0) { 'Yellow' } else { 'DarkGray' }
    Write-KV 'Flat Discharges' (if ($brFlatDischarges -gt 0) { "$brFlatDischarges in recent history" } else { 'None detected' }) $flatColor
} else {
    Write-KV 'Flat Discharges' '(report unavailable)' 'DarkGray'
}

$elapsed = [Math]::Round(((Get-Date) - $scriptStart).TotalSeconds, 1)
Write-Host ''
Write-Host "  Done in ${elapsed}s  |  $currentUser" -ForegroundColor DarkGray
Write-Host ''
