# Windows / Updates

Scripts for checking Windows Update state and history.

## Scripts

| Script | When to use |
|--------|-------------|
| `Get-UpdateHealth` | Check if a device has pending updates — mandatory or optional. |
| `Get-UpdateHistory` | See what updates were installed recently and check for failures with HResult codes. |

## Common Scenarios

**Device missing patches / update compliance check:**
```powershell
.\Get-UpdateHealth.ps1
```

**Update keeps failing — need to see the error:**
```powershell
.\Get-UpdateHistory.ps1
```
Look for HResult codes in the FAILURES section of the output.

**Did a specific patch install after Patch Tuesday?**
```powershell
.\Get-UpdateHistory.ps1
```
The 10 most recent entries are listed with install date.
