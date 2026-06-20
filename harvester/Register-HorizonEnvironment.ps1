#Requires -Version 7.0
<#
.SYNOPSIS
    Register a Horizon environment — prompts for hostnames and credentials
    and stores them in config + SecretStore.

.DESCRIPTION
    First-run helper for the Horizon View harvesters. Run this once per
    environment (prod, test, DR…) and the harvester/generator will pick up
    everything non-interactively afterwards.

    What this does (in order):
        1. Ensures SecretManagement + SecretStore modules are installed
        2. Registers the HrznHarvester vault (prompts for master password)
        3. Writes environment hostnames to ~/.config/hrzn-harvester/environments.json
        4. Prompts for vCenter + Horizon credentials (+ NetScaler if -Variant full)
        5. Stores them in the vault as hrzn-{env}-{type}

.PARAMETER Environment
    A short name for this environment (e.g. prod, test, dr).

.PARAMETER Variant
    Which harvester variant this environment will be used with.
        no-netscaler  — vCenter + Horizon only (default)
        full          — also prompts for NetScaler NITRO credentials

.PARAMETER Force
    Overwrite an existing environment entry without prompting.

.EXAMPLE
    pwsh ./harvester/Register-HorizonEnvironment.ps1 -Environment prod

.EXAMPLE
    pwsh ./harvester/Register-HorizonEnvironment.ps1 -Environment prod -Variant full -Force

.NOTES
    Author  : ASTGL - As The Geek Learns (astgl.com)
    Version : 1.0.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Environment,
    [ValidateSet('no-netscaler','full')]
    [string]$Variant = 'no-netscaler',
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Import the shared module
$modulePath = Join-Path $PSScriptRoot 'Common/HorizonEnvConfig.psm1'
if (-not (Test-Path $modulePath)) {
    throw "Shared module not found: $modulePath"
}
Import-Module $modulePath -Force

Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║     Horizon Environment Registration                    ║" -ForegroundColor Cyan
Write-Host "║     Environment: $($Environment.PadRight(40))║" -ForegroundColor Cyan
Write-Host "║     Variant    : $($Variant.PadRight(40))║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

# ── Step 1: Vault setup ────────────────────────────────────────────────────────
Write-Host "Step 1/5: Vault setup" -ForegroundColor Cyan
Initialize-HorizonVault

# ── Step 2: Check for existing env entry ───────────────────────────────────────
Write-Host "`nStep 2/5: Config file check" -ForegroundColor Cyan
$configPath = Get-HorizonEnvConfigPath
Write-Host "  Config file: $configPath"

$existingEntry = $null
if (Test-Path $configPath) {
    try {
        $existingEntry = Get-HorizonEnvironment -Name $Environment -ErrorAction SilentlyContinue
    } catch { $existingEntry = $null }
}

if ($existingEntry -and -not $Force) {
    Write-Host "  ⚠ Environment '$Environment' already exists in config:" -ForegroundColor Yellow
    $existingEntry | Format-Table -AutoSize | Out-String | Write-Host
    $response = Read-Host "  Overwrite? [y/N]"
    if ($response -notmatch '^[Yy]') {
        Write-Host "  Aborted. No changes made." -ForegroundColor Yellow
        return
    }
}

# ── Step 3: Prompt for hostnames ───────────────────────────────────────────────
Write-Host "`nStep 3/5: Environment hostnames" -ForegroundColor Cyan
$vcenter      = Read-Host "  vCenter FQDN              (e.g. vcenter.example.org)"
$horizon      = Read-Host "  Horizon CS FQDN           (e.g. horizon-cs01.example.org)"
$externalUrl  = Read-Host "  Horizon external URL      (optional — press Enter to auto-discover)"
$skipCertResp = Read-Host "  Skip SSL cert validation? [y/N]"
$skipCert     = ($skipCertResp -match '^[Yy]')

$envConfig = @{
    vcenter                = $vcenter
    horizon                = $horizon
    external_url           = $externalUrl
    variant                = $Variant
    skip_certificate_check = $skipCert
    output_dir             = $null  # null = generator's default (./output)
}

Set-HorizonEnvironment -Name $Environment -Config $envConfig
Write-Host "  ✔ Hostnames written to $configPath" -ForegroundColor Green

# ── Step 4: Prompt for credentials ─────────────────────────────────────────────
Write-Host "`nStep 4/5: Credentials" -ForegroundColor Cyan

Write-Host "  ► vCenter credentials ($vcenter)" -ForegroundColor Yellow
$vCenterCred = Get-Credential -Message "vCenter ($vcenter) credentials"
Save-HorizonCredentials -Environment $Environment -Type vcenter -Credential $vCenterCred
Write-Host "  ✔ Stored: hrzn-$Environment-vcenter" -ForegroundColor Green

Write-Host "  ► Horizon credentials ($horizon)" -ForegroundColor Yellow
$horizonCred = Get-Credential -Message "Horizon Connection Server ($horizon) credentials"
Save-HorizonCredentials -Environment $Environment -Type horizon -Credential $horizonCred
Write-Host "  ✔ Stored: hrzn-$Environment-horizon" -ForegroundColor Green

if ($Variant -eq 'full') {
    Write-Host "  ► NetScaler NITRO credentials" -ForegroundColor Yellow
    $nsCred = Get-Credential -Message "NetScaler NITRO credentials"
    Save-HorizonCredentials -Environment $Environment -Type netscaler -Credential $nsCred
    Write-Host "  ✔ Stored: hrzn-$Environment-netscaler" -ForegroundColor Green
}

# ── Step 5: Done ───────────────────────────────────────────────────────────────
Write-Host "`nStep 5/5: Done" -ForegroundColor Cyan
$harvesterScript = if ($Variant -eq 'full') {
    './harvester/Invoke-HorizonHarvester.ps1'
} else {
    './harvester/Invoke-HorizonHarvester-NoNetScaler.ps1'
}

Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║               Environment Registered!                   ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════════╝`n" -ForegroundColor Green
Write-Host "  Next step — run the harvester:" -ForegroundColor Cyan
Write-Host "    pwsh $harvesterScript -Environment $Environment`n" -ForegroundColor White
Write-Host "  Then the generator:" -ForegroundColor Cyan
Write-Host "    python generator/Generate-HorizonDiagram.py --environment $Environment --drawio`n" -ForegroundColor White
