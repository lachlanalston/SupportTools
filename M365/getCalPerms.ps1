# Define variables
$tenantId = Read-Host "Enter Tenant ID"
$clientId = Read-Host "Enter Client ID"
$clientSecret = Read-Host "Enter Client Secret"
$scope = "https://graph.microsoft.com/.default"

# Request body to get the access token
$body = @{
    client_id     = $clientId
    client_secret = $clientSecret
    grant_type    = "client_credentials"
    scope         = $scope
}

# Get the access token
$response = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" `
                             -Method Post `
                             -ContentType "application/x-www-form-urlencoded" `
                             -Body $body

# Check if we got a valid response
if ($response.access_token) {
    $accessToken = $response.access_token
} else {
    Write-Host "Error: Access token not received."
    exit
}

# Define the user's email address
$userId = "lachlan@alston.id.au"  # Replace with the target user's email address

# API to get user's calendars
$uri = "https://graph.microsoft.com/v1.0/users/$userId/calendars"

# Call the Microsoft Graph API to get the user's calendars
$headers = @{
    Authorization = "Bearer $accessToken"
}

$response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers

# Check if there are any calendars
if ($response.value.Count -eq 0) {
    Write-Host "No calendars found for user $userId"
    exit
}

# Function to explain permission roles
function Get-PermissionDescription {
    param (
        [string]$role
    )
    switch ($role) {
        "owner" { return "Owner: Full control, can create, delete, and modify events, and change permissions." }
        "editor" { return "Editor: Can create, modify, and delete events." }
        "delegate" { return "Delegate: Can view and manage the calendar, including creating, modifying, and deleting events." }
        "reader" { return "Reader: Can only view events." }
        "none" { return "None: No access." }
        "freeBusyRead" { return "Free/Busy Reader: Can view when a user is busy, but not the event details." }
        default { return "Unknown role." }
    }
}

# Loop through all calendars and get their permissions
foreach ($calendar in $response.value) {
    Write-Host "`n================================="
    Write-Host "Calendar Name: $($calendar.name)"
    Write-Host "================================="

    # Get the calendar ID
    $calendarId = $calendar.id

    # API to get the calendar permissions for the selected calendar
    $uriPermissions = "https://graph.microsoft.com/v1.0/users/$userId/calendars/$calendarId/calendarPermissions"

    # Call the Microsoft Graph API to get the calendar permissions
    $permissionsResponse = Invoke-RestMethod -Uri $uriPermissions -Method Get -Headers $headers

    # Check if permissions exist
    if ($permissionsResponse.value.Count -eq 0) {
        Write-Host "No permissions found for this calendar."
    } else {
        # Display permissions for the calendar
        $permissionsResponse.value | ForEach-Object {
            Write-Host "`n-- Permission Details --"
            # Check if the principal has an email address
            if ($_.emailAddress) {
                $principalName = $_.emailAddress.name
                $principalEmail = $_.emailAddress.address
                $permissionType = $_.role
                $permissionDescription = Get-PermissionDescription -role $permissionType

                Write-Host "Principal: $principalName"
                Write-Host "Email: $principalEmail"
                Write-Host "Permission Type: $permissionType"
                Write-Host "Permission Description: $permissionDescription"
            } elseif ($_.userPrincipalName -eq $userId) {
                # Handle the user principal
                $principalName = "User Principal"
                $principalEmail = $userId
                $permissionType = $_.role
                $permissionDescription = Get-PermissionDescription -role $permissionType

                Write-Host "Principal: $principalName"
                Write-Host "Email: $principalEmail"
                Write-Host "Permission Type: $permissionType"
                Write-Host "Permission Description: $permissionDescription"
            } else {
                # For other types of principals (external)
                $principalName = "External User"
                $principalEmail = "N/A"
                $permissionType = $_.role
                $permissionDescription = Get-PermissionDescription -role $permissionType

                Write-Host "Principal: $principalName"
                Write-Host "Email: $principalEmail"
                Write-Host "Permission Type: $permissionType"
                Write-Host "Permission Description: $permissionDescription"
            }
            Write-Host "-----------------------------"
        }
    }
}

Write-Host "`nScript completed successfully."
