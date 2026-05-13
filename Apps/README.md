# Apps

Scripts for checking and remediating specific third-party application health on Windows endpoints.

## Scripts

| Script | When to use |
|--------|-------------|
| `Outlook/Get-OutlookHealth.ps1` | Outlook not opening, can't connect to Exchange, or DNS/connectivity failures. |
| `Netskope/Get-NetskopeHealth.ps1` | Netskope agent not running, blocking traffic, or needs to be fully removed. |

## Common Scenarios

**Outlook won't connect to Microsoft 365:**
```powershell
.\Outlook\Get-OutlookHealth.ps1
```
Checks if Outlook is installed, whether it's running, and if DNS resolves outlook.office365.com.

**Netskope causing connectivity problems:**
```powershell
.\Netskope\Get-NetskopeHealth.ps1
```

**Completely remove Netskope (service, MSI, certs, roaming data):**
```powershell
.\Netskope\Get-NetskopeHealth.ps1 -Remove
```
