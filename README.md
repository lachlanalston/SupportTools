# SupportTools

A curated toolbox of scripts, utilities, and DNS references built for MSPs and helpdesk techs.

Browse everything at **[tools.lrfa.dev](http://tools.lrfa.dev)** — scripts, commands, shortcuts, bookmarks, and RFCs, all searchable in one place.

---

## What's Inside

- PowerShell scripts for Windows diagnostics, remediation, and automation
- Bash scripts for macOS endpoint troubleshooting
- PowerShell scripts for Microsoft 365 and 3CX API interactions
- Quick-reference commands and shortcuts for common helpdesk tasks

## Built For

- MSPs, sysadmins, and helpdesk teams
- Fast triage, audits, reporting, and cleanup
- Windows and macOS environments with Microsoft 365 and 3CX integrations

---

## Quick Reference — Tech Sees X, Run Y

| Symptom | Script |
|---------|--------|
| PC slow / general triage | `Get-EndpointHealth` |
| Something broke recently | `Get-RecentChanges` |
| Printer not printing / stuck queue | `Get-PrintHealth -Fix` |
| Low disk space | `Get-DiskHealth -Fix` |
| Network drives missing / red X | `Get-NetworkDriveHealth` |
| Clock wrong / Kerberos errors | `Get-TimeSyncHealth -Fix` |
| BitLocker showing as off | `Get-BitLockerHealth` |
| Device not in Intune / CA blocking | `Get-DeviceJoinHealth` |
| Outlook not connecting | `Get-OutlookHealth` |
| Can this PC run Windows 11? | `Get-Win11Readiness` |
| Need event logs for escalation | `Get-EventLogExport` |
| Mac slow / general triage | `get-EndpointHealth.sh` |
| Mac printer stuck | `get-printer-health.sh --fix` |
| Mac not in Intune | `get-mdm-health.sh` |
| Who can see this calendar? | `getCalPerms.ps1` |

---

## Connect to Microsoft 365 Copilot

> SupportTools is designed to connect directly to **Microsoft 365 Copilot**, so technicians can ask natural language questions and get grounded, accurate answers from these scripts — right inside Teams or the Copilot app. No more hunting through documentation or the website.
>
> To set it up, see **[COPILOT.md](./COPILOT.md)** for step-by-step instructions on connecting this repo via the GitHub Graph Connector and optionally building a Declarative Agent in Copilot Studio.

---

## Repo Structure

```
Windows/
├── Diagnostics/    PowerShell diagnostics for Windows endpoints
├── Security/       BitLocker, device join, security baseline
├── Network/        Network drives, time sync
├── Updates/        Windows Update health and history
└── Users/          Local user account management

MacOS/              Bash diagnostics for macOS endpoints
M365/               Microsoft 365 Graph API scripts
Apps/               App-specific scripts (Outlook, Netskope)
3CX/                3CX VoIP API scripts
docs/data/          Structured metadata (scripts.json, commands.json)
```

---

Built and maintained by a working MSP tech. Star the repo if you find it useful.
