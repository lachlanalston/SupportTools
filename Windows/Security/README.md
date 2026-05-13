# Windows / Security

Scripts for checking and troubleshooting Windows security configuration, encryption, and device identity.

## Scripts

| Script | When to use |
|--------|-------------|
| `Get-SecurityBaseline` | Security audit — checks Secure Boot, TPM, Fast Startup, and Windows Firewall. |
| `Get-BitLockerHealth` | BitLocker showing as not enabled, Intune compliance failing for encryption, or N-central false positive after ImmyBot. |
| `Get-DeviceJoinHealth` | Device not in Intune, Conditional Access blocking sign-in, PRT expired, hybrid join broken. |

## Common Scenarios

**N-central reports BitLocker off after ImmyBot maintenance:**
```powershell
.\Get-BitLockerHealth.ps1 -Fix
```

**User getting Conditional Access error on sign-in:**
```powershell
.\Get-DeviceJoinHealth.ps1
```
Check PRT status, device certificate expiry, and MDM last sync in the output.

**Pre-deployment security check:**
```powershell
.\Get-SecurityBaseline.ps1
```
