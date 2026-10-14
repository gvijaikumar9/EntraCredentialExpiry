@{
    RootModule        = 'EntraCredentialExpiry.psm1'
    ModuleVersion     = '0.2.0'
    GUID              = 'f3c2a7e4-1b9d-4e6a-8c2f-9a7b5d1e0c33'
    Author            = 'Vijay Kumar G'
    CompanyName       = 'fivenumber.com'
    Copyright         = '(c) Vijay Kumar G. MIT License.'
    Description       = 'Reminds you before Entra (Azure AD) app registration and enterprise application credentials (client secrets and certificates) expire. Entra does not email you about client secret expiry; this reads the credentials via Microsoft Graph, buckets them by your own expiry windows, and (optionally) sends a Teams card or email. Read-only. Built for scheduled, unattended runs (Azure Automation, Azure Functions, GitHub Actions).'
    PowerShellVersion = '7.2'
    RequiredModules   = @(
        @{ ModuleName = 'Microsoft.Graph.Authentication'; ModuleVersion = '2.0.0' }
    )
    FunctionsToExport = @('Get-EntraCredentialExpiry','Send-EntraCredentialExpiryAlert')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData = @{
        PSData = @{
            Tags         = @('Entra','AzureAD','Microsoft365','Graph','Security','Governance','Secrets','Certificates','Expiry','AppRegistration')
            LicenseUri   = 'https://github.com/gvijaikumar9/EntraCredentialExpiry/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/gvijaikumar9/EntraCredentialExpiry'
            ReleaseNotes = 'v0.2.0 - Production hardening: automatic retry on Graph throttling (429) and transient 5xx with Retry-After honoured; robust UTC date normalisation; per-channel isolation in Send-EntraCredentialExpiryAlert (one channel failing no longer blocks the other, and the cmdlet throws on any delivery failure so scheduled hosts record it); -WhatIf/-Confirm support; PortalUrl added to CSV. v0.1.0 - Get-EntraCredentialExpiry (app registrations + enterprise apps, secrets + certificates, tiered windows, console/CSV/HTML) and Send-EntraCredentialExpiryAlert (Teams card + email). App-only Graph, read-only.'
        }
    }
}
