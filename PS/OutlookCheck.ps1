# Function to check if Outlook is running
function Check-OutlookStatus {
    $outlook = Get-Process -Name "Outlook" -ErrorAction SilentlyContinue
    if ($outlook) {
        return "OK"
    } else {
        return "Outlook is not running."
    }
}

# Function to check DNS resolution for Outlook server
function Check-DNSResolution {
    try {
        $dns = Resolve-DnsName -Name "outlook.office365.com" -ErrorAction Stop
        return "OK"
    } catch {
        return "DNS resolution failed. Please check DNS settings."
    }
}

# Function to check internet connection
function Test-InternetConnection {
    try {
        $ping = Test-Connection -ComputerName "google.com" -Count 2 -ErrorAction Stop
        return "OK"
    } catch {
        return "Internet connection is not stable."
    }
}

# Function to start Outlook if it's not running or restart if frozen
function StartOrRestart-Outlook {
    $outlookProcess = Get-Process -Name "Outlook" -ErrorAction SilentlyContinue
    if ($outlookProcess) {
        # If Outlook is running but frozen, restart it
        Stop-Process -Name "Outlook" -Force
        try {
            Start-Process "Outlook" -ErrorAction Stop
            return "Outlook has been restarted."
        } catch {
            return "Failed to restart Outlook. Please ensure Outlook is installed."
        }
    } else {
        # If Outlook is not running, start it
        try {
            Start-Process "Outlook" -ErrorAction Stop
            return "Outlook has been started."
        } catch {
            return "Failed to start Outlook. Please ensure Outlook is installed."
        }
    }
}

# Initial Checks
$outlookStatus = Check-OutlookStatus
$dnsStatus = Check-DNSResolution
$internetStatus = Test-InternetConnection

# Display Initial Checks Table with Colors
Write-Host "`n------------------ Initial Checks ------------------" -ForegroundColor Cyan
Write-Host "Check               Result        Recommendation" -ForegroundColor Yellow
Write-Host "-----               ------        --------------" -ForegroundColor Yellow
Write-Host "Outlook Status      $outlookStatus     $(if($outlookStatus -eq 'OK') {'Outlook is running fine.'} else {'Outlook is not running. Please start Outlook.'})"
Write-Host "DNS Resolution      $dnsStatus     DNS resolution for Outlook is working fine. No action required."
Write-Host "Internet Connection $internetStatus     Internet connection is stable. No action required."
Write-Host ""

# Automated Task (Start or Restart Outlook if necessary)
if ($outlookStatus -eq "Outlook is not running.") {
    Write-Host "------------------ Automated Tasks ------------------" -ForegroundColor Cyan
    $startOrRestartStatus = StartOrRestart-Outlook
    Write-Host "Task               Status     Recommendation" -ForegroundColor Yellow
    Write-Host "----               ------     --------------" -ForegroundColor Yellow
    Write-Host "Outlook Started     Not Running     $startOrRestartStatus"
    Write-Host ""
} elseif ($outlookStatus -eq "Outlook is frozen.") {
    Write-Host "------------------ Automated Tasks ------------------" -ForegroundColor Cyan
    $startOrRestartStatus = StartOrRestart-Outlook
    Write-Host "Task               Status     Recommendation" -ForegroundColor Yellow
    Write-Host "----               ------     --------------" -ForegroundColor Yellow
    Write-Host "Outlook Restarted   Frozen     $startOrRestartStatus"
    Write-Host ""
} else {
    Write-Host "------------------ Automated Tasks ------------------" -ForegroundColor Cyan
    Write-Host "No automated tasks required." -ForegroundColor Green
    Write-Host ""
}

# Final Checks
$outlookStatus = Check-OutlookStatus
$dnsStatus = Check-DNSResolution
$internetStatus = Test-InternetConnection

# Display Final Checks Table with Colors
Write-Host "------------------ Final Checks ------------------" -ForegroundColor Cyan
Write-Host "Check               Result        Recommendation" -ForegroundColor Yellow
Write-Host "-----               ------        --------------" -ForegroundColor Yellow
Write-Host "Outlook Status      $outlookStatus     $(if($outlookStatus -eq 'OK') {'No action required. Outlook is running fine.'} else {'Outlook is not running. Please start Outlook.'})"
Write-Host "DNS Resolution      $dnsStatus     $(if($dnsStatus -eq 'OK') {'No action required. DNS resolution is working fine.'} else {'DNS resolution failed. Please check DNS settings.'})"
Write-Host "Internet Connection $internetStatus     $(if($internetStatus -eq 'OK') {'No action required. Internet connection is stable.'} else {'Internet connection is not stable.'})"
Write-Host ""

# Final Status
Write-Host "------------------ Final Status ------------------" -ForegroundColor Cyan
Write-Host "Check               Result        Recommendation" -ForegroundColor Yellow
Write-Host "-----               ------        --------------" -ForegroundColor Yellow

# Corrected final status condition
if ($outlookStatus -eq "OK" -and $dnsStatus -eq "OK" -and $internetStatus -eq "OK") {
    Write-Host "Final Status        OK          No issues detected. All checks passed." -ForegroundColor Green
} else {
    $failedChecks = @()
    if ($outlookStatus -ne "OK") { $failedChecks += "Outlook Status" }
    if ($dnsStatus -ne "OK") { $failedChecks += "DNS Resolution" }
    if ($internetStatus -ne "OK") { $failedChecks += "Internet Connection" }

    Write-Host "Final Status        Investigate The following tests failed: $($failedChecks -join ', '). Follow the recommendations above to resolve the issues." -ForegroundColor Red
}
