# Ensure TLS 1.2 is used for secure downloads
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Ensure NuGet provider is installed without prompts or output
if (-not (Get-PackageProvider -ListAvailable | Where-Object { $_.Name -eq "NuGet" })) {
    Write-Output "NuGet provider not found. Installing..."
    Install-PackageProvider -Name NuGet -Force -Confirm:$false | Out-Null
}

# Ensure PowerShellGet module is updated without prompts or output
if (-not (Get-Module -ListAvailable -Name PowerShellGet)) {
    Write-Output "PowerShellGet module not found. Installing..."
    Install-Module -Name PowerShellGet -Force -Confirm:$false -SkipPublisherCheck | Out-Null
}

# Ensure the PSWindowsUpdate module is installed without prompts or output
if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
    Write-Output "PSWindowsUpdate module not found. Installing..."
    Install-Module -Name PSWindowsUpdate -Force -Confirm:$false -AllowClobber -SkipPublisherCheck -Scope CurrentUser | Out-Null
}

# Import the module, ensuring errors are caught
try {
    Import-Module PSWindowsUpdate -ErrorAction Stop | Out-Null
} catch {
    Write-Output "Failed to import PSWindowsUpdate module. Exiting..."
    exit 1
}

# Check for available updates
try {
    $AvailableUpdates = Get-WindowsUpdate -ErrorAction Stop

    # Display available updates
    if ($AvailableUpdates) {
        Write-Host "`nThe following updates are available:" -ForegroundColor Green
        Write-Host "--------------------------------------------------------"
        $AvailableUpdates | Format-Table -Property KB, Title, Date -AutoSize | Out-String | Write-Host
    } else {
        Write-Host "`nNo updates are pending." -ForegroundColor Yellow
    }
} catch {
    Write-Host "Failed to retrieve Windows Updates. Ensure the module is correctly installed." -ForegroundColor Red
}
