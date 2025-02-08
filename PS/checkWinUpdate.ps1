# Ensure the PSWindowsUpdate module is installed
if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
    Write-Output "PSWindowsUpdate module not found. Installing..."
    Install-Module -Name PSWindowsUpdate -Force -AllowClobber
}

# Import the module
Import-Module PSWindowsUpdate

# Check for available updates
$AvailableUpdates = Get-WindowsUpdate

# Display available updates
if ($AvailableUpdates) {
    Write-Host "`nThe following updates are available:" -ForegroundColor Green
    Write-Host "--------------------------------------------------------"
    $AvailableUpdates | Format-Table -Property KB, Title, Date -AutoSize | Out-String | Write-Host
} else {
    Write-Host "`nNo updates are pending." -ForegroundColor Yellow
}
