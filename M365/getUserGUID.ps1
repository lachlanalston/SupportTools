<#
.SYNOPSIS
    Looks up a user's Object ID (GUID) from Microsoft Graph by UPN.

.DESCRIPTION
    Connects to Microsoft Graph and queries for a user by their User Principal Name,
    returning the Entra ID Object ID. Useful when a GUID is needed for API calls,
    Intune targeting, or Conditional Access troubleshooting.

.EXAMPLE
    .\getUserGUID.ps1
    # Prompts for client domain and target UPN.

.NOTES
    Author:  Lachlan Alston
    Requires: MSGraph PowerShell module and appropriate read permissions.
#>

# Connect to Microsoft Graph
Connect-MSGraph -Domain (Read-Host "Enter Client Domain (e.g., example.com)")

# Prompt user for the User Principal Name (UPN)
$upn = Read-Host "Enter the User Principal Name (UPN) of the user (e.g., user@domain.com)"

# Get the user object from Graph
$user = Invoke-MSGraph -DCP_resource "users" | Where-Object { $_.userPrincipalName -eq $upn }

# Check if the user object was found
if ($user) {
    # Output: User GUID (Object ID)
    Write-Output "`nUser GUID (Object ID) for ${upn}: $($user.id)"
} else {
    # Error message if the user is not found
    Write-Error "Error: User not found with UPN: $upn"
}
