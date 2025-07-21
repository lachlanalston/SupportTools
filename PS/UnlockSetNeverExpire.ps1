$user = "username"

# Get BEFORE values
$before = @(Get-CimInstance -ClassName Win32_UserAccount -Filter "Name='$user'" |
    Select-Object Name,
                  @{Name="State";Expression={"Before"}},
                  Disabled,
                  PasswordExpires)

# Action description
$changeSummary = "Enabled user + Set PasswordNeverExpires"

# Apply changes (commented out)
Enable-LocalUser -Name $user
Set-LocalUser -Name $user -PasswordNeverExpires $true

# Get AFTER values
$after = @(Get-CimInstance -ClassName Win32_UserAccount -Filter "Name='$user'" |
    Select-Object Name,
                  @{Name="State";Expression={"After"}},
                  Disabled,
                  PasswordExpires,
                  @{Name="Changes";Expression={$changeSummary}})

# Output BEFORE section
Write-Host "`n=== BEFORE CHANGES ===" -ForegroundColor Yellow
$before | Format-Table Name, State, Disabled, PasswordExpires

# Output AFTER section
Write-Host "`n=== AFTER CHANGES ===" -ForegroundColor Green
$after | Format-Table Name, State, Disabled, PasswordExpires, Changes
