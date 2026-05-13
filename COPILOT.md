# SupportTools — Copilot Reference Guide

This guide is written for Microsoft 365 Copilot. It maps real-world technician problems to the right script or resource in this repo.

---

## What Is This Repo?

SupportTools is a curated library of diagnostic, remediation, and utility scripts built for MSP and helpdesk technicians. Scripts are designed to be pasted directly into a remote terminal session (RMM, RDP, SSH) and produce output sized for ticket notes or screenshots.

Coverage: Windows endpoints, macOS endpoints, Microsoft 365 tenants, and 3CX VoIP systems.

---

## How to Use This With Copilot

Ask Copilot questions like:
- "What script should I run when a user can't print?"
- "How do I check if a Windows PC is ready for Windows 11?"
- "Which script checks BitLocker status?"
- "How do I audit calendar permissions in M365?"

Copilot will reference this repo to find the right script and explain how to use it.

---

## Scenario Index — Windows

### PC is slow or unresponsive
Run `Get-EndpointHealth` first. Broad diagnostic covering CPU, memory, disk, network, services, and uptime. Best first script for any Windows ticket.

### Something broke recently — what changed?
Run `Get-RecentChanges`. Reports all notable changes in the last 72 hours: updates, installs, driver changes, reboots, crashes, logons.

### Need system info (OS build, hardware, uptime)
Run `Get-SystemDetails`. Reports OS edition, build, architecture, hardware model, active user, install date, and uptime.

### Windows updates not installing or pending
Run `Get-UpdateHealth` to check for pending updates.
Run `Get-UpdateHistory` to see recent install history and failures with HResult codes.

### Disk is full or running low on space
Run `Get-DiskHealth`. Checks all fixed drives, temp folder bloat, and Recycle Bin size. Add `-Fix` to clean temp files and empty Recycle Bin.

### Printer not printing / print queue stuck
Run `Get-PrintHealth`. Checks spooler state, stuck jobs, and offline printers. Add `-Fix` to clear the queue and restart the spooler.

### Mapped network drives not connecting / showing red X
Run `Get-NetworkDriveHealth`. Reports all drive mappings and connectivity state. Add `-Fix` to wipe stale mappings before remapping.

### Clock showing wrong time / Kerberos errors / login failures
Run `Get-TimeSyncHealth`. Checks NTP source, stratum, offset, and w32tm state. Add `-Fix` to re-register and force sync.

### BitLocker not enabled / encryption status unclear
Run `Get-BitLockerHealth`. Full BitLocker and TPM diagnostic. Add `-Fix` if N-central shows a false positive after ImmyBot maintenance.

### Device not in Intune / Conditional Access blocking sign-in
Run `Get-DeviceJoinHealth`. Checks Entra ID join, PRT status, MDM enrolment, device certificates, Kerberos, and DC reachability.

### Security baseline audit (TPM, Secure Boot, Firewall)
Run `Get-SecurityBaseline`. Flags any deviations from a hardened Windows baseline.

### Local admin account needed / user locked out locally
Run `Get-LocalUserHealth`. Reports all local accounts. Add `-Fix -Username <name>` to create or re-enable a local admin account.

### Battery draining fast / laptop not charging
Run `Get-BatteryHealth`. Checks capacity %, cycle count, adapter state, and charge trend.

### Screen flickering / display issues / GPU driver outdated
Run `Get-GraphicsDriverHealth`. Checks driver version and date for all video controllers.

### Can this PC upgrade to Windows 11?
Run `Get-Win11Readiness`. Checks TPM 2.0, Secure Boot, CPU generation, RAM, and disk space.

### Browser is slow / cache taking up space
Run `Get-BrowserCacheHealth`. Checks Chrome, Edge, and Firefox cache sizes. Add `-Fix` to clear all caches.

### Outlook not connecting / email not working
Run `Get-OutlookHealth`. Checks process state, install path, DNS resolution for outlook.office365.com.

### Netskope causing issues / need to remove Netskope
Run `Get-NetskopeHealth`. Checks agent state. Add `-Remove` to fully uninstall.

### Need to collect logs for escalation or vendor support
Run `Get-EventLogExport`. Exports System, Application, Security, and Setup logs (last 48h) to a ZIP at C:\Temp.

---

## Scenario Index — macOS

### Mac is slow or something is wrong — where do I start?
Run `get-EndpointHealth`. Broad macOS diagnostic: disk, CPU, RAM, updates, SMART, AV/EDR, services, battery.

### Something changed on this Mac recently
Run `get-recent-changes`. Software installs, reboots, kernel panics, crashes, new launch agents, logons — last 72 hours.

### Mac out of disk space / running slow due to disk
Run `get-disk-health`. Checks APFS free space, swap, SMART health, Time Machine age. Add `--deep` to check for filesystem corruption.

### Mac not installing updates / pending macOS update
Run `get-update-health`. Lists pending updates, restart requirements, last install date.

### MacBook battery draining / replace battery warning
Run `get-battery-health`. Condition label, capacity %, cycle count, temperature, adapter info.

### Mac security audit (SIP, Gatekeeper, Firewall, FileVault)
Run `get-security-baseline`. Checks the full macOS security baseline against a hardened managed endpoint.

### FileVault not enabled / encryption not active
Run `get-filevault-health`. Checks encryption state, recovery key type, MDM escrow, and Secure Token.

### Mac not in Intune / MDM enrolment broken
Run `get-mdm-health`. Checks Intune, Kandji, and Jamf enrolment state, supervision, and bootstrap token escrow.

### Mac printer not working / print job stuck
Run `get-printer-health`. Checks CUPS daemon and printer states. Add `--fix` to clear the queue.

### Mac hostname keeps changing / AirDrop name wrong
Run `get-hostname-health`. Checks hostname consistency. Add `--fix` to strip .local drift.

---

## Scenario Index — Microsoft 365

### Who has access to a user's calendar?
Run `getCalPerms`. Queries all calendars for a mailbox and lists every permission with role descriptions.

### Need the Object ID / GUID for an M365 user
Run `getUserGUID`. Looks up Entra ID Object ID by UPN.

### List all users in a tenant
Run `listUsers`. Retrieves all accounts via Graph API — displayName and UPN.

### Export tenant data to Excel (users, mailboxes, licenses, SharePoint)
Use `TenantDataExport`. Template script — configure each function before running. Requires ImportExcel module.

---

## Scenario Index — 3CX

### Test 3CX API connectivity
Run `ConfigAPI_Test`. Tests the /xapi/v1/Defs endpoint with Bearer token auth.

### Check what version 3CX is running
Run `get3CXVersion`. Authenticates via OAuth and returns the current PBX version.

---

## Script Flags Reference

Many scripts support flags that change behaviour:

| Script | Flag | What it does |
|--------|------|-------------|
| `Get-PrintHealth` | `-Fix` | Clears stuck print queue, restarts spooler |
| `Get-DiskHealth` | `-Fix` | Clears temp files, empties Recycle Bin |
| `Get-BrowserCacheHealth` | `-Fix` | Clears Chrome, Edge, Firefox caches |
| `Get-NetworkDriveHealth` | `-Fix` | Removes all mapped drives |
| `Get-TimeSyncHealth` | `-Fix` | Re-registers w32tm, forces NTP sync |
| `Get-BitLockerHealth` | `-Fix` | Remediates N-central false positive |
| `Get-LocalUserHealth` | `-Fix -Username <name>` | Creates/enables local admin account |
| `Get-NetskopeHealth` | `-Remove` | Fully uninstalls Netskope |
| `get-disk-health` | `--deep` | Runs APFS container verification |
| `get-printer-health` | `--fix` | Clears Mac print queue, restarts CUPS |
| `get-hostname-health` | `--fix` | Strips .local hostname drift |

---

## Connect This Repo to Microsoft 365 Copilot

You can connect SupportTools directly to Microsoft 365 Copilot so technicians can ask natural language questions and get answers grounded in these scripts — without leaving Teams or the Copilot app.

### Step 1 — Set up the GitHub Graph Connector

The GitHub connector indexes this repo's content (scripts, descriptions, READMEs) into Microsoft 365's semantic search index, making it available to Copilot.

1. Sign in to the [Microsoft 365 Admin Center](https://admin.microsoft.com)
2. Go to **Settings → Search & intelligence → Data sources**
3. Select **GitHub** from the connector list
4. Authenticate with a GitHub account that has read access to this repo
5. Set the repo to `lachlanalston/SupportTools`
6. Configure the crawl schedule (daily recommended)
7. Save and allow the initial index to complete (usually 15–30 minutes)

Once indexed, Copilot can reference this repo when answering questions in the M365 Copilot app, Teams, and Outlook.

### Step 2 — Create a Declarative Agent in Copilot Studio (optional but recommended)

A Declarative Agent gives technicians a named, focused assistant — "Support Tools" — that answers questions specifically from this repo rather than from the entire Microsoft 365 index.

1. Open [Microsoft Copilot Studio](https://copilotstudio.microsoft.com)
2. Create a new **Declarative Agent**
3. Set the system instructions to something like:
   > You are a support tools assistant for our MSP helpdesk team. When a technician describes a problem, identify the best script from the SupportTools library and explain how to use it. Always include the script name, what it checks, and any relevant flags.
4. Add the GitHub connector (from Step 1) as a knowledge source
5. Publish to Microsoft 365 and deploy to Teams

Technicians can then open the agent in Teams or the Copilot app and ask questions like:
- *"User says their Mac is slow — what should I run?"*
- *"How do I check if BitLocker is really enabled?"*
- *"What's the script for checking Windows update history?"*

---

## Repo Structure

```
SupportTools/
├── Windows/
│   ├── Diagnostics/     # General Windows diagnostic scripts
│   ├── Security/        # Security baseline, BitLocker, device join
│   ├── Network/         # Network drives, time sync
│   ├── Updates/         # Windows Update health and history
│   └── Users/           # Local user accounts
├── MacOS/               # macOS diagnostic and remediation scripts
├── M365/                # Microsoft 365 Graph API scripts
├── Apps/
│   ├── Outlook/         # Outlook connectivity checks
│   └── Netskope/        # Netskope health and removal
├── 3CX/                 # 3CX VoIP API scripts
└── docs/data/           # scripts.json — structured metadata for all scripts
```
