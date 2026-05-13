# MacOS

Diagnostic and remediation scripts for macOS endpoints. All scripts are written in bash and designed for use in SSH, Kandji/Jamf remote commands, or terminal paste.

## Scripts

| Script | When to use |
|--------|-------------|
| `get-EndpointHealth.sh` | First script to run on any Mac ticket. Broad triage: disk, CPU, RAM, updates, SMART, AV/EDR, services, battery. |
| `get-recent-changes.sh` | Something broke on this Mac recently — shows installs, reboots, panics, crashes in last 72 hours. |
| `get-disk-health.sh` | Mac running slow, out of space, or SMART warning. Add `--deep` for filesystem integrity check. |
| `get-update-health.sh` | Mac not installing updates or pending restart for update. |
| `get-battery-health.sh` | MacBook battery draining fast, not charging, or condition warning. |
| `get-security-baseline.sh` | Security audit — SIP, Gatekeeper, Firewall, FileVault, XProtect, SSH state. |
| `get-filevault-health.sh` | FileVault not enabled, recovery key missing, or MDM escrow not configured. |
| `get-mdm-health.sh` | Mac not in Intune, Kandji/Jamf enrolment broken, or supervision state unclear. |
| `get-printer-health.sh` | Mac printer not working or print job stuck. Add `--fix` to clear queue. |
| `get-hostname-health.sh` | Mac hostname keeps changing or AirDrop showing wrong name. Add `--fix` to strip drift. |

## Usage

```bash
# Run read-only
bash get-EndpointHealth.sh

# Run with fix
bash get-printer-health.sh --fix
bash get-disk-health.sh --deep
```
