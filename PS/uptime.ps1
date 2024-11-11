# Get system uptime
$uptime = (Get-Date) - (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime

# Display in hours if less than 24 hours, otherwise in days
if ($uptime.TotalHours -lt 24) {
    $uptimeFormatted = [math]::round($uptime.TotalHours, 2).ToString() + " hours"
} else {
    # Explicitly convert hours to days (divide by 24)
    $days = [math]::round($uptime.TotalHours / 24, 2)
    $uptimeFormatted = $days.ToString() + " days"
}

# Output the formatted uptime
$uptimeFormatted
