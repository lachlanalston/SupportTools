# M365

PowerShell scripts for Microsoft 365 administration via the Microsoft Graph API. All scripts use OAuth client credentials flow (app registration, not delegated auth).

## Scripts

| Script | When to use |
|--------|-------------|
| `getCalPerms.ps1` | Audit who has access to a user's calendar — delegate, editor, reader, or free/busy. |
| `getUserGUID.ps1` | Look up a user's Entra ID Object ID by UPN. Needed for Graph API calls and Intune targeting. |
| `listUsers.ps1` | List all accounts in a tenant — displayName and UPN. |
| `TenantDataExport.ps1` | Export users, Exchange mailboxes, OneDrive, SharePoint, licenses, and CA policies to Excel. Template — configure before running. |

## Prerequisites

All scripts require an **Azure AD app registration** with appropriate Graph API permissions:

| Script | Required Permission |
|--------|---------------------|
| `getCalPerms.ps1` | `Calendars.Read` |
| `getUserGUID.ps1` | `User.Read.All` |
| `listUsers.ps1` | `User.Read.All` |
| `TenantDataExport.ps1` | Multiple — see script comments |

`TenantDataExport.ps1` also requires the `ImportExcel` module:
```powershell
Install-Module ImportExcel -Scope CurrentUser
```
