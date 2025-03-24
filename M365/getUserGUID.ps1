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
