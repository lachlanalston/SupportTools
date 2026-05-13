# Windows / Diagnostics

General-purpose diagnostic scripts for Windows endpoints. Most are safe to paste into any remote terminal session — RMM, RDP, or PowerShell remoting.

## Scripts

| Script | When to use |
|--------|-------------|
| `Get-EndpointHealth` | First script to run on any Windows ticket. Broad triage: CPU, memory, disk, network, services, uptime. |
| `Get-SystemDetails` | Need hardware info, OS build, or uptime for a ticket. |
| `Get-RecentChanges` | Something broke recently — shows all changes in last 72 hours. |
| `Get-EventLogExport` | Need to send logs to a vendor or attach to an escalation. |
| `Get-BatteryHealth` | Laptop battery draining fast or not charging. |
| `Get-DiskHealth` | Low disk space, temp bloat, or Recycle Bin filling up. Use `-Fix` to clean. |
| `Get-BrowserCacheHealth` | Browser slow or cache taking up space. Use `-Fix` to clear. |
| `Get-GraphicsDriverHealth` | Screen flickering, display issues, or outdated GPU driver. |
| `Get-PrintHealth` | Printer not printing, stuck jobs, or spooler crashing. Use `-Fix` to clear queue. |
| `Get-Win11Readiness` | Check if a PC can upgrade to Windows 11 before attempting. |

## Usage

All scripts are read-only by default. Scripts with a `-Fix` flag only remediate when that flag is passed explicitly.

```powershell
# Run diagnostics only
.\Get-EndpointHealth.ps1

# Run and remediate
.\Get-DiskHealth.ps1 -Fix
.\Get-PrintHealth.ps1 -Fix
```
