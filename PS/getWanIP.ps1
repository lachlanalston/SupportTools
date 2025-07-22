try {
    $wanIp = (Invoke-RestMethod -Uri "https://www.cloudflare.com/cdn-cgi/trace" -UseBasicParsing) -split "`n" |
        Where-Object { $_ -like "ip=*" } |
        ForEach-Object { ($_ -split "=")[1] }

    Write-Output "WAN IP: $wanIp"
} catch {
    Write-Error "Failed to retrieve WAN IP: $_"
}
