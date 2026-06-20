#Requires -Version 7.0
<#
.SYNOPSIS
    Diagnostic helper — tries a Horizon REST API /rest/login call and
    prints the full request + response so we can see why auth is failing.

.DESCRIPTION
    Use this when the main harvester is getting a 401 from Horizon and
    you need to figure out WHY. It tries three payload variations:
        1. short NetBIOS domain        (domain = "contoso")
        2. upper-case NetBIOS domain   (domain = "CONTOSO")
        3. AD FQDN                     (domain = "contoso.local")
        4. UPN in username, blank dom  (username = "jdoeadm@contoso.local")
    …and prints the HTTP status + response body for each.

    This script is stateless: it doesn't touch the vault or the config
    file. You give it the server + credential directly.

.PARAMETER HorizonServer
    FQDN of a Horizon Connection Server (or the internal LB in front of
    one). E.g. horizon-ext.example.org.

.PARAMETER Username
    Username (sAMAccountName, e.g. jdoeadm).

.PARAMETER Domain
    Short domain / NetBIOS name (e.g. contoso). Optional — if omitted, all
    four variations are tried against whatever you supply for --Username.

.PARAMETER SkipCertificateCheck
    Pass this if the Horizon server has a self-signed / non-public cert.

.EXAMPLE
    pwsh ./harvester/Test-HorizonLogin.ps1 `
        -HorizonServer horizon-ext.example.org `
        -Username jdoeadm -Domain contoso

.EXAMPLE
    # Let the script try all four payload shapes
    pwsh ./harvester/Test-HorizonLogin.ps1 `
        -HorizonServer horizon-ext.example.org `
        -Username jdoeadm

.NOTES
    The script prompts for the password via Read-Host -AsSecureString so
    it never appears in command history or process tables.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$HorizonServer,
    [Parameter(Mandatory)][string]$Username,
    [string]$Domain = '',
    [switch]$SkipCertificateCheck
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

# ── Prompt for password (never on the command line) ──────────────────────────
$securePw = Read-Host -AsSecureString -Prompt "Password for $Username"
$plainPw  = [System.Net.NetworkCredential]::new('', $securePw).Password

# ── Build list of payload variations ──────────────────────────────────────────
# If the user supplied an explicit domain, just try that one. Otherwise try
# the four most common shapes.
if ($Domain) {
    $attempts = @(
        @{ label = "explicit domain='$Domain'"; body = @{ domain = $Domain; username = $Username; password = $plainPw } }
    )
}
else {
    # Derive a plausible short domain from the server's FQDN for attempt #3/4
    $guessedAdFqdn = ($HorizonServer -split '\.', 2)[1]   # e.g. example.org → example.org
    $attempts = @(
        @{ label = "lowercase short domain";    body = @{ domain = 'contoso';       username = $Username; password = $plainPw } }
        @{ label = "uppercase short domain";    body = @{ domain = 'CONTOSO';       username = $Username; password = $plainPw } }
        @{ label = "AD domain 'contoso.local'";  body = @{ domain = 'contoso.local'; username = $Username; password = $plainPw } }
        @{ label = "UPN in username, no dom";   body = @{ domain = '';             username = "$Username@contoso.local"; password = $plainPw } }
    )
}

# ── Optional: skip cert validation (cross-platform way) ─────────────────────
$restParams = @{
    Method      = 'POST'
    ContentType = 'application/json'
}
if ($SkipCertificateCheck) {
    $restParams.SkipCertificateCheck = $true
}

$uri = "https://$HorizonServer/rest/login"
Write-Host "`nTarget URI: $uri" -ForegroundColor Cyan
Write-Host "Trying $($attempts.Count) payload variation(s)...`n" -ForegroundColor Cyan

$successCount = 0

foreach ($attempt in $attempts) {
    Write-Host "───────────────────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host "  Attempt: $($attempt.label)" -ForegroundColor Yellow

    # Print the request body with password redacted
    $safeBody = $attempt.body.Clone()
    $safeBody.password = '<redacted>'
    Write-Host "  Request: $($safeBody | ConvertTo-Json -Compress)" -ForegroundColor DarkGray

    try {
        $response = Invoke-RestMethod -Uri $uri -Body ($attempt.body | ConvertTo-Json) @restParams
        Write-Host "  ✔ SUCCESS" -ForegroundColor Green
        if ($response.access_token) {
            $tokenPreview = $response.access_token.Substring(0, [math]::Min(20, $response.access_token.Length))
            Write-Host "    access_token: $tokenPreview..." -ForegroundColor Green
        }
        if ($response.refresh_token) {
            Write-Host "    refresh_token: (present)" -ForegroundColor Green
        }
        Write-Host "`n  >>> THIS payload shape works. Use domain='$($attempt.body.domain)' username='$($attempt.body.username)' when you Register-HorizonEnvironment.`n" -ForegroundColor Green
        $successCount++

        # Try to log out cleanly so we don't leave a dangling session
        try {
            $logoutParams = @{
                Uri         = "https://$HorizonServer/rest/logout"
                Method      = 'POST'
                Headers     = @{ Authorization = "Bearer $($response.access_token)" }
                ContentType = 'application/json'
            }
            if ($SkipCertificateCheck) { $logoutParams.SkipCertificateCheck = $true }
            Invoke-RestMethod @logoutParams | Out-Null
        } catch { }
        break   # stop on first success
    }
    catch {
        $status = $null
        if ($_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
        }
        Write-Host "  ✗ FAILED: $($_.Exception.Message)" -ForegroundColor Red
        if ($status) {
            Write-Host "    HTTP status: $status" -ForegroundColor Red
        }
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            Write-Host "    Response body: $($_.ErrorDetails.Message)" -ForegroundColor Red
        }
    }
    Write-Host ""
}

Write-Host "───────────────────────────────────────────────────────────" -ForegroundColor DarkGray
if ($successCount -eq 0) {
    Write-Host "`nAll attempts failed. Next steps:" -ForegroundColor Yellow
    Write-Host "  1. Verify the account has Horizon Administrator role assigned in Horizon Admin Console" -ForegroundColor Yellow
    Write-Host "     (being a domain admin is NOT enough — Horizon RBAC is separate)" -ForegroundColor Yellow
    Write-Host "  2. Try hitting a Connection Server directly instead of the LB:" -ForegroundColor Yellow
    Write-Host "     pwsh ./harvester/Test-HorizonLogin.ps1 -HorizonServer horizon-cs01.example.org -Username $Username -Domain contoso" -ForegroundColor Yellow
    Write-Host "  3. Check the CS event log on the Horizon server — failed REST logins log a reason." -ForegroundColor Yellow
    Write-Host ""
}
