function Verify-SecureBootEnabled {
    <#
    .SYNOPSIS
        Checks if Secure Boot is enabled on the system.

    .DESCRIPTION
        Uses Confirm-SecureBootUEFI to determine if Secure Boot is enabled.
        Returns $true if enabled, $false if disabled, unsupported, or error occurs.

    .OUTPUTS
        [bool] True if Secure Boot is enabled, otherwise False.
    #>

    try {
        return [bool](Confirm-SecureBootUEFI -ErrorAction Stop)
    }
    catch [System.UnauthorizedAccessException] {
        Write-Verbose "Secure Boot check failed: Access denied. Run as Administrator."
        return $false
    }
    catch [System.InvalidOperationException] {
        Write-Verbose "Secure Boot check failed: Platform does not support UEFI or Secure Boot."
        return $false
    }
    catch {
        Write-Verbose "Secure Boot check failed: $($_.Exception.Message)"
        return $false
    }
}
