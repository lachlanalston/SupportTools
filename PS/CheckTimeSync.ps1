# Set NTP servers for time synchronization
$ntpServer = "time.anu.edu.au"  # Primary NTP server
$alternateNtpServer = "pool.ntp.org"  # Alternative NTP server
$successfulNtpServer = $null  # To store the successfully used NTP server

# Initial Check: Current Time and Sync Status
Write-Host "-----------------------------------------"
Write-Host "Initial Check"
Write-Host "-----------------------------------------"
Write-Host ""

# Get current time
$currentTime = Get-Date
Write-Host "Current Time: $($currentTime.ToString('MM/dd/yyyy hh:mm:ss tt'))"
Write-Host ""  # New line added for better readability

# Get Windows Time Service Status
$timeServiceStatus = Get-Service -Name w32time
Write-Host "Windows Time Service Status: $($timeServiceStatus.Status)"
Write-Host ""  # New line added for better readability

# Get Time Sync Status and format it correctly
$timeSyncStatus = w32tm /query /status
Write-Host "Time Sync Status:"
$timeSyncStatus = $timeSyncStatus -replace "\r\n", "`n"  # Normalize line breaks
$timeSyncStatus = $timeSyncStatus -replace "  +", " "  # Remove extra spaces between values

# Format Time Sync Status output to show each value on a new line
$timeSyncStatusLines = $timeSyncStatus -split "`n"
$timeSyncStatusLines | ForEach-Object { Write-Host $_ }  # Output each line

Write-Host ""  # New line added for better readability

# Actions: Testing NTP Server Connectivity and Syncing Time
Write-Host "-----------------------------------------"
Write-Host "Actions"
Write-Host "-----------------------------------------"
Write-Host ""

Write-Host "Testing Connectivity to ${ntpServer}:"
$ntpServerReachable = Test-Connection -ComputerName $ntpServer -Count 2 -Quiet

if ($ntpServerReachable) {
    Write-Host "$ntpServer is reachable."
    
    # Set NTP server explicitly if reachable
    Write-Host "`nSetting NTP Server: $ntpServer"
    w32tm /config /manualpeerlist:"$ntpServer" /syncfromflags:manual /reliable:YES /update
    Restart-Service -Name w32time
    
    # Force time synchronization and send resync command
    Write-Host "`nRestarting Windows Time Service with NTP Server: $ntpServer"
    $syncStatus = w32tm /resync
    Write-Host "The command completed successfully."
    Write-Host "Forced time synchronization with the NTP server."
    Write-Host "Sending resync command to local computer"
    
    # Track that we used the primary server for synchronization
    $successfulNtpServer = $ntpServer
} else {
    Write-Host "$ntpServer is not reachable."
    Write-Host "Attempting to use an alternative NTP server..."
    
    # Test and use alternative NTP server if the primary one fails
    Write-Host "Testing Connectivity to ${alternateNtpServer}:"
    $ntpServerReachableAlt = Test-Connection -ComputerName $alternateNtpServer -Count 2 -Quiet
    
    if ($ntpServerReachableAlt) {
        Write-Host "$alternateNtpServer is reachable."
        Write-Host "`nSetting NTP Server: $alternateNtpServer"
        w32tm /config /manualpeerlist:"$alternateNtpServer" /syncfromflags:manual /reliable:YES /update
        Restart-Service -Name w32time
        $syncStatusAlt = w32tm /resync
        Write-Host "The command completed successfully."
        Write-Host "Forced time synchronization with alternative NTP server."
        
        # Track that we used the alternative server
        $successfulNtpServer = $alternateNtpServer
    } else {
        Write-Host "$alternateNtpServer is not reachable. Skipping synchronization steps."
    }
}

# Post Check: Check Current Time After Sync and Time Sync Status
Write-Host "-----------------------------------------"
Write-Host "Post Check"
Write-Host "-----------------------------------------"
Write-Host ""  # Added a new line here for separation

# Get current time after synchronization
$currentTimeAfterSync = Get-Date
Write-Host "Current Time After Sync: $($currentTimeAfterSync.ToString('MM/dd/yyyy hh:mm:ss tt'))"
Write-Host ""  # New line added for better readability

# Get Time Sync Status after sync attempt
$timeSyncStatusAfter = w32tm /query /status
Write-Host "Time Sync Status After Sync:"
$timeSyncStatusAfter = $timeSyncStatusAfter -replace "\r\n", "`n"  # Normalize line breaks
$timeSyncStatusAfter = $timeSyncStatusAfter -replace "  +", " "  # Remove extra spaces between values

# Format Time Sync Status after sync output to show each value on a new line
$timeSyncStatusAfterLines = $timeSyncStatusAfter -split "`n"
$timeSyncStatusAfterLines | ForEach-Object { Write-Host $_ }  # Output each line after sync

# Check Windows Time Service Status
$timeServiceStatusAfter = Get-Service -Name w32time
Write-Host "`nWindows Time Service Status: $($timeServiceStatusAfter.Status)"

# Check for errors in Event Viewer related to Time Sync
Write-Host "`nLooking for any time synchronization errors in the Event Viewer..."

$eventLogErrors = Get-WinEvent -LogName System | Where-Object { $_.Message -like "*Time Synchronization*" }
Write-Host "Time Sync Errors in Event Viewer:"
if ($eventLogErrors) {
    $eventLogErrors | ForEach-Object { Write-Host $_.Message }
} else {
    Write-Host "No time sync errors found in the Event Viewer."
}

# Summary Section: Include Current Local Time and Sync Information
Write-Host ""
Write-Host "-----------------------------------------"
Write-Host "Summary"
Write-Host "-----------------------------------------"
Write-Host "Current Time on Local Machine: $($currentTime.ToString('MM/dd/yyyy hh:mm:ss tt'))"
Write-Host "Last Successful Sync Time: $($currentTimeAfterSync.ToString('MM/dd/yyyy hh:mm:ss tt'))"
Write-Host "Time Synchronization was successfully completed with NTP Server: $($successfulNtpServer)"
Write-Host "-----------------------------------------"
