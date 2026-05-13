<#
.SYNOPSIS
    Lists all users in a Microsoft 365 tenant via the Graph API.

.DESCRIPTION
    Authenticates using OAuth client credentials flow, then retrieves all user
    accounts from the tenant and outputs displayName and userPrincipalName.
    Use for tenant audits, account discovery, or verifying user provisioning.

.EXAMPLE
    .\listUsers.ps1
    # Prompts for Tenant ID, Client ID, and Client Secret.

.NOTES
    Author:  Lachlan Alston
    Requires: Microsoft Graph API app registration with User.Read.All permission.
#>

# Define variables
$tenantId = Read-Host "Enter Tenant ID"
$clientId = Read-Host "Enter Client ID"
$clientSecret = Read-Host "Enter Client Secret"
$scope = "https://graph.microsoft.com/.default"

# Request OAuth Token (Client Credentials Flow)
$tokenUrl = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"

# Define the body for the token request
$tokenBody = @{
    client_id     = $clientId
    client_secret = $clientSecret
    scope         = $scope
    grant_type    = "client_credentials"
}

# Request the token
$tokenResponse = Invoke-RestMethod -Uri $tokenUrl -Method Post -ContentType "application/x-www-form-urlencoded" -Body $tokenBody

# Extract the access token from the response
$accessToken = $tokenResponse.access_token

# Check if the token was successfully obtained
if ($accessToken) {
    Write-Output "Access token successfully obtained."
} else {
    Write-Error "Failed to obtain access token."
    exit
}

# Now use the token to call Microsoft Graph API to get a list of users
$headers = @{
    Authorization = "Bearer $accessToken"
    "Content-Type" = "application/json"
}

# Microsoft Graph API endpoint to get all users
$uri = "https://graph.microsoft.com/v1.0/users"

# Call Microsoft Graph API to get the list of users
$response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get

# Output the list of users (you can format this to show specific user details)
$response.value | Select-Object displayName, userPrincipalName | Format-Table
