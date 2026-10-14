<#
    EntraCredentialExpiry
    Finds Entra (Azure AD) app registration and enterprise application credentials
    (client secrets and certificates) that are expiring, so you get a reminder
    BEFORE they lapse - Entra does not email you about client secret expiry.

    Read-only. Needs an existing Microsoft Graph connection with Application.Read.All
    (app-only via managed identity or certificate is recommended - never a client
    secret, since that is the very thing that expires on you).

    Author: Vijay Kumar G  (fivenumber.com)
#>

# -- internal: ensure a Graph connection exists -------------------------------
function Assert-GraphConnection {
    $ctx = $null
    try { $ctx = Get-MgContext } catch { $ctx = $null }
    if (-not $ctx) {
        throw "No Microsoft Graph connection. Connect first with app-only auth, for example:`n" +
              "  Connect-MgGraph -Identity                                  # managed identity`n" +
              "  Connect-MgGraph -TenantId <tenant> -ClientId <appId> -CertificateThumbprint <thumb>`n" +
              "The app needs the Application.Read.All application permission."
    }
}

# -- internal: run a Graph/HTTP call with retry on throttling + transient 5xx -
function Invoke-WithGraphRetry {
    param(
        [Parameter(Mandatory)][scriptblock] $Action,
        [int] $MaxAttempts = 5
    )
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            return & $Action
        }
        catch {
            # Work out the HTTP status, if there is one.
            $status = $null
            $resp   = $_.Exception.Response
            if ($resp) { try { $status = [int]$resp.StatusCode } catch { $status = $null } }
            if (-not $status -and $_.ErrorDetails.Message -match 'TooManyRequests|"code"\s*:\s*"TooManyRequests"') { $status = 429 }

            $retryable = $status -and ($status -eq 429 -or $status -ge 500)
            if (-not $retryable -or $attempt -ge $MaxAttempts) { throw }

            # Honour Retry-After when the service sends one; otherwise exponential backoff.
            $delay = [math]::Min(60, [math]::Pow(2, $attempt))
            try {
                $ra = $resp.Headers.RetryAfter
                if ($ra -and $ra.Delta)     { $delay = [double]$ra.Delta.TotalSeconds }
                elseif ($ra -and $ra.Date)  { $delay = [math]::Max(1, ($ra.Date - [DateTimeOffset]::UtcNow).TotalSeconds) }
            } catch { Write-Verbose "No usable Retry-After header; using backoff delay." }

            Write-Verbose "Graph returned $status on attempt $attempt/$MaxAttempts; retrying in $([int]$delay)s..."
            Start-Sleep -Seconds ([int][math]::Ceiling($delay))
        }
    }
}

# -- internal: GET a Graph collection, following @odata.nextLink ---------------
function Get-GraphCollection {
    param([Parameter(Mandatory)][string]$Uri)
    $items = New-Object System.Collections.Generic.List[object]
    $next = $Uri
    while ($next) {
        $resp = Invoke-WithGraphRetry { Invoke-MgGraphRequest -Method GET -Uri $next -OutputType PSObject }
        if ($resp.value) { foreach ($v in $resp.value) { $items.Add($v) } }
        $next = $resp.'@odata.nextLink'
    }
    return $items
}

# -- internal: normalise a Graph timestamp (string or DateTime) to real UTC ---
function ConvertTo-Utc {
    param($Value)
    if ($Value -is [datetime]) {
        $dt = [datetime]$Value
        if ($dt.Kind -eq [System.DateTimeKind]::Unspecified) {
            # Graph timestamps are UTC; an unspecified Kind means "already UTC, just untagged".
            return [datetime]::SpecifyKind($dt, [System.DateTimeKind]::Utc)
        }
        return $dt.ToUniversalTime()
    }
    return [datetime]::Parse(
        [string]$Value,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal)
}

# -- internal: severity label from days-left + the configured windows ---------
function Get-Severity {
    param([int]$DaysLeft, [int[]]$Windows)
    if ($DaysLeft -lt 0) { return 'Expired' }
    foreach ($w in ($Windows | Sort-Object)) {
        if ($DaysLeft -le $w) { return "Within $w days" }
    }
    return $null   # outside all windows
}

function Get-EntraCredentialExpiry {
<#
.SYNOPSIS
    Lists Entra app registration and enterprise app credentials (secrets + certificates)
    with their expiry dates, days remaining, and a severity bucket.

.DESCRIPTION
    Read-only. Reads passwordCredentials (client secrets) and keyCredentials
    (certificates) directly from /applications and, optionally, /servicePrincipals,
    so you choose your own expiry windows instead of being limited to the Entra
    recommendation's fixed 30-day view (which also needs a Workload ID licence).

    Requires an existing Connect-MgGraph session with Application.Read.All.

.PARAMETER DaysWindow
    One or more day thresholds used to bucket results (default 90, 60, 30, 7).
    The largest value is also the look-ahead horizon used by -ExpiringOnly.

.PARAMETER IncludeServicePrincipals
    Also scan enterprise applications (service principals), not just app registrations.

.PARAMETER ExpiringOnly
    Return only credentials that are expired or within the largest DaysWindow.

.PARAMETER CsvPath
    Optional. Writes the rows to this CSV.

.PARAMETER HtmlPath
    Optional. Writes a styled HTML report to this path.

.EXAMPLE
    Connect-MgGraph -Identity
    Get-EntraCredentialExpiry -ExpiringOnly | Format-Table

.EXAMPLE
    Get-EntraCredentialExpiry -IncludeServicePrincipals -HtmlPath .\cred-expiry.html
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateNotNullOrEmpty()]
        [ValidateRange(1, 3650)]
        [int[]] $DaysWindow = @(90,60,30,7),

        [switch] $IncludeServicePrincipals,
        [switch] $ExpiringOnly,
        [string] $CsvPath,
        [string] $HtmlPath
    )

    Assert-GraphConnection
    $now  = [datetime]::UtcNow
    $max  = ($DaysWindow | Measure-Object -Maximum).Maximum
    $rows = New-Object System.Collections.Generic.List[object]

    $sources = @(
        @{ Type='Application';      Uri="v1.0/applications?`$select=id,appId,displayName,passwordCredentials,keyCredentials&`$top=999" }
    )
    if ($IncludeServicePrincipals) {
        $sources += @{ Type='ServicePrincipal'; Uri="v1.0/servicePrincipals?`$select=id,appId,displayName,passwordCredentials,keyCredentials&`$top=999" }
    }

    foreach ($src in $sources) {
        Write-Verbose "Reading $($src.Type) objects..."
        $objs = Get-GraphCollection -Uri $src.Uri
        foreach ($o in $objs) {
            $creds = @()
            if ($o.passwordCredentials) { $creds += ,@($o.passwordCredentials, 'Secret') }
            if ($o.keyCredentials)      { $creds += ,@($o.keyCredentials,      'Certificate') }
            foreach ($pair in $creds) {
                foreach ($c in $pair[0]) {
                    if (-not $c.endDateTime) { continue }
                    $end  = ConvertTo-Utc $c.endDateTime
                    $days = [int][math]::Floor(($end - $now).TotalDays)
                    $sev  = Get-Severity -DaysLeft $days -Windows $DaysWindow
                    if ($ExpiringOnly -and ($days -gt $max)) { continue }
                    $portal = if ($src.Type -eq 'Application') {
                        "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/Credentials/appId/$($o.appId)"
                    } else {
                        "https://entra.microsoft.com/#view/Microsoft_AAD_IAM/ManagedAppMenuBlade/~/Credentials/objectId/$($o.id)/appId/$($o.appId)"
                    }
                    $rows.Add([pscustomobject]@{
                        ObjectType       = $src.Type
                        DisplayName      = [string]$o.displayName
                        AppId            = [string]$o.appId
                        CredentialType   = $pair[1]
                        CredentialName   = [string]($c.displayName)
                        EndDateUtc       = $end.ToString('yyyy-MM-dd')
                        DaysUntilExpiry  = $days
                        Severity         = $sev
                        ObjectId         = [string]$o.id
                        PortalUrl        = $portal
                    })
                }
            }
        }
    }

    $out = @($rows | Sort-Object DaysUntilExpiry)

    if ($CsvPath) {
        $out | Select-Object ObjectType,DisplayName,AppId,CredentialType,CredentialName,EndDateUtc,DaysUntilExpiry,Severity,PortalUrl |
            Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
        Write-Verbose "CSV written: $CsvPath"
    }
    if ($HtmlPath) { Write-CredentialExpiryHtml -Rows $out -Path $HtmlPath -MaxWindow $max }

    return $out
}

# -- internal: styled HTML report ---------------------------------------------
function Write-CredentialExpiryHtml {
    param([object[]]$Rows, [string]$Path, [int]$MaxWindow)
    $enc = { param($t) [System.Net.WebUtility]::HtmlEncode([string]$t) }
    $body = ($Rows | ForEach-Object {
        $cls = if ($_.DaysUntilExpiry -lt 0) { 'exp' } elseif ($_.DaysUntilExpiry -le 7) { 'crit' } elseif ($_.DaysUntilExpiry -le 30) { 'warn' } else { 'ok' }
        "<tr class='$cls'><td>$(& $enc $_.ObjectType)</td><td>$(& $enc $_.DisplayName)</td><td>$(& $enc $_.CredentialType)</td><td>$(& $enc $_.EndDateUtc)</td><td>$($_.DaysUntilExpiry)</td><td>$(& $enc $_.Severity)</td><td class='id'>$(& $enc $_.AppId)</td></tr>"
    }) -join "`n"
    $expired = @($Rows | Where-Object { $_.DaysUntilExpiry -lt 0 }).Count
    $html = @"
<!doctype html><html><head><meta charset="utf-8"><title>Entra credential expiry</title>
<style>body{font-family:Segoe UI,Arial,sans-serif;margin:2rem;color:#201f1e}
h1{font-size:1.3rem}.sub{color:#605e5c}
table{border-collapse:collapse;margin-top:1rem;width:100%}
th,td{border:1px solid #edebe9;padding:.4rem .6rem;text-align:left;font-size:.92rem}
th{background:#f3f2f1}.id{font-family:Consolas,monospace;color:#605e5c}
tr.exp td{background:#fde7e9}tr.crit td{background:#fdf3f2}tr.warn td{background:#fff8f0}tr.ok td{background:#f3faf3}</style></head><body>
<h1>Entra credential expiry</h1>
<div class="sub">Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') &middot; look-ahead $MaxWindow days &middot; $($Rows.Count) credential(s), $expired expired</div>
<table><tr><th>Object</th><th>Name</th><th>Type</th><th>Expires (UTC)</th><th>Days</th><th>Severity</th><th>App ID</th></tr>
$body
</table></body></html>
"@
    Set-Content -Path $Path -Value $html -Encoding UTF8
    Write-Verbose "HTML written: $Path"
}

function Send-EntraCredentialExpiryAlert {
<#
.SYNOPSIS
    Runs Get-EntraCredentialExpiry -ExpiringOnly and sends a Teams card and/or email.

.DESCRIPTION
    The notification step for scheduled, unattended runs (Azure Automation, an Azure
    Function timer, a GitHub Action, or Task Scheduler). Read-only reads; it only sends
    an alert. Requires an existing Connect-MgGraph session with Application.Read.All
    (plus Mail.Send if you use -MailTo).

    Each delivery channel is isolated: if one fails the other is still attempted, and
    the cmdlet throws at the end if any channel failed, so a scheduled host records the
    run as failed.

.PARAMETER TeamsWebhook
    A Teams Incoming Webhook / Workflows ("post to a channel when a webhook request is
    received") URL. Posts an Adaptive Card summary.

.PARAMETER MailTo
    One or more recipient addresses. Sends an HTML email via Graph sendMail.

.PARAMETER MailFrom
    The sender mailbox (user or shared mailbox the app can send as). Required with -MailTo.

.PARAMETER DaysWindow
    Expiry thresholds (default 90, 60, 30, 7). Largest value = look-ahead horizon.

.PARAMETER IncludeServicePrincipals
    Also scan enterprise applications.

.EXAMPLE
    Connect-MgGraph -Identity
    Send-EntraCredentialExpiryAlert -TeamsWebhook $env:TEAMS_WEBHOOK
#>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param(
        [string]   $TeamsWebhook,
        [string[]] $MailTo,
        [string]   $MailFrom,

        [ValidateNotNullOrEmpty()]
        [ValidateRange(1, 3650)]
        [int[]]    $DaysWindow = @(90,60,30,7),

        [switch]   $IncludeServicePrincipals
    )
    if (-not $TeamsWebhook -and -not $MailTo) { throw "Provide -TeamsWebhook and/or -MailTo." }
    if ($MailTo -and -not $MailFrom)          { throw "-MailFrom is required when using -MailTo." }

    $max  = ($DaysWindow | Measure-Object -Maximum).Maximum
    $rows = Get-EntraCredentialExpiry -DaysWindow $DaysWindow -IncludeServicePrincipals:$IncludeServicePrincipals -ExpiringOnly
    if (-not $rows -or $rows.Count -eq 0) {
        Write-Verbose "Nothing expiring within $max days."
        return
    }

    $expired = @($rows | Where-Object { $_.DaysUntilExpiry -lt 0 }).Count
    $soon    = @($rows | Where-Object { $_.DaysUntilExpiry -ge 0 -and $_.DaysUntilExpiry -le 7 }).Count
    $summary = "$($rows.Count) Entra credential(s) need attention: $expired expired, $soon within 7 days."

    $failures = New-Object System.Collections.Generic.List[string]

    if ($TeamsWebhook) {
        if ($PSCmdlet.ShouldProcess('Teams channel', 'Post credential-expiry Adaptive Card')) {
            try {
                $factRows = ($rows | Select-Object -First 15 | ForEach-Object {
                    @{ title = "$($_.DisplayName) [$($_.CredentialType)]"; value = "$($_.EndDateUtc)  ($($_.DaysUntilExpiry) days)" }
                })
                $card = @{
                    type = "message"
                    attachments = @(@{
                        contentType = "application/vnd.microsoft.card.adaptive"
                        content = @{
                            '$schema' = "http://adaptivecards.io/schemas/adaptive-card.json"
                            type = "AdaptiveCard"; version = "1.4"
                            body = @(
                                @{ type="TextBlock"; size="Large"; weight="Bolder"; text="Entra credential expiry" }
                                @{ type="TextBlock"; wrap=$true; text=$summary }
                                @{ type="FactSet"; facts=$factRows }
                            )
                        }
                    })
                }
                $json = $card | ConvertTo-Json -Depth 12
                Invoke-WithGraphRetry { Invoke-RestMethod -Uri $TeamsWebhook -Method Post -ContentType 'application/json' -Body $json } | Out-Null
                Write-Verbose "Teams card posted."
            }
            catch {
                Write-Warning "Teams post failed: $($_.Exception.Message)"
                $failures.Add("Teams: $($_.Exception.Message)")
            }
        }
    }

    if ($MailTo) {
        if ($PSCmdlet.ShouldProcess(($MailTo -join ', '), 'Send credential-expiry email')) {
            $tmp = $null
            try {
                $tmp = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "cred-expiry-$([guid]::NewGuid().ToString('N')).html")
                Write-CredentialExpiryHtml -Rows $rows -Path $tmp -MaxWindow $max
                $htmlBody = Get-Content $tmp -Raw
                $msg = @{
                    message = @{
                        subject = "Entra credential expiry: $($rows.Count) need attention ($expired expired)"
                        body = @{ contentType = "HTML"; content = $htmlBody }
                        toRecipients = @($MailTo | ForEach-Object { @{ emailAddress = @{ address = $_ } } })
                    }
                    saveToSentItems = $false
                }
                $mailJson = $msg | ConvertTo-Json -Depth 12
                Invoke-WithGraphRetry { Invoke-MgGraphRequest -Method POST -Uri "v1.0/users/$MailFrom/sendMail" -Body $mailJson } | Out-Null
                Write-Verbose "Email sent to $($MailTo -join ', ')."
            }
            catch {
                Write-Warning "Email send failed: $($_.Exception.Message)"
                $failures.Add("Email: $($_.Exception.Message)")
            }
            finally {
                if ($tmp -and (Test-Path $tmp)) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
            }
        }
    }

    if ($failures.Count -gt 0) {
        throw "Alert delivery failed: $($failures -join ' | ')"
    }
}

Export-ModuleMember -Function Get-EntraCredentialExpiry, Send-EntraCredentialExpiryAlert
