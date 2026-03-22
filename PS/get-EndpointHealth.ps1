#Requires -Version 5.1
# Get-EndpointHealth.ps1
# MSP diagnostic tool — paste into a terminal during a remote session.

#region --- Elevation ---
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)) {

    Write-Host ""
    Write-Host "  ERROR: This script must be run as Administrator." -ForegroundColor Red
    Write-Host "  Right-click PowerShell and select 'Run as Administrator', then try again." -ForegroundColor Yellow
    Write-Host ""
    exit 1
}
#endregion

#region --- Layout ---
$colCheck  = 22
$colStatus = 10
$colValue  = 26
$colMsg    = 44
$width     = $colCheck + $colStatus + $colValue + $colMsg + 5
#endregion

#region --- Helpers ---
function Write-Divider ([string]$color = "DarkGray") {
    Write-Host ("-" * $width) -ForegroundColor $color
}

function Write-Row ($check, $status, $value, $message, $color) {
    $c = ([string]$check).PadRight($colCheck).Substring(0, $colCheck)
    $s = ([string]$status).PadRight($colStatus).Substring(0, $colStatus)
    $v = ([string]$value).PadRight($colValue).Substring(0, $colValue)
    $m = [string]$message
    $m = if ($m.Length -gt $colMsg) { $m.Substring(0, $colMsg - 3) + "..." } else { $m }
    Write-Host "  $c $s $v $m" -ForegroundColor $color
}

function Write-InfoRow ($lLabel, $lValue, $rLabel = "", $rValue = "") {
    $lLbl = ([string]$lLabel).PadRight(9).Substring(0, 9)
    $lVal = [string]$lValue
    $lVal = if ($lVal.Length -gt 34) { $lVal.Substring(0, 31) + "..." } else { $lVal.PadRight(34) }

    $left = "  $lLbl : $lVal"

    if ($rLabel) {
        $rLbl  = ([string]$rLabel).PadRight(9).Substring(0, 9)
        $right = "$rLbl : $([string]$rValue)"
    } else {
        $right = ""
    }

    Write-Host "$left$right" -ForegroundColor Gray
}
#endregion

#region --- Checks ---
function Get-UptimeStatus {
    $sysInfo = Get-CimInstance -ClassName Win32_OperatingSystem
    $elapsed = (Get-Date) - $sysInfo.LastBootUpTime
    $display = "$($elapsed.Days) days, $($elapsed.Hours) hrs, $($elapsed.Minutes) min"

    if ($elapsed.TotalHours -ge 48) {
        [PSCustomObject]@{ Status = "Warning"; Message = "Restart overdue — running for $($elapsed.Days) day(s)"; Value = $display; Color = "Yellow" }
    } else {
        [PSCustomObject]@{ Status = "Healthy"; Message = "Last restart within the past 48 hours"; Value = $display; Color = "Green" }
    }
}

function Get-DiskSpaceStatus {
    $disk    = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'"
    $pctFree = [math]::Round(($disk.FreeSpace / $disk.Size) * 100, 0)
    $gbFree  = [math]::Round($disk.FreeSpace / 1GB, 1)
    $gbTotal = [math]::Round($disk.Size / 1GB, 1)
    $display = "$pctFree% free ($gbFree GB of $gbTotal GB)"

    if ($pctFree -le 2) {
        [PSCustomObject]@{ Status = "Critical"; Message = "C: drive nearly full — immediate action required"; Value = $display; Color = "Red" }
    } elseif ($pctFree -le 5) {
        [PSCustomObject]@{ Status = "Warning";  Message = "C: drive running low — cleanup recommended"; Value = $display; Color = "Yellow" }
    } elseif ($pctFree -le 10) {
        [PSCustomObject]@{ Status = "Warning";  Message = "C: drive below 10% — monitor closely"; Value = $display; Color = "Yellow" }
    } else {
        [PSCustomObject]@{ Status = "Healthy";  Message = "C: drive has adequate free space"; Value = $display; Color = "Green" }
    }
}

function Get-CpuStatus {
    # Clock performance % reflects how fast the CPU is running relative to its base clock.
    # A result below 100% under high load indicates thermal or power throttling.
    $clockReadings       = [System.Collections.Generic.List[double]]::new()
    $utilizationReadings = [System.Collections.Generic.List[double]]::new()

    1..3 | ForEach-Object {
        $clockReadings.Add((Get-Counter "\Processor Information(_Total)\% Processor Performance").CounterSamples.CookedValue)
        $utilizationReadings.Add((Get-CimInstance -ClassName Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average)
        Start-Sleep -Seconds 1
    }

    $meanClock = [math]::Round(($clockReadings       | Measure-Object -Average).Average, 0)
    $meanUtil  = [math]::Round(($utilizationReadings | Measure-Object -Average).Average, 0)
    $display   = "load: $meanUtil%, clock: $meanClock%"

    if ($meanUtil -gt 80 -and $meanClock -lt 100) {
        [PSCustomObject]@{ Status = "Critical"; Message = "CPU throttled — high load but below base clock"; Value = $display; Color = "Red" }
    } elseif ($meanUtil -gt 80) {
        [PSCustomObject]@{ Status = "Warning";  Message = "CPU under sustained high load"; Value = $display; Color = "Yellow" }
    } else {
        [PSCustomObject]@{ Status = "Healthy";  Message = "CPU operating normally"; Value = $display; Color = "Green" }
    }
}

function Get-PowerProfileStatus {
    # Detect device type — Balanced is correct for laptops but not desktops
    # PCSystemType: 1 = Desktop, 2 = Mobile/Laptop
    $pcType     = (Get-CimInstance -ClassName Win32_ComputerSystem).PCSystemType
    $isMobile   = ($pcType -eq 2)

    $activePlan = Get-CimInstance -Namespace "root\cimv2\power" -ClassName Win32_PowerPlan `
                    -Filter "IsActive = True" -ErrorAction Stop

    if (-not $activePlan) {
        return [PSCustomObject]@{ Status = "Critical"; Message = "No active power plan found"; Value = "None"; Color = "Red" }
    }

    $planName = $activePlan.ElementName

    if ($planName -match "High performance|Ultimate Performance") {
        [PSCustomObject]@{ Status = "Healthy"; Message = "Power plan configured for maximum performance"; Value = $planName; Color = "Green" }
    } elseif ($isMobile -and $planName -match "Balanced") {
        [PSCustomObject]@{ Status = "Healthy"; Message = "Balanced plan appropriate for laptop"; Value = $planName; Color = "Green" }
    } else {
        [PSCustomObject]@{ Status = "Warning"; Message = "Power plan may restrict CPU performance"; Value = $planName; Color = "Yellow" }
    }
}

function Get-WindowsUpdatesStatus {
    $session  = [activator]::CreateInstance([type]::GetTypeFromProgID("Microsoft.Update.Session"))
    $searcher = $session.CreateUpdateSearcher()
    $pending  = $searcher.Search("IsInstalled=0 AND IsHidden=0")
    $count    = $pending.Updates.Count

    if ($count -gt 0) {
        [PSCustomObject]@{ Status = "Warning"; Message = "$count update(s) waiting to be installed"; Value = "$count pending"; Color = "Yellow" }
    } else {
        [PSCustomObject]@{ Status = "Healthy"; Message = "Windows is fully up to date"; Value = "Up to date"; Color = "Green" }
    }
}

function Get-RamStatus {
    $os      = Get-CimInstance -ClassName Win32_OperatingSystem
    $uptime  = (Get-Date) - $os.LastBootUpTime
    $totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    $freeGB  = [math]::Round($os.FreePhysicalMemory  / 1MB, 1)
    $freePct = [math]::Round(($os.FreePhysicalMemory / $os.TotalVisibleMemorySize) * 100)
    $value   = "$freeGB GB free of $totalGB GB"

    if ($uptime.TotalMinutes -lt 30) {
        return [PSCustomObject]@{ Status = "Unknown"; Message = "System just booted — RAM usage not yet representative"; Value = $value; Color = "Cyan" }
    }

    if ($freePct -le 10) {
        [PSCustomObject]@{ Status = "Critical"; Message = "Critically low RAM — $freePct% free"; Value = $value; Color = "Red" }
    } elseif ($freePct -le 20) {
        [PSCustomObject]@{ Status = "Warning";  Message = "Low RAM — $freePct% free"; Value = $value; Color = "Yellow" }
    } else {
        [PSCustomObject]@{ Status = "Healthy";  Message = "RAM usage normal — $freePct% free"; Value = $value; Color = "Green" }
    }
}

function Get-SmartDiskStatus {
    $disks = Get-PhysicalDisk | Where-Object { $_.MediaType -ne 'Unspecified' }

    if (-not $disks) {
        return [PSCustomObject]@{ Status = "Unknown"; Message = "No physical disks detected"; Value = "N/A"; Color = "Yellow" }
    }

    $results = foreach ($disk in $disks) {
        $rel = $disk | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
        [PSCustomObject]@{
            Name         = $disk.FriendlyName
            Health       = $disk.HealthStatus
            PowerOnHours = if ($rel) { $rel.PowerOnHours } else { $null }
        }
    }

    $newDisks    = $results | Where-Object { $null -ne $_.PowerOnHours -and $_.PowerOnHours -lt 100 }
    $matureDisks = $results | Where-Object { $null -eq $_.PowerOnHours -or $_.PowerOnHours -ge 100 }
    $unhealthy   = $matureDisks | Where-Object { $_.Health -ne 'Healthy' }

    if (@($results).Count -eq @($newDisks).Count) {
        [PSCustomObject]@{ Status = "Unknown";  Message = "Disk(s) too new for reliable SMART data (< 100 hrs)"; Value = "$(@($results).Count) disk(s)"; Color = "Cyan" }
    } elseif (@($unhealthy).Count -gt 0) {
        [PSCustomObject]@{ Status = "Critical"; Message = "$(@($unhealthy).Count) disk(s) reporting unhealthy SMART status"; Value = ($unhealthy.Name -join ', '); Color = "Red" }
    } else {
        $newNote = if (@($newDisks).Count -gt 0) { " ($(@($newDisks).Count) new disk(s) skipped)" } else { "" }
        [PSCustomObject]@{ Status = "Healthy";  Message = "All disk(s) healthy$newNote"; Value = "$(@($results).Count) disk(s) checked"; Color = "Green" }
    }
}

function Get-AvStatus {
    $avProducts = Get-CimInstance -Namespace "root/SecurityCenter2" -ClassName AntiVirusProduct -ErrorAction Stop

    if (-not $avProducts) {
        return [PSCustomObject]@{ Status = "Critical"; Message = "No antivirus registered with Security Center"; Value = "None"; Color = "Red" }
    }

    $avStatuses = foreach ($av in $avProducts) {
        $hex = [Convert]::ToString($av.productState, 16).PadLeft(6, '0')
        [PSCustomObject]@{
            Name         = $av.displayName
            RTPEnabled   = ($hex.Substring(0, 2) -eq "10")
            DefsUpToDate = ($hex.Substring(2, 2) -eq "00")
        }
    }

    $disabled = $avStatuses | Where-Object { -not $_.RTPEnabled }
    $outdated  = $avStatuses | Where-Object { -not $_.DefsUpToDate }
    $avNames   = ($avStatuses.Name -join ', ')

    if ($disabled) {
        [PSCustomObject]@{ Status = "Critical"; Message = "Real-time protection disabled: $($disabled.Name -join ', ')"; Value = $avNames; Color = "Red" }
    } elseif ($outdated) {
        [PSCustomObject]@{ Status = "Warning";  Message = "Definitions out of date: $($outdated.Name -join ', ')"; Value = $avNames; Color = "Yellow" }
    } else {
        [PSCustomObject]@{ Status = "Healthy";  Message = "Antivirus active with up-to-date definitions"; Value = $avNames; Color = "Green" }
    }
}

function Get-CriticalServicesStatus {
    $criticalServices = @(
        @{ Name = 'RpcSs';             Display = 'Remote Procedure Call'  },
        @{ Name = 'EventLog';          Display = 'Windows Event Log'      },
        @{ Name = 'Schedule';          Display = 'Task Scheduler'         },
        @{ Name = 'Dnscache';          Display = 'DNS Client'             },
        @{ Name = 'W32Time';           Display = 'Windows Time'           },
        @{ Name = 'wuauserv';          Display = 'Windows Update'         },
        @{ Name = 'WinDefend';         Display = 'Windows Defender'       },
        @{ Name = 'MpsSvc';            Display = 'Windows Firewall'       },
        @{ Name = 'LanmanWorkstation'; Display = 'Workstation (SMB)'      },
        @{ Name = 'CryptSvc';          Display = 'Cryptographic Services' }
    )

    $stopped = [System.Collections.Generic.List[string]]::new()
    $checked = 0

    foreach ($svc in $criticalServices) {
        $service = Get-Service -Name $svc.Name -ErrorAction SilentlyContinue
        if (-not $service) { continue }
        $checked++
        if ($service.Status -ne 'Running') { $stopped.Add($svc.Display) }
    }

    if ($stopped.Count -gt 0) {
        [PSCustomObject]@{ Status = "Critical"; Message = "Stopped: $($stopped -join ', ')"; Value = "$($stopped.Count) of $checked down"; Color = "Red" }
    } else {
        [PSCustomObject]@{ Status = "Healthy";  Message = "All critical services running"; Value = "$checked checked"; Color = "Green" }
    }
}

function Get-BatteryStatus {
    $battery = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue

    if (-not $battery) {
        return [PSCustomObject]@{ Status = "N/A"; Message = "No battery — desktop or battery not present"; Value = "N/A"; Color = "Gray" }
    }

    $designData = Get-CimInstance -Namespace "root/wmi" -ClassName BatteryStaticData          -ErrorAction SilentlyContinue
    $fullData   = Get-CimInstance -Namespace "root/wmi" -ClassName BatteryFullChargedCapacity  -ErrorAction SilentlyContinue
    $cycleData  = Get-CimInstance -Namespace "root/wmi" -ClassName BatteryCycleCount           -ErrorAction SilentlyContinue

    if ($designData -and $fullData -and $designData.DesignedCapacity -gt 0) {
        $cycleCnt  = if ($cycleData) { $cycleData.CycleCount } else { $null }
        $healthPct = [math]::Round(($fullData.FullChargedCapacity / $designData.DesignedCapacity) * 100)

        if ($null -ne $cycleCnt -and $cycleCnt -lt 10) {
            return [PSCustomObject]@{ Status = "Unknown"; Message = "Battery too new — only $cycleCnt cycle(s) recorded"; Value = "$cycleCnt cycles / $healthPct% capacity"; Color = "Cyan" }
        }

        $cycleNote = if ($null -ne $cycleCnt) { " | $cycleCnt cycles" } else { "" }

        if ($healthPct -le 60) {
            [PSCustomObject]@{ Status = "Critical"; Message = "Battery significantly degraded — $healthPct% capacity$cycleNote"; Value = "$healthPct% health"; Color = "Red" }
        } elseif ($healthPct -le 80) {
            [PSCustomObject]@{ Status = "Warning";  Message = "Battery wear detected — $healthPct% capacity$cycleNote"; Value = "$healthPct% health"; Color = "Yellow" }
        } else {
            [PSCustomObject]@{ Status = "Healthy";  Message = "Battery health good — $healthPct% capacity$cycleNote"; Value = "$healthPct% health"; Color = "Green" }
        }
    } else {
        $statusMap  = @{ 0="Unknown";1="Other";2="Unknown";3="Fully Charged";4="Low";5="Critical";6="Charging";7="Charging High";8="Charging Low";9="Charging Critical";10="Undefined";11="Partially Charged" }
        $statusKey  = [int]$battery.BatteryStatus
        $statusText = if ($statusMap.ContainsKey($statusKey)) { $statusMap[$statusKey] } else { "Unknown ($statusKey)" }
        [PSCustomObject]@{ Status = "Unknown"; Message = "Capacity data unavailable — status: $statusText"; Value = "$($battery.EstimatedChargeRemaining)% charge"; Color = "Yellow" }
    }
}
#endregion

#region --- Parallel execution ---
# Start WAN IP lookup immediately as a background job so it runs while checks execute
$wanJob = Start-Job -ScriptBlock {
    try { (Invoke-RestMethod -Uri "https://api.ipify.org" -TimeoutSec 5 -ErrorAction Stop).Trim() }
    catch { "Unavailable" }
}

# Build an initialisation script that loads all check functions into each job's runspace
$funcNames  = @(
    'Get-UptimeStatus','Get-DiskSpaceStatus','Get-CpuStatus','Get-PowerProfileStatus',
    'Get-WindowsUpdatesStatus','Get-RamStatus','Get-SmartDiskStatus','Get-AvStatus',
    'Get-CriticalServicesStatus','Get-BatteryStatus'
)
$funcDefs   = $funcNames | ForEach-Object { "function $_ {`n$((Get-Item ('function:' + $_)).ScriptBlock)`n}" }
$initScript = [scriptblock]::Create($funcDefs -join "`n`n")

# Show progress screen while jobs spin up
Clear-Host
Write-Host ("=" * $width) -ForegroundColor White
Write-Host "  RUNNING CHECKS..." -ForegroundColor White
Write-Host ("=" * $width) -ForegroundColor White
Write-Host ""

# Launch all checks simultaneously
$jobs = [ordered]@{
    "Uptime"            = Start-Job -InitializationScript $initScript -ScriptBlock { Get-UptimeStatus }
    "Disk Space"        = Start-Job -InitializationScript $initScript -ScriptBlock { Get-DiskSpaceStatus }
    "CPU Performance"   = Start-Job -InitializationScript $initScript -ScriptBlock { Get-CpuStatus }
    "Power Scheme"      = Start-Job -InitializationScript $initScript -ScriptBlock { Get-PowerProfileStatus }
    "Windows Updates"   = Start-Job -InitializationScript $initScript -ScriptBlock { Get-WindowsUpdatesStatus }
    "RAM Usage"         = Start-Job -InitializationScript $initScript -ScriptBlock { Get-RamStatus }
    "SMART Disk Health" = Start-Job -InitializationScript $initScript -ScriptBlock { Get-SmartDiskStatus }
    "Antivirus"         = Start-Job -InitializationScript $initScript -ScriptBlock { Get-AvStatus }
    "Critical Services" = Start-Job -InitializationScript $initScript -ScriptBlock { Get-CriticalServicesStatus }
    "Battery Health"    = Start-Job -InitializationScript $initScript -ScriptBlock { Get-BatteryStatus }
}

# Show a live elapsed timer while waiting for all jobs to finish
$timer = [System.Diagnostics.Stopwatch]::StartNew()
while (@($jobs.Values | Where-Object { $_.State -eq 'Running' }).Count -gt 0) {
    $elapsed  = $timer.Elapsed
    $running  = @($jobs.Values | Where-Object { $_.State -eq 'Running' }).Count
    $done     = $jobs.Count - $running
    Write-Host "`r  $done/$($jobs.Count) checks complete   [$([string]::Format('{0:D2}:{1:D2}', $elapsed.Minutes, $elapsed.Seconds))]   " -NoNewline -ForegroundColor DarkGray
    Start-Sleep -Milliseconds 500
}
$timer.Stop()
Write-Host "`r  All checks complete [$([string]::Format('{0:D2}:{1:D2}', $timer.Elapsed.Minutes, $timer.Elapsed.Seconds))]          " -ForegroundColor DarkGray
Write-Host ""

# All jobs are now finished — collect results in order with no further waiting
$checks = [ordered]@{}
foreach ($entry in $jobs.GetEnumerator()) {
    try {
        $result = Receive-Job -Job $entry.Value -ErrorAction Stop
        if (-not $result) { throw "Check returned no result" }
        $checks[$entry.Key] = $result
    } catch {
        $checks[$entry.Key] = [PSCustomObject]@{ Status = "Error"; Message = $_.Exception.Message; Value = "N/A"; Color = "Magenta" }
    } finally {
        $entry.Value | Remove-Job -Force -ErrorAction SilentlyContinue
    }
}
#endregion

#region --- Device info ---
$os   = try { Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop } catch { $null }
$bios = try { Get-CimInstance -ClassName Win32_BIOS            -ErrorAction Stop } catch { $null }
$cs   = try { Get-CimInstance -ClassName Win32_ComputerSystem  -ErrorAction Stop } catch { $null }

$localIP = try {
    $ip = (Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter "IPEnabled = True" |
        Where-Object { $_.IPAddress -match '^\d+\.\d+\.\d+\.\d+$' } |
        Select-Object -First 1).IPAddress |
        Where-Object { $_ -match '^\d' } |
        Select-Object -First 1
    if ($ip) { $ip } else { "Not detected" }
} catch { "Not detected" }

# Collect WAN IP — should already be done since checks took longer than the lookup
$wanIP = try {
    [string]($wanJob | Wait-Job -Timeout 5 | Receive-Job -ErrorAction Stop | Select-Object -First 1)
} catch { "Unavailable" } finally {
    $wanJob | Remove-Job -Force -ErrorAction SilentlyContinue
}
if (-not $wanIP) { $wanIP = "Unavailable" }

$serialNum  = if ($bios) { $bios.SerialNumber } else { "N/A" }
$modelName  = if ($cs)   { $cs.Model          } else { "N/A" }
$domainName = if ($cs)   { $cs.Domain         } else { "N/A" }
$bootTime   = if ($os)   { Get-Date $os.LastBootUpTime -Format 'yyyy-MM-dd HH:mm:ss' } else { "N/A" }
$osCaption  = if ($os)   { $os.Caption -replace '^Microsoft\s+', '' } else { "Unknown" }
$osValue    = if ($os)   { "$osCaption (Build $($os.BuildNumber))" } else { "Unknown" }
#endregion

#region --- Results ---
Clear-Host

Write-Host ("=" * $width) -ForegroundColor White
# PadRight($width - 2): title includes a 2-space leading indent, padding to ($width - 2) aligns the right edge with the === border
Write-Host ("  PC HEALTH CHECK".PadRight($width - 2)) -ForegroundColor Cyan
Write-Host ("=" * $width) -ForegroundColor White
Write-InfoRow "Host"      $env:COMPUTERNAME                  "Serial"    $serialNum
Write-InfoRow "User"      $env:USERNAME                      "Model"     $modelName
Write-InfoRow "Domain"    $domainName                        "OS"        $osValue
Write-InfoRow "Local IP"  $localIP                           "WAN IP"    $wanIP
Write-InfoRow "Boot Time" $bootTime                          "Generated" (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Write-Host ("=" * $width) -ForegroundColor White
Write-Host ""

Write-Row "CHECK" "STATUS" "VALUE" "DETAILS" "White"
Write-Divider "White"

foreach ($entry in $checks.GetEnumerator()) {
    $r = $entry.Value
    Write-Row $entry.Key $r.Status $r.Value $r.Message $r.Color
}

Write-Divider "White"
Write-Host ""
#endregion

