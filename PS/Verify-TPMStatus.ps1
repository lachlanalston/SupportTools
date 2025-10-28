function Check-TPMStatus {
    <#
    .SYNOPSIS
        Checks if TPM is enabled and working on the system.
    .DESCRIPTION
        Uses Get-Tpm cmdlet to check if TPM is enabled, present, and ready.
    .OUTPUTS
        [bool] Returns $True if TPM is enabled and working, otherwise $False.
    #>

    try {
        # Get TPM status
        $tpm = Get-Tpm -ErrorAction Stop

        # Return True if TPM is present and ready
        if ($tpm.TpmPresent -and $tpm.TpmReady) {
            return $true
        }
        else {
            return $false
        }
    }
    catch {
        # Catch any error and return False if TPM is not available or there is an issue
        return $false
    }
}
