# Define URLs
$tokenUrl = 'https://pbx.3cx.com.au/connect/token'
$quickTestUrl = 'https://pbx.3cx.com.au/xapi/v1/Defs?$select=Id'

# Prepare body for token request
$body = @{
    client_id     = 'client_id'
    client_secret = 'client_secret'
    grant_type    = 'client_credentials'
}

try {
    # Get the access token
    $tokenResponse = Invoke-RestMethod -Uri $tokenUrl -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded'

    if ($tokenResponse.access_token) {
        $accessToken = $tokenResponse.access_token

        # Prepare headers for the GET request
        $headers = @{
            Authorization = "Bearer $accessToken"
        }

        # Send the GET request
        $response = Invoke-RestMethod -Uri $quickTestUrl -Headers $headers -Method Get

        # Output the success result
        Write-Output "Success:"
        $response | ConvertTo-Json -Depth 5
    }
    else {
        Write-Error "Access token not found in the response."
    }
}
catch {
    Write-Error "Error: $($_.Exception.Message)"
}
