# Ensure script is run as Administrator
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(`
    [Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Error "Please run PowerShell as Administrator"
    return $false
}

# Define preferred NTP servers
$ntpServers = @(
    "0.au.pool.ntp.org",
    "1.au.pool.ntp.org",
    "2.au.pool.ntp.org",
    "3.au.pool.ntp.org",
    "time.cloudflare.com",
    "time.google.com",
    "time.windows.com"
)

# Function to test ping and return fastest server
function Get-FastestNtpServer {
    $results = @()
    foreach ($server in $ntpServers) {
        try {
            $ping = Test-Connection -Count 1 -ComputerName $server -Quiet -ErrorAction Stop
            if ($ping) {
                $rtt = (Test-Connection -Count 1 -ComputerName $server).ResponseTime
                $results += [PSCustomObject]@{Server=$server;Latency=$rtt}
            }
        } catch {
            Write-Warning "Failed to reach $server"
        }
    }
    return ($results | Sort-Object Latency | Select-Object -First 1).Server
}

# Pick fastest reachable server
$bestServer = Get-FastestNtpServer
if (-not $bestServer) {
    Write-Error "No NTP servers are reachable"
    return $false
}
Write-Host "Fastest NTP server: $bestServer"

# Check if w32time service exists
$service = Get-Service -Name w32time -ErrorAction SilentlyContinue

if ($service) {
    Write-Host "Stopping Windows Time service..."
    Stop-Service w32time -Force
    Start-Sleep -Seconds 2

    Write-Host "Unregistering Windows Time service..."
    w32tm /unregister | Out-Null
    Start-Sleep -Seconds 2
} else {
    Write-Host "w32time service not found. Registering it fresh..."
}

Write-Host "Registering Windows Time service..."
w32tm /register | Out-Null
Start-Sleep -Seconds 2

Write-Host "Starting Windows Time service..."
Start-Service w32time
Start-Sleep -Seconds 2

# Configure selected NTP server
Write-Host "Configuring NTP server to $bestServer..."
w32tm /config /manualpeerlist:"$bestServer,0x1" /syncfromflags:manual /reliable:yes /update | Out-Null

# Resync time
Write-Host "Resyncing time..."
$syncResult = w32tm /resync /nowait 2>&1
Start-Sleep -Seconds 3

# Check offset using updated regex to match time output
$offsetOutput = w32tm /stripchart /computer:$bestServer /samples:1 /dataonly 2>&1
$lastLine = $offsetOutput[-1]

if ($lastLine -match "[\d:,]+\s*,\s*([+-]?\d+\.\d+)s") {
    $offset = [double]$matches[1]
    if ([math]::Abs($offset) -lt 5) {
        Write-Host "Time sync successful. Offset: $offset seconds"
        return $true
    } else {
        Write-Warning "Time synced, but offset too large: $offset seconds"
        return $false
    }
} else {
    Write-Warning "Failed to determine time offset. Output: $offsetOutput"
    return $false
}
