# Import the PSWindowsUpdate module
Import-Module PSWindowsUpdate

# Get list of updates that are available to install
$updates = Get-WUList

# Check if updates are available
if ($updates.Count -eq 0) {
    Write-Host "No updates are available."
    # You can add additional actions here, like logging the result or triggering other tasks.
} else {
    $updates | Select-Object Title, KB, IsInstalled | Format-Table -AutoSize
}
