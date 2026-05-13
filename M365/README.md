# Microsoft 365

PowerShell scripts for Microsoft 365 administration via the Microsoft Graph API. All scripts use OAuth client credentials flow.

## Scripts

| Script | When to use |
|--------|-------------|
| `getCalPerms` | who has access to this calendar |
| `getUserGUID` | need the object ID for a user |
| `listUsers` | get a list of all users in the tenant |
| `TenantDataExport` | export M365 tenant overview |

## Prerequisites

All scripts require an Azure AD app registration with appropriate Microsoft Graph API permissions. See each script's `.NOTES` block for details.

