$user = "username"
$pass = ConvertTo-SecureString "CHANGE_ME" -AsPlainText -Force

# Create user if missing
if (-not (Get-LocalUser -Name $user -ErrorAction SilentlyContinue)) {
    New-LocalUser -Name $user -Password $pass
}

# Configure user
Enable-LocalUser -Name $user
Set-LocalUser -Name $user -PasswordNeverExpires $true -AccountNeverExpires
Add-LocalGroupMember -Group "Administrators" -Member $user -ErrorAction SilentlyContinue

# Output
Write-Host "`nLocal Admin Account Status" -ForegroundColor Cyan
Get-LocalUser -Name $user | Select-Object `
    Name,
    Enabled,
    PasswordNeverExpires,
    AccountExpires,
    @{Name="IsAdmin";Expression={
        (Get-LocalGroupMember Administrators -ErrorAction SilentlyContinue |
         Where-Object Name -Match $user) -ne $null
    }} | Format-Table -AutoSize
