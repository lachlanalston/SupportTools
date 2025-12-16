# ==========================================
# 3CX Configuration API Connection Test
# Uses /xapi/v1/Defs (official doc test)
# ==========================================

# -------- CONFIG --------
$BaseUrl  = "https://FQDN.3cx.com.au"   # 3CX FQDN + port (NO trailing slash)
$ClientId = "Enter Client ID Here"
$ApiKey   = "Enter API Key Here"

# -------- FUNCTIONS --------
function Write-Section {
    param([string]$Text)
    Write-Host "`n==================== $Text ====================" -ForegroundColor Cyan
}

function Write-SubSection {
    param([string]$Text)
    Write-Host "`n--- $Text ---" -ForegroundColor Yellow
}

# -------- START --------
Write-Section "3CX Configuration API Test"

try {
    # -------- REQUEST OAUTH TOKEN --------
    Write-SubSection "Requesting OAuth Access Token"

    $tokenBody = @{
        grant_type    = "client_credentials"
        client_id     = $ClientId
        client_secret = $ApiKey
    }

    $tokenResponse = Invoke-RestMethod `
        -Uri "$BaseUrl/connect/token" `
        -Method Post `
        -Body $tokenBody `
        -ContentType "application/x-www-form-urlencoded"

    if (-not $tokenResponse.access_token) {
        throw "No access token returned from OAuth endpoint."
    }

    $AccessToken = $tokenResponse.access_token

    Write-Host "✅Access token acquired!" -ForegroundColor Green
    Write-Host "Token details:" -ForegroundColor White
    Write-Host ($tokenResponse | ConvertTo-Json -Depth 5) -ForegroundColor Gray

    # -------- AUTH HEADER --------
    $Headers = @{
        "Authorization" = "Bearer $AccessToken"
        "Accept"        = "application/json"
    }

    # -------- TEST CONFIGURATION API --------
    Write-SubSection "Calling /xapi/v1/Defs to verify access"

    $defsResponse = Invoke-RestMethod `
        -Uri "$BaseUrl/xapi/v1/Defs?`$select=Id" `
        -Headers $Headers `
        -Method Get

    Write-Host "`nConfiguration API connection SUCCESSFUL!" -ForegroundColor Green
    Write-Host "Returned object count: $($defsResponse.value.Count)" -ForegroundColor White
    Write-Host "`nFull /Defs response:" -ForegroundColor White
    Write-Host ($defsResponse | ConvertTo-Json -Depth 5) -ForegroundColor Gray

}
catch {
    Write-Host "`nConfiguration API connection FAILED" -ForegroundColor Red
    Write-Host "Error message:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor White

    if ($_.Exception.Response -ne $null) {
        Write-Host "`nHTTP Response content:" -ForegroundColor Red
        try {
            $respStream = $_.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($respStream)
            $respBody = $reader.ReadToEnd()
            Write-Host $respBody -ForegroundColor White
        } catch {
            Write-Host "Could not read response stream." -ForegroundColor Red
        }
    }
}

Write-Section "Test Complete"
