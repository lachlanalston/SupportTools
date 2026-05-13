# macOS

Diagnostic and remediation scripts for macOS endpoints. Written in bash — use in SSH, Kandji/Jamf remote commands, or terminal paste.

## Scripts

| Script | When to use |
|--------|-------------|
| `get-printer-health` | Mac printer not working |
| `get-security-baseline` | Mac security audit |
| `get-update-health` | Mac not installing updates |
| `get-battery-health` | MacBook battery draining fast |
| `get-disk-health` | Mac running slow |
| `get-filevault-health` | FileVault not enabled on Mac |
| `get-mdm-health` | Mac not showing in Intune |
| `get-EndpointHealth` | Mac running slow |
| `get-recent-changes` | something changed on Mac and now it's broken |
| `get-hostname-health` | Mac hostname keeps changing |

## Usage

```bash
bash get-EndpointHealth.sh
bash get-printer-health.sh --fix
```

