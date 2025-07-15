$pbxFqdn = 'pbx.3cx.com.au'
$clientId = 'CLIENT_ID'
$clientSecret = 'CLIENT_SECRET'
$tokenUrl = "https://$pbxFqdn/connect/token"
$apiUrl = "https://$pbxFqdn/xapi/v1/Defs`?\$select=Id"

$body = @{
    grant_type    = 'client_credentials'
    client_id     = $clientId
    client_secret = $clientSecret
    scope         = 'xapi'
}

$response = Invoke-RestMethod -Uri $tokenUrl -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded'
$accessToken = $response.access_token

$headers = @{
    Authorization = "Bearer $accessToken"
}

$response = Invoke-WebRequest -Uri $apiUrl -Headers $headers -Method Get

if ($response.StatusCode -eq 200) {
    $version = $response.Headers['X-3CX-Version']
    Write-Host "3CX Version: $version"
} else {
    Write-Host "Failed to retrieve version. Status code: $($response.StatusCode)"
}
