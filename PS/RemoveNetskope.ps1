function Remove-NetskopeClient {
    $svc = 'stAgentSvc'
    $paths = @(
        'C:\Program Files (x86)\Netskope\STAgent',
        'C:\ProgramData\Netskope'
    )
    $failures = @()
    $guid = $null

    # Dynamically get Netskope MSI product GUID
    $product = Get-WmiObject -Class Win32_Product | Where-Object { $_.Name -like "*Netskope*" } | Select-Object -First 1
    if ($null -eq $product) {
        Write-Host "Netskope MSI product not found; skipping uninstall."
    } else {
        $guid = $product.IdentifyingNumber
        Write-Host "Uninstalling Netskope via MSI product code $guid..."
        try {
            Start-Process msiexec.exe -ArgumentList "/x $guid /qn" -Wait -ErrorAction Stop
            Write-Host "Uninstall command executed."
        } catch {
            $failures += "Failed to uninstall Netskope via MSI: $guid"
        }
        Start-Sleep -Seconds 5
    }

    # Stop and remove service if still present
    if (Get-Service -Name $svc -ErrorAction SilentlyContinue) {
        try {
            Write-Host "Stopping service $svc..."
            Stop-Service -Name $svc -Force -ErrorAction Stop
            Write-Host "Deleting service $svc..."
            sc.exe delete $svc | Out-Null
        } catch {
            $failures += "Failed to stop or delete service: $svc"
        }
    }

    # Remove leftover folders
    foreach ($p in $paths) {
        if (Test-Path $p) {
            # Attempt to stop locking processes by name containing 'Netskope'
            $lockingProcs = Get-Process | Where-Object { $_.Path -like "*Netskope*" } | Select-Object -ExpandProperty Id -Unique
            foreach ($pid in $lockingProcs) {
                try {
                    Write-Host "Stopping locking process PID $pid..."
                    Stop-Process -Id $pid -Force -ErrorAction Stop
                } catch {
                    $failures += "Failed to stop locking process with PID $pid"
                }
            }

            Start-Sleep -Seconds 2

            try {
                Write-Host "Removing folder $p ..."
                Remove-Item $p -Recurse -Force -ErrorAction Stop
            } catch {
                # Report Failure
                $failures += "Failed to remove folder: $p"
            }
        }
    }

    # Remove Netskope certificates
    try {
        Get-ChildItem Cert:\LocalMachine\Root |
            Where-Object { $_.Issuer -like '*Netskope*' -or $_.Subject -like '*Netskope*' } |
            ForEach-Object {
                Remove-Item "Cert:\LocalMachine\Root\$($_.Thumbprint)" -ErrorAction SilentlyContinue
            }
    } catch {
        $failures += "Failed to remove some Netskope certificates"
    }

    # Remove user roaming data
    Get-ChildItem 'C:\Users' -Directory | ForEach-Object {
        $userPath = "$($_.FullName)\AppData\Roaming\Netskope"
        if (Test-Path $userPath) {
            try {
                Remove-Item $userPath -Recurse -Force -ErrorAction Stop
            } catch {
                $failures += "Failed to remove user roaming folder: $userPath"
            }
        }
    }

    # Final checks for leftovers
    if (Get-Service -Name $svc -ErrorAction SilentlyContinue) {
        $failures += "Service still exists: $svc"
    }

    if ($guid) {
        if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$guid") {
            $failures += "Registry uninstall key still exists: $guid"
        }
    }

    foreach ($p in $paths) {
        if (Test-Path $p) {
            $failures += "Folder still exists: $p"
        }
    }

    $certs = Get-ChildItem Cert:\LocalMachine\Root |
        Where-Object { $_.Issuer -like '*Netskope*' -or $_.Subject -like '*Netskope*' }
    if ($certs.Count -gt 0) {
        $failures += "Netskope certificates still present"
    }

    $roamingLeft = Get-ChildItem 'C:\Users' -Directory |
        Where-Object { Test-Path "$($_.FullName)\AppData\Roaming\Netskope" }
    if ($roamingLeft.Count -gt 0) {
        $failures += "User roaming data still exists in $($roamingLeft.Count) user(s)"
    }

    # Output results and return boolean
    if ($failures.Count -eq 0) {
        Write-Output "PASS: All Netskope remnants removed successfully."
        return $true
    } else {
        Write-Output "FAIL: Netskope remnants detected:"
        $failures | ForEach-Object { Write-Output "  - $_" }
        return $false
    }
}

# Run function and capture result
$result = Remove-NetskopeClient
$result
