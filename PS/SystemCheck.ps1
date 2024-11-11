# Check system performance, services, memory, disk, and updates

# Define the critical services to check
$criticalServices = @(
    "wuauserv",    # Windows Update
    "bits",        # Background Intelligent Transfer Service
    "dhcp",        # DHCP Client
    "netlogon",    # Netlogon
    "rpcss",       # RPC Endpoint Mapper
    "schedule"     # Task Scheduler
)

# Initialize investigation flag and result details
$investigateReasons = @()

# Check the status of critical services
$criticalServicesStatus = "OK"
$criticalServiceIssues = @()

foreach ($service in $criticalServices) {
    $serviceStatus = Get-Service -Name $service -ErrorAction SilentlyContinue
    if ($serviceStatus.Status -ne "Running") {
        $criticalServicesStatus = "Investigate"
        $criticalServiceIssues += "Critical service '$service' is not running."
    }
}

# Collect disk usage info
$diskSpace = Get-WmiObject Win32_LogicalDisk | Where-Object { $_.DriveType -eq 3 }
$diskSpaceResults = $diskSpace | Select-Object DeviceID, 
    @{Name="Used(GB)"; Expression={[math]::round(($_.Size - $_.FreeSpace) / 1GB, 2)}}, 
    @{Name="Free(GB)"; Expression={[math]::round($_.FreeSpace / 1GB, 2)}}, 
    @{Name="Total(GB)"; Expression={[math]::round($_.Size / 1GB, 2)}}

# Check if disk space is below 10% free space
$diskFreeSpaceCheck = $diskSpace | Where-Object { $_.FreeSpace / $_.Size -lt 0.1 }
if ($diskFreeSpaceCheck) {
    $criticalServicesStatus = "Investigate"
    $investigateReasons += "Disk space is low on drive '$($diskFreeSpaceCheck.DeviceID)'. Free space is below 10%."
}

# Get CPU info (usage and speed)
$cpuInfo = Get-WmiObject Win32_Processor
$cpuUsage = $cpuInfo | Select-Object Name, 
    @{Name="Usage(%)"; Expression={$_.'LoadPercentage'}}, 
    @{Name="Speed(GHz)"; Expression={($_.MaxClockSpeed / 1000)}}

# Get memory info (usage, free, and total)
$memory = Get-WmiObject Win32_OperatingSystem
$memoryUsage = [math]::round(($memory.TotalVisibleMemorySize - $memory.FreePhysicalMemory) / 1MB, 2)
$memoryFree = [math]::round($memory.FreePhysicalMemory / 1MB, 2)
$memoryTotal = [math]::round($memory.TotalVisibleMemorySize / 1MB, 2)

# Check if memory usage is over 90%
if ($memoryUsage / $memoryTotal -gt 0.9) {
    $criticalServicesStatus = "Investigate"
    $investigateReasons += "Memory usage is over 90%. Current usage: $memoryUsage MB."
}

# Get IO Read/Write activity (top 5 processes)
$processes = Get-WmiObject Win32_Process | Select-Object Name, IOReadBytes, IOWriteBytes | Sort-Object IOReadBytes -Descending | Select-Object -First 5

# Get page file usage
$pageFile = Get-WmiObject -Class Win32_PageFileUsage
$pageFileUsage = $pageFile | Select-Object Name, AllocatedBaseSize, CurrentUsage

# Handle CPU temperature (if available)
$cpuTemp = "Not Supported"
try {
    $thermalInfo = Get-WmiObject -Namespace "root/wmi" -Class MSAcpi_ThermalZoneTemperature -ErrorAction Stop
    if ($thermalInfo) {
        $cpuTemp = $thermalInfo.CurrentTemperature
    }
} catch {
    # Handle the case where CPU temperature is not supported
}

# Get pending Windows updates
Import-Module PSWindowsUpdate -ErrorAction SilentlyContinue
$pendingUpdates = Get-WUList
$pendingUpdatesResults = if ($pendingUpdates.Count -gt 0) {
    $pendingUpdates | Select-Object Title, KB
} else {
    $null
}

# Check if there are pending updates
if ($pendingUpdates.Count -gt 0) {
    $criticalServicesStatus = "Investigate"
    $investigateReasons += "There are pending Windows updates."
}

# Output only issues that need to be investigated
Write-Host "`n=== System Performance Issues ==="
Write-Host "----------------------------------------"

# Output investigation results (only issues found)
if ($criticalServiceIssues.Count -gt 0) {
    Write-Host "`nCritical Services Status: Investigate"
    $criticalServiceIssues | ForEach-Object { Write-Host $_ }
}

if ($diskFreeSpaceCheck) {
    Write-Host "`nDisk Space Usage: Investigate"
    Write-Host "Disk space is low on drive '$($diskFreeSpaceCheck.DeviceID)'. Free space is below 10%."
}

if ($memoryUsage / $memoryTotal -gt 0.9) {
    Write-Host "`nMemory Usage: Investigate"
    Write-Host "Memory usage is over 90%. Current usage: $memoryUsage MB."
}

if ($cpuTemp -eq "Not Supported") {
    Write-Host "`nCPU Temperature: Not Supported"
}

if ($pendingUpdatesResults) {
    Write-Host "`nPending Windows Updates: Investigate"
    $pendingUpdatesResults | Format-Table -AutoSize
}

# Final Status (OK or Investigate)
$finalStatus = if ($criticalServicesStatus -eq "OK" -and $diskSpaceResults) { "OK" } else { "Investigate" }

# Display Final Status with Color
$finalStatusColor = if ($finalStatus -eq "OK") { "Green" } else { "Yellow" }
Write-Host "`nFinal Status: $finalStatus" -ForegroundColor $finalStatusColor
