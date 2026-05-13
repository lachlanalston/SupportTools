# Windows / Network

Scripts for diagnosing and fixing Windows network configuration issues.

## Scripts

| Script | When to use |
|--------|-------------|
| `Get-NetworkDriveHealth` | Mapped drives showing a red X, disconnecting after login, or UNC paths not accessible. |
| `Get-TimeSyncHealth` | Clock showing wrong time, Kerberos errors, or login failures related to time skew. |

## Common Scenarios

**Mapped drives disconnect on every login:**
```powershell
.\Get-NetworkDriveHealth.ps1
# If stale mappings need clearing before MDM remaps them:
.\Get-NetworkDriveHealth.ps1 -Fix
```

**Kerberos authentication failing / clock wrong:**
```powershell
.\Get-TimeSyncHealth.ps1
# To re-register w32tm and force a sync:
.\Get-TimeSyncHealth.ps1 -Fix
```
