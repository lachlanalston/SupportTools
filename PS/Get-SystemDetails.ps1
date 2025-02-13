# Get OS Info
$OS = Get-ComputerInfo
$WindowsEdition = $OS.WindowsProductName
$WindowsVersion = $OS.WindowsVersion
$OSBuild = $OS.OsBuildNumber
$Arch = $OS.OsArchitecture
$FeatureVersion = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name DisplayVersion).DisplayVersion

# Get Install Info
$version = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" | Select-Object DisplayVersion, InstallDate
$installDate = [System.DateTimeOffset]::FromUnixTimeSeconds($version.InstallDate).DateTime

# Get System Info (Manufacturer and Model)
$SystemInfo = Get-WmiObject -Class Win32_ComputerSystem | Select-Object Manufacturer, Model

# Get Active User Info
$User = (Get-WmiObject -Class Win32_ComputerSystem).UserName

# Get Machine Uptime
$LastBootUpTime = (Get-WmiObject -Class Win32_OperatingSystem).LastBootUpTime
$LastBootUpTime = [System.Management.ManagementDateTimeConverter]::ToDateTime($LastBootUpTime)
$Uptime = (Get-Date) - $LastBootUpTime
$UptimeFormatted = [string]::Format("{0:D2} days, {1:D2} hours, {2:D2} minutes", $Uptime.Days, $Uptime.Hours, $Uptime.Minutes)

# Last Sign-Out User retrieval is currently not working, so it has been commented out.
<#
# Get Last Sign-Out User and Time via Event Logs
$LastLogoffEvent = Get-WinEvent -LogName Security -FilterXPath "*[EventData[@Name='TargetUserName'] and EventID=4647]" -MaxEvents 1 -ErrorAction SilentlyContinue
if ($LastLogoffEvent) {
    $LastSignOutUser = $LastLogoffEvent.Properties[0].Value
    $LastSignOutTime = $LastLogoffEvent.TimeCreated
} else {
    $LastSignOutUser = "No logoff events found"
    $LastSignOutTime = "N/A"
}
#>

# Output Results
Write-Output "`n--- OS Information ---"
Write-Output "Windows Edition: $WindowsEdition"
Write-Output "Windows Version: $WindowsVersion"
Write-Output "Feature Update Version: $FeatureVersion"
Write-Output "OS Build Number: $OSBuild"
Write-Output "OS Architecture: $Arch"
Write-Output "Updated to Windows $($version.DisplayVersion) on $installDate"

Write-Output "`n--- System Info ---"
Write-Output "System Info: $($SystemInfo.Manufacturer) $($SystemInfo.Model)"

Write-Output "`n--- User Info ---"
if ($User) {
    Write-Output "Currently Logged In User: $User"
} else {
    Write-Output "No user is currently signed in."
}
Write-Output "Machine Uptime: $UptimeFormatted"

<#
Write-Output "`n--- Last Sign-Out User ---"
Write-Output "Last Signed Out User: $LastSignOutUser"
Write-Output "Last Sign-Out Time: $LastSignOutTime"
#>
