<#
.SYNOPSIS
    Retrieves the Windows Update log and displays it in a table format for troubleshooting purposes.

.DESCRIPTION
    This script uses the `Get-WindowsUpdateLog` cmdlet to retrieve the Windows Update log and formats it into a table for easy viewing. The table includes key troubleshooting information such as:
    - `TimeStamp`: The timestamp of the update event.
    - `KB`: The Knowledge Base (KB) ID of the update (if available).
    - `Title`: The title or description of the update (if available).
    - `Result`: The status of the update (Completed, Failed, or In Progress).
    - `ErrorCode`: The error code, if any, associated with a failed update.

    This function is designed for use in an MSP (Managed Service Provider) or troubleshooting context where identifying update failures, error codes, and the specifics of each update is important for problem resolution.

.PARAMETER ShowLogInConsole
    A switch parameter that, when set, will display the log results in the console. If not set, the function will not display the log in the console but will still retrieve the log for further use.

.EXAMPLE
    Get-WindowsUpdateLogAutomation -ShowLogInConsole
    Retrieves the Windows Update log and displays the relevant troubleshooting data (TimeStamp, KB, Title, Result, ErrorCode) in the console in a table format.

.OUTPUTS
    None (This function directly outputs the results in the console as a table).
    The output is displayed as a table containing information such as TimeStamp, KB, Title, Result, and ErrorCode.

.NOTES
    Author: Lachlan Alston
    Last Updated: 2025-10-28
    This function requires the `Get-WindowsUpdateLog` cmdlet, which is built into Windows 10 and later versions.
#>

function Get-WindowsUpdateLogAutomation {
    param(
        [switch]$ShowLogInConsole  # Option to display log in console as a table
    )
    
    try {
        Write-Host "Retrieving Windows Update log..." -ForegroundColor Green

        # Get the Windows Update logs
        $UpdateLog = Get-WindowsUpdateLog -ErrorAction Stop

        if ($UpdateLog) {
            Write-Host "`nWindows Update Log retrieved successfully:" -ForegroundColor Green
            Write-Host "--------------------------------------------------------"

            # If the switch to show in console is set, output the results as a table
            if ($ShowLogInConsole) {
                $UpdateLog | Select-Object `
                    @{Name='TimeStamp';Expression={$_.TimeStamp}}, `
                    @{Name='KB';Expression={($_.Message -match 'KB\d+') ? ($_.Message -replace '^.*(KB\d+).*$', '$1') : 'N/A'}}, `
                    @{Name='Title';Expression={($_.Message -match '.*update.*(.*?)\n') ? ($_.Message -replace '.*update.*(.*?)\n', '$1') : 'N/A'}}, `
                    @{Name='Result';Expression={if ($_.Message -match 'failed') { 'Failed' } elseif ($_.Message -match 'completed') { 'Completed' } else { 'In Progress' }}}, `
                    @{Name='ErrorCode';Expression={if ($_.Message -match '0x[0-9A-F]+') { ($_.Message -match '0x[0-9A-F]+') } else { 'N/A' }}}
                
                # Display the output as a formatted table
                | Format-Table -AutoSize
            }

        } else {
            Write-Host "`nNo Windows Update log data found." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "Failed to retrieve Windows Update log. Please check your system configuration." -ForegroundColor Red
        exit 1
    }
}
