# ========================================
# Script: Clone-SPGroups.ps1
# Description: This script logs into Microsoft Graph, prompts for a source user and a target user,
#              retrieves the groups that the source user is a member of, filters for groups
#              starting with "SP_", and then adds the target user to those groups.
# 
# Notes: WIP Script - need to add error handling 
#
# Prerequisites: 
# - Microsoft Graph PowerShell module should be installed.
# - The user running the script must have appropriate permissions to read group memberships
#   and add users to groups in Azure AD.
# ========================================

# Install and Import the Microsoft Graph module (if not already done)
# Install-Module -Name Microsoft.Graph -Force -AllowClobber
# Import-Module Microsoft.Graph

# Login to Microsoft Graph (prompts for credentials)
Connect-MgGraph

# Prompt for the source username (user whose groups to copy)
$sourceUsername = Read-Host -Prompt "Enter the source username (user whose groups to copy)"

# Prompt for the target username (user to add groups to)
$targetUsername = Read-Host -Prompt "Enter the target username (user to add groups to)"

# Get the source user object
$sourceUser = Get-MgUser -UserId $sourceUsername

# Get the target user object
$targetUser = Get-MgUser -UserId $targetUsername

# Check if users are valid (not null)
if (-not $sourceUser) {
    Write-Host "Source user '$sourceUsername' not found. Please check the username and try again."
    exit
}
if (-not $targetUser) {
    Write-Host "Target user '$targetUsername' not found. Please check the username and try again."
    exit
}

# Get the groups the source user is a member of
$sourceUserGroups = Get-MgUserMemberOf -UserId $sourceUser.Id

# Filter the groups that start with 'SP_'
$spGroups = $sourceUserGroups | Where-Object { $_.DisplayName -like "SP_*" }

# If no 'SP_' groups are found, notify the user
if ($spGroups.Count -eq 0) {
    Write-Host "No groups starting with 'SP_' were found for the source user."
    exit
}

# Loop through each group that starts with 'SP_' and add the target user to it
foreach ($group in $spGroups) {
    try {
        # Add the target user to the group
        Add-MgGroupMember -GroupId $group.Id -MemberId $targetUser.Id
        Write-Host "Successfully added $targetUsername to group $($group.DisplayName)"
    }
    catch {
        Write-Host "Failed to add $targetUsername to group $($group.DisplayName): $_"
    }
}

Write-Host "Group cloning process complete."
