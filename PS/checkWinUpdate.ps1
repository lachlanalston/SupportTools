# List all installed updates (including security and non-security updates)
Get-WmiObject -Class "Win32_QuickFixEngineering" | Select-Object Description, HotFixID, InstalledOn, ServicePackInEffect | Format-Table -AutoSize
