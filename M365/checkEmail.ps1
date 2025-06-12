Get-Recipient -ResultSize Unlimited | Where-Object { $_.EmailAddresses -match "admin@domain.com" } | Select Name,RecipientType,RecipientTypeDetails,PrimarySmtpAddress

Get-DistributionGroupMember -Identity admin@domain.com | Select Name, PrimarySmtpAddress
