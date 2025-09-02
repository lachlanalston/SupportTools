Write-Host "=== Windows 11 Compatibility Check ===" -ForegroundColor Cyan
Write-Host ""

$Compatible = $true

# --- TPM Check ---
$tpm = Get-Tpm
$tpmVersions = @()

if ($tpm.TpmPresent) {
    if ($tpm.SpecVersion) {
        $tpmVersions = $tpm.SpecVersion
    } else {
        # fallback to WMI if SpecVersion is blank
        $tpmWmi = Get-WmiObject -Namespace "Root\CIMv2\Security\MicrosoftTpm" -Class Win32_Tpm -ErrorAction SilentlyContinue
        if ($tpmWmi -and $tpmWmi.SpecVersion) {
            $tpmVersions = $tpmWmi.SpecVersion.Split(",")
        }
    }

    if ($tpmVersions -match "2\.0") {
        Write-Host "TPM: Present (Version $($tpmVersions -join ', '))" -ForegroundColor Green
    } else {
        Write-Host "TPM: Present but not version 2.0 (Found: $($tpmVersions -join ', '))" -ForegroundColor Yellow
        $Compatible = $false
    }
} else {
    Write-Host "TPM: Not Present" -ForegroundColor Red
    $Compatible = $false
}
Write-Host ""

# --- Secure Boot ---
try {
    $sb = Confirm-SecureBootUEFI
    if ($sb) {
        Write-Host "Secure Boot: Enabled" -ForegroundColor Green
    } else {
        Write-Host "Secure Boot: Disabled" -ForegroundColor Red
        $Compatible = $false
    }
} catch {
    Write-Host "Secure Boot: Not Supported on this system" -ForegroundColor Yellow
    $Compatible = $false
}
Write-Host ""

# --- CPU ---
$cpu = Get-CimInstance Win32_Processor
$cpuName = $cpu.Name
Write-Host "CPU: $cpuName [$($cpu.Manufacturer)]" -ForegroundColor White

# Basic CPU validation (Intel 8th Gen+, AMD Ryzen 2000+)
$intelOK = ($cpuName -match "Intel\(R\).*Core\(TM\)\s+i[3579]-(?:[8-9]\d{2,}|1[0-9]{3,})")
$amdOK   = ($cpuName -match "AMD Ryzen [2-9]\d{3,}")

if ($intelOK -or $amdOK) {
    Write-Host "CPU: Supported for Windows 11" -ForegroundColor Green
} else {
    Write-Host "CPU: May not be supported (Check Microsoft list)" -ForegroundColor Yellow
    $Compatible = $false
}
Write-Host ""

# --- RAM ---
$ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 2)
if ($ramGB -ge 4) {
    Write-Host "RAM: $ramGB GB" -ForegroundColor Green
} else {
    Write-Host "RAM: $ramGB GB (Below Windows 11 minimum of 4 GB)" -ForegroundColor Red
    $Compatible = $false
}
Write-Host ""

# --- Final Result ---
Write-Host "=== Final Result ===" -ForegroundColor Cyan
if ($Compatible) {
    Write-Host "This system IS compatible with Windows 11" -ForegroundColor Green
} else {
    Write-Host "This system is NOT compatible with Windows 11" -ForegroundColor Red
}
