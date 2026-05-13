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

<!-- GEN:START -->

## Scenario Index — Windows — Diagnostics

### `Get-EndpointHealth`
Comprehensive MSP diagnostic tool. Checks CPU, memory, disk, network, services, and uptime. Paste into a remote terminal session.

**Use when:**
- PC running slow
- general endpoint triage
- first script to run on a new ticket
- computer performance issues
- endpoint health check
- device not responding properly
- user says computer is slow
- broad diagnostic before escalating

### `Get-EventLogExport`
Exports System, Application, Security, and Setup event logs (last 48h) to a ZIP of rendered XML. Output goes to C:\Temp.

**Use when:**
- need to send logs to a vendor
- escalation requires event logs
- gather evidence for a ticket
- attach Windows logs to support case
- export event viewer logs
- collect logs before reimaging

### `Get-RecentChanges`
Reports all notable changes on a Windows endpoint in the last 72 hours including updates, installs, driver changes, reboots, crashes, and logons.

**Use when:**
- something changed and now it's broken
- user says it stopped working recently
- what happened on this PC yesterday
- after a crash what changed
- software installed without permission
- PC rebooted unexpectedly
- recent driver changes causing issues

### `Get-SystemDetails`
Reports OS edition, feature update version, build, architecture, hardware manufacturer and model, active user, install date, and uptime. Warns if uptime exceeds 14 days.

**Use when:**
- what OS version is this PC running
- what hardware is this device
- need system info for a ticket
- check Windows build number
- device uptime too long
- what model is this computer
- asset info for a support case

### `Get-GraphicsDriverHealth`
Checks GPU driver version and date for all installed video controllers. Warns if any driver is older than 365 days. Works for NVIDIA, AMD, Intel, and any vendor.

**Use when:**
- screen flickering
- black screen on second monitor
- display not working properly
- graphics glitch or artifact
- GPU driver outdated
- monitor keeps disconnecting
- video driver issues

### `Get-Win11Readiness`
Checks Windows 11 upgrade readiness: TPM 2.0, Secure Boot, CPU generation, RAM (4 GB min), and disk space (64 GB min). Reports CRIT for hard blockers.

**Use when:**
- can this PC upgrade to Windows 11
- TPM 2.0 check
- is this hardware compatible with Windows 11
- Windows 11 upgrade blocked
- check Secure Boot for Windows 11
- PC not eligible for Windows 11

### `Get-PrintHealth`
Checks print spooler health, stuck jobs, and offline printer states. Run with -Fix to stop the spooler, clear job files, and restart.

**Use when:**
- printer not printing
- print job stuck in queue
- printer showing offline
- print spooler crashing
- can't print anything
- print queue jammed
- printer keeps going offline

**Flags:**
| Flag | When to use |
|------|-------------|
| `-Fix` | Jobs are stuck in the queue and not clearing automatically — stops the spooler, wipes job files, and restarts it. |

### `Get-DiskHealth`
Checks free space on all fixed drives (CRIT ≤5%, WARN ≤15%), temp folder bloat, and Recycle Bin size. Run with -Fix to clear temp files and empty the Recycle Bin.

**Use when:**
- low disk space warning
- C drive is full
- PC running slow due to disk
- not enough space to install software
- disk cleanup needed
- temp folder too large
- Recycle Bin taking up space

**Flags:**
| Flag | When to use |
|------|-------------|
| `-Fix` | Temp folder or Recycle Bin is bloated and you want to reclaim space immediately without manual cleanup. |

### `Get-BrowserCacheHealth`
Checks Chrome, Edge, and Firefox cache sizes across all user profiles. Warns if any browser cache exceeds 500 MB. Run with -Fix to clear all caches.

**Use when:**
- browser running slow
- Chrome using too much disk space
- Edge cache too large
- browser cache bloated
- websites loading slowly
- browser performance issues
- clear browser cache remotely

**Flags:**
| Flag | When to use |
|------|-------------|
| `-Fix` | Browser cache is bloated and causing slowness or storage pressure — clears all detected caches across every user profile on the device. |

### `Get-BatteryHealth`
Checks battery health, capacity %, cycle count, charge state, and adapter info. Parses powercfg /batteryreport for capacity trend and flat-discharge history. Handles multi-battery devices and desktop/VM gracefully.

**Use when:**
- laptop battery draining too fast
- laptop not charging
- battery health check
- how many charge cycles on this battery
- battery capacity degraded
- laptop dies quickly
- does this battery need replacing


## Scenario Index — Windows — Security

### `Get-SecurityBaseline`
Checks Windows security baseline: Secure Boot, TPM presence and readiness, Fast Startup state, and Windows Firewall profile status. Flags CRIT/WARN for any failures.

**Use when:**
- security audit for an endpoint
- Secure Boot not enabled
- TPM not detected
- Windows Firewall disabled
- compliance check failed
- device failing security policy
- check device security posture

### `Get-DeviceJoinHealth`
Checks device join health across Entra ID, domain, and hybrid environments. Reports join type, PRT status and age, device certificate expiry, MDM enrolment and last sync, domain secure channel, DC reachability, machine account password age, and Kerberos ticket availability.

**Use when:**
- device not showing in Intune
- conditional access blocking sign-in
- PRT expired or missing
- Azure AD join broken
- device certificate expired
- MDM not syncing
- Kerberos failing
- hybrid join not working
- user getting access denied after domain join

### `Get-BitLockerHealth`
Checks BitLocker encryption status and TPM health on the C: drive. Reports protection status, encryption method, disk mode, key protectors, PCR validation profile, TPM state, Secure Boot, and UEFI vs Legacy BIOS. Flags issues relevant to Intune compliance.

**Use when:**
- BitLocker showing as not enabled
- drive not encrypted
- N-central reports BitLocker off after ImmyBot
- Intune compliance failing for encryption
- BitLocker suspended
- TPM not ready for BitLocker
- encryption status unclear

**Flags:**
| Flag | When to use |
|------|-------------|
| `-Fix` | N-central / N-able reports BitLocker as not enabled after ImmyBot maintenance |


## Scenario Index — Windows — Network

### `Get-NetworkDriveHealth`
Reports mapped network drives and their connectivity state. Warns on disconnected drives. Run with -Fix to remove all mapped drives.

**Use when:**
- network drives not connecting
- mapped drives showing red X
- drive disappears after login
- user can't access shared folders
- network drive disconnected
- mapped drive not available
- UNC path not accessible

**Flags:**
| Flag | When to use |
|------|-------------|
| `-Fix` | Disconnected or stale drive mappings need to be wiped before remapping via login script or MDM policy. |

### `Get-TimeSyncHealth`
Checks Windows Time service health, NTP source, stratum, last sync time, and time offset. Run with -Fix to re-register w32time and sync to the fastest reachable AU/global NTP server.

**Use when:**
- clock showing wrong time
- time out of sync on Windows
- Kerberos authentication errors
- login failing due to time skew
- w32tm not working
- NTP sync failing
- time drift causing issues

**Flags:**
| Flag | When to use |
|------|-------------|
| `-Fix` | Time is drifting or the w32time service is broken — re-registers the service, sets a reliable NTP source, and forces an immediate sync. |


## Scenario Index — Windows — Updates

### `Get-UpdateHealth`
Checks for pending Windows updates using the Windows Update COM API. Flags mandatory updates as CRIT and optional updates as WARN.

**Use when:**
- Windows not installing updates
- device missing patches
- Patch Tuesday check
- update compliance report
- how do I check if Windows is up to date
- pending updates not installing

### `Get-UpdateHistory`
Reports Windows Update install history — last successful install date, recent failures with HResult codes, and a list of the 10 most recent entries.

**Use when:**
- when did last update install
- update keeps failing
- what updates were installed recently
- HResult error from Windows Update
- update failure history
- check if a specific patch was installed


## Scenario Index — Windows — Users

### `Get-LocalUserHealth`
Reports all local user accounts, enabled state, admin membership, password expiry, and last logon. Run with -Fix -Username <name> to create/enable a local admin account with non-expiring password.

**Use when:**
- user locked out of local account
- need a local admin account
- break-glass account needed
- local account disabled
- password expired on local account
- who has local admin on this device
- create emergency local login

**Flags:**
| Flag | When to use |
|------|-------------|
| `-Fix -Username <name>` | You need to create or re-enable a local admin account — typically for emergency access or a break-glass account when normal login paths are unavailable. |


## Scenario Index — macOS

### `get-printer-health`
Checks CUPS daemon state, printer states (idle/stopped/error), stuck print jobs, default printer, and print sharing. Run with --fix to cancel all queued jobs, re-enable stopped printers, and restart the CUPS daemon.

**Use when:**
- Mac printer not working
- print job stuck on Mac
- CUPS daemon not running
- printer showing stopped on Mac
- can't print from Mac
- Mac print queue jammed

**Flags:**
| Flag | When to use |
|------|-------------|
| `--fix` | Jobs are stuck in the queue and not clearing — cancels all queued jobs, re-enables stopped printers, and restarts the CUPS daemon. |

### `get-security-baseline`
Checks the macOS security baseline: SIP, Gatekeeper, Firewall, FileVault, Secure Boot (T2 and Apple Silicon), XProtect and MRT versions, and remote access state (SSH, Screen Sharing). Flags anything that deviates from a hardened managed endpoint.

**Use when:**
- Mac security audit
- SIP disabled on Mac
- Gatekeeper turned off
- macOS firewall not enabled
- Mac failing compliance check
- check Mac security posture
- SSH unexpectedly enabled on Mac

### `get-update-health`
Checks pending macOS updates by name, whether a restart is required, last successful install date, and recent update history. Flags the restart-required + long-uptime combination as CRIT. softwareupdate runs in the background to keep total time under 30s.

**Use when:**
- Mac not installing updates
- pending macOS update
- Mac needs a restart for updates
- softwareupdate check
- macOS version out of date
- how long since last update on Mac

### `get-battery-health`
Checks battery health, condition label (Normal / Replace Soon / Replace Now / Service Battery), capacity %, cycle count, temperature, charge state, adapter info, and recent low-battery events from the power log. Handles desktop Macs gracefully.

**Use when:**
- MacBook battery draining fast
- Mac says replace battery
- MacBook not charging
- battery health check Mac
- how many cycles on MacBook battery
- Mac battery condition warning

### `get-disk-health`
Checks APFS container free space, swap usage, SMART health and sector counts, Time Machine backup age, and live I/O load. Flags the high-swap + low-disk combination that causes most macOS performance complaints. Run with --deep to also verify the APFS container for filesystem corruption (adds 20-60s).

**Use when:**
- Mac running slow
- Mac out of disk space
- APFS volume full
- Mac using too much swap
- Time Machine backup old
- SMART disk warning on Mac
- Mac performance degraded due to disk

**Flags:**
| Flag | When to use |
|------|-------------|
| `--deep` | User reports data corruption, unexpected crashes, or disk errors in Console — runs diskutil verifyContainer to check for APFS filesystem corruption (adds 20–60s). |

### `get-filevault-health`
Checks FileVault encryption status, recovery key type (personal or institutional), MDM escrow profile presence, and Secure Token state for the logged-in user. Flags missing keys, deferred encryption, and escrow not configured.

**Use when:**
- FileVault not enabled on Mac
- Mac encryption status
- FileVault recovery key missing
- MDM escrow not configured
- Mac failing encryption compliance
- Secure Token missing for user
- FileVault deferred and not activating

### `get-mdm-health`
Checks MDM enrolment health across Intune, Kandji, and Jamf. Reports enrolment status, provider detection, supervision state, bootstrap token escrow (Apple Silicon), and provider-specific agent health. Flags Jamf presence as a phase-out advisory.

**Use when:**
- Mac not showing in Intune
- MDM enrolment broken on Mac
- Kandji not enrolling Mac
- Jamf agent not running
- Mac not supervised
- bootstrap token not escrowed
- Company Portal issues on Mac

### `get-EndpointHealth`
Broad endpoint health check for macOS. Runs all checks in parallel — disk space, CPU load, RAM availability, pending updates, SMART disk health, AV/EDR presence, critical system services, and battery capacity. Outputs findings and detail blocks sized for ticket screenshots.

**Use when:**
- Mac running slow
- general Mac triage
- first script to run on a Mac ticket
- Mac endpoint health check
- broad Mac diagnostic
- user says Mac is slow or broken

### `get-recent-changes`
Reports all notable changes on a macOS endpoint in the last 72 hours — software installs, reboots, kernel panics, application crashes, new LaunchDaemons/Agents, driver changes, and user logons. Outputs a FINDINGS block, a categorised change timeline, and a plain-text ticket note.

**Use when:**
- something changed on Mac and now it's broken
- Mac started crashing recently
- software installed on Mac without permission
- kernel panic after recent change
- what happened on this Mac yesterday
- Mac rebooted unexpectedly

### `get-hostname-health`
Checks macOS hostname consistency across ComputerName, HostName, and LocalHostName. Flags .local suffix drift caused by Bluetooth or AirDrop activity, unset HostName, and mismatches between values. Run with --fix to strip .local suffixes automatically.

**Use when:**
- Mac hostname keeps changing
- AirDrop name wrong
- Mac showing wrong name on network
- Bonjour name drifted
- hostname mismatch on Mac
- Mac name changed after AirDrop use

**Flags:**
| Flag | When to use |
|------|-------------|
| `--fix` | HostName or LocalHostName has drifted with a .local suffix — strips the suffix so all three hostname values are consistent. |


## Scenario Index — Microsoft 365

### `getCalPerms`
Retrieves calendar permissions for a mailbox via the Microsoft Graph API using client credentials.

**Use when:**
- who has access to this calendar
- calendar permission report
- check who can see a user's calendar
- delegate access on calendar
- calendar sharing audit
- user can't see another user's calendar

### `getUserGUID`
Looks up a user's Object ID / GUID from Microsoft Graph by UPN.

**Use when:**
- need the object ID for a user
- find user GUID in Entra ID
- Azure AD user ID lookup
- what is the GUID for this user
- user object ID for Graph API call

### `listUsers`
Lists all users in a tenant via the Microsoft Graph API using OAuth client credentials flow.

**Use when:**
- get a list of all users in the tenant
- who is in Microsoft 365
- export user list from Entra ID
- audit all accounts in a tenant
- list every M365 user

### `TenantDataExport`
Template script to export M365 tenant data (users, Exchange, OneDrive, SharePoint, licenses) to an Excel workbook.

**Use when:**
- export M365 tenant overview
- tenant audit report to Excel
- need a spreadsheet of all M365 data
- license report for a tenant
- SharePoint and OneDrive export
- Exchange mailbox audit export


## Scenario Index — Apps

### `Get-OutlookHealth`
Checks Outlook process state, install path, DNS resolution for outlook.office365.com, and internet connectivity. Flags missing install and DNS/connectivity failures.

**Use when:**
- Outlook not opening
- Outlook can't connect to server
- email not working in Outlook
- Outlook keeps crashing
- can't send or receive email
- Outlook not finding mail server
- DNS resolution failing for Outlook

### `Get-NetskopeHealth`
Checks Netskope client installation state, version, agent service status, and certificate presence. Run with -Remove to fully uninstall Netskope including service, MSI, folders, certs, and roaming data.

**Use when:**
- Netskope blocking websites
- Netskope agent not running
- need to remove Netskope
- Netskope causing connectivity issues
- VPN proxy interfering with traffic
- Netskope service crashed
- completely uninstall Netskope


## Scenario Index — 3CX

### `ConfigAPI_Test`
Tests connectivity to the 3CX Configuration API using the /xapi/v1/Defs endpoint with Bearer token auth.

**Use when:**
- 3CX API not responding
- test 3CX API connection
- 3CX xapi connectivity check
- verify 3CX API credentials work
- troubleshoot 3CX API access

### `get3CXVersion`
Authenticates to a 3CX PBX via OAuth client credentials and retrieves the current PBX version.

**Use when:**
- what version is 3CX running
- check 3CX PBX version
- 3CX version number lookup
- verify 3CX firmware version before upgrade


<!-- GEN:END -->

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
