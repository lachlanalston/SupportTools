# Remove-NetworkDrives.ps1
# Removes all connected network drives and reports what was done

# Report execution context
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
if ($currentUser -like '*SYSTEM*') {
    Write-Host "Running as: SYSTEM context  ($currentUser)" -ForegroundColor Magenta
    Write-Host "NOTE: Network drives mapped to users will NOT be visible in this context.`n" -ForegroundColor Yellow
} else {
    Write-Host "Running as: User context  ($currentUser)`n" -ForegroundColor Magenta
}

$drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.DisplayRoot -like '\\*' }

if (-not $drives) {
    Write-Host "No network drives found." -ForegroundColor Yellow
    exit
}

Write-Host "`nFound $($drives.Count) network drive(s). Removing...`n" -ForegroundColor Cyan

foreach ($drive in $drives) {
    $letter = "$($drive.Name):"
    $path   = $drive.DisplayRoot

    try {
        net use $letter /delete /yes 2>&1 | Out-Null
        Write-Host "[REMOVED] $letter -> $path" -ForegroundColor Green
    } catch {
        Write-Host "[FAILED]  $letter -> $path  |  $_" -ForegroundColor Red
    }
}

Write-Host "`nDone." -ForegroundColor Cyan
