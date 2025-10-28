function Verify-FastStartupDisabled {
    <#
    .SYNOPSIS
        Checks if Fast Startup is disabled on the system.

    .DESCRIPTION
        Verifies the state of Fast Startup by checking the registry value.
        Returns $true if Fast Startup is disabled, $false if enabled, or error occurs.

    .OUTPUTS
        [bool] True if Fast Startup is disabled, otherwise False.
    #>

    try {
        $fastStartupRegistryKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Power"
        $fastStartupValue = "HiberbootEnabled"
        
        # Check if registry key exists
        if (Test-Path $fastStartupRegistryKey) {
            $fastStartupState = Get-ItemProperty -Path $fastStartupRegistryKey -Name $fastStartupValue -ErrorAction Stop
            if ($fastStartupState.$fastStartupValue -eq 0) {
                Write-Verbose "Fast Startup is disabled."
                return $true
            }
            else {
                Write-Verbose "Fast Startup is enabled."
                return $false
            }
        }
        else {
            Write-Verbose "Fast Startup registry key does not exist or is unsupported on this system."
            return $false
        }
    }
    catch [System.UnauthorizedAccessException] {
        Write-Verbose "Fast Startup check failed: Access denied. Run as Administrator."
        return $false
    }
    catch {
        Write-Verbose "Fast Startup check failed: $($_.Exception.Message)"
        return $false
    }
}
