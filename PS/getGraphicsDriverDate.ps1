function Get-DellGraphicsDriverUpdates {
    [CmdletBinding()]
    param (
        [int]$DaysBack = 90,
        [string]$ExportPath = ""  # Optional export to CSV
    )

    $logPath = "C:\ProgramData\Dell\UpdateService\Log"

    if (!(Test-Path $logPath)) {
        Write-Host "Dell log folder not found at $logPath"
        return
    }

    $graphicsRegex = "NVIDIA.*(GeForce|RTX|Quadro|Titan)|Intel.*(UHD|Iris|Graphics)|AMD.*(Radeon|Graphics)|Radeon.*Graphics|Graphics Driver|Video"

    $entries = @()

    Get-ChildItem -Path $logPath -Filter "Service*.log" |
    Sort-Object LastWriteTime -Descending |
    ForEach-Object {
        $logFile = $_.FullName

        Select-String -Path $logFile -Pattern $graphicsRegex |
        ForEach-Object {
            $line = $_.Line.Trim()

            if ($line -match "install(ed)? successfully|fail(ed)?") {
                if ($line -match "\[(\d{2}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]") {
                    $timestamp = $matches[1]
                } else {
                    $timestamp = "Unknown"
                }

                if ($line -match $graphicsRegex) {
                    $driver = $matches[0]
                } else {
                    $driver = "Unknown"
                }

                $status = if ($line -match "successfully") { "Successful" } else { "Failed" }

                if ($timestamp -ne "Unknown") {
                    try {
                        $entryDate = [datetime]::ParseExact($timestamp, "yy-MM-dd HH:mm:ss", $null)
                        if ($entryDate -lt (Get-Date).AddDays(-$DaysBack)) {
                            return
                        }
                        $daysAgo = (New-TimeSpan -Start $entryDate -End (Get-Date)).Days
                    } catch {
                        $daysAgo = "Unknown"
                    }
                } else {
                    $daysAgo = "Unknown"
                }

                $entries += [PSCustomObject]@{
                    DateInstalled = $entryDate
                    DaysAgo       = $daysAgo
                    Driver        = $driver
                    Status        = $status
                    SourceLog     = Split-Path $logFile -Leaf
                }
            }
        }
    }

    if ($entries.Count -gt 0) {
        $sorted = $entries | Sort-Object DateInstalled -Descending

        Write-Host "=== Dell Graphics Driver Update History (Last $DaysBack days) ===`n" -ForegroundColor Cyan
        $sorted | Format-Table DateInstalled, DaysAgo, Status, Driver -AutoSize

        if ($ExportPath) {
            $sorted | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
            Write-Host "`nResults exported to $ExportPath" -ForegroundColor Green
        }
    }
    else {
        Write-Host "No Dell graphics driver updates found in the last $DaysBack days." -ForegroundColor Yellow
    }
}

# Example usage (check last 180 days and export to CSV)
Get-DellGraphicsDriverUpdates -DaysBack 180 -ExportPath "C:\Temp\DellGraphicsDrivers.csv"
