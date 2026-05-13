# Windows / Users

Scripts for managing local user accounts on Windows endpoints.

## Scripts

| Script | When to use |
|--------|-------------|
| `Get-LocalUserHealth` | Audit local accounts, check who has admin, or check password/expiry state. Create or re-enable a local admin account with `-Fix`. |

## Common Scenarios

**Need a break-glass local admin account:**
```powershell
.\Get-LocalUserHealth.ps1 -Fix -Username support
```
Creates or re-enables the specified account with admin rights and a non-expiring password.

**Check who has local admin on a device:**
```powershell
.\Get-LocalUserHealth.ps1
```

**User locked out and can't log in via normal methods:**
```powershell
.\Get-LocalUserHealth.ps1 -Fix -Username <name>
```
