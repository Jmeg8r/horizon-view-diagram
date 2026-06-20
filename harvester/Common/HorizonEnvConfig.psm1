#Requires -Version 7.0
<#
.SYNOPSIS
    Shared config + credential helpers for the Horizon View harvesters.

.DESCRIPTION
    Provides per-environment hostname configuration (stored as JSON) and
    credential retrieval backed by Microsoft.PowerShell.SecretStore. This
    module is cross-platform by design: the SecretStore vault uses real
    AES-256 encryption with a user-supplied master password on Windows,
    macOS, and Linux alike.

    WHY SecretStore instead of Export-Clixml + PSCredential?
        On Windows, Export-Clixml wraps credentials with DPAPI so only the
        current user on the current machine can read them. On macOS/Linux
        PowerShell 7 has no DPAPI equivalent — it falls back to writing the
        AES key next to the ciphertext, which is obfuscation rather than
        encryption. SecretStore is Microsoft's supported cross-platform
        answer and gives us identical behavior on every OS we target.

.NOTES
    Author  : ASTGL - As The Geek Learns (astgl.com)
    Version : 1.0.0
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Constants ──────────────────────────────────────────────────────────────────
$script:VaultName          = 'HrznHarvester'
$script:DefaultConfigDir   = Join-Path $HOME '.config/hrzn-harvester'
$script:DefaultConfigFile  = 'environments.json'
$script:RequiredModules    = @(
    'Microsoft.PowerShell.SecretManagement'
    'Microsoft.PowerShell.SecretStore'
)

# ── Public: Config Path ────────────────────────────────────────────────────────
function Get-HorizonEnvConfigPath {
    <#
    .SYNOPSIS
        Returns the resolved path to the environments.json config file.
    .DESCRIPTION
        Honors $env:HRZN_CONFIG_PATH if set; otherwise falls back to
        ~/.config/hrzn-harvester/environments.json (XDG-adjacent).
    #>
    [CmdletBinding()]
    param()

    if ($env:HRZN_CONFIG_PATH) {
        return $env:HRZN_CONFIG_PATH
    }
    return (Join-Path $script:DefaultConfigDir $script:DefaultConfigFile)
}

# ── Public: Vault Initialization ───────────────────────────────────────────────
function Initialize-HorizonVault {
    <#
    .SYNOPSIS
        Ensures SecretManagement/SecretStore modules are installed and the
        HrznHarvester vault is registered. Idempotent — safe to re-run.
    .DESCRIPTION
        On first run this will:
          1. Install-Module SecretManagement/SecretStore (CurrentUser scope)
          2. Register-SecretVault -Name HrznHarvester
          3. Configure SecretStore with a 15-minute password timeout
             (the user will be prompted to set a master password once)
    #>
    [CmdletBinding()]
    param()

    # Step 1: install required modules if missing
    foreach ($mod in $script:RequiredModules) {
        if (-not (Get-Module -ListAvailable -Name $mod)) {
            Write-Host "  ► Installing $mod (CurrentUser scope)..." -ForegroundColor Yellow
            Install-Module -Name $mod -Scope CurrentUser -Force -AcceptLicense -ErrorAction Stop
        }
        Import-Module $mod -ErrorAction Stop
    }

    # Step 2: register the vault if it doesn't already exist
    $existing = Get-SecretVault -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq $script:VaultName }
    if (-not $existing) {
        Write-Host "  ► Registering SecretStore vault '$($script:VaultName)'..." -ForegroundColor Yellow
        Register-SecretVault `
            -Name           $script:VaultName `
            -ModuleName     Microsoft.PowerShell.SecretStore `
            -DefaultVault:$false `
            -ErrorAction    Stop
    }

    # Step 3: configure SecretStore (no-op if already configured)
    # NOTE: Set-SecretStoreConfiguration will prompt for a master password the
    # very first time. -Confirm:$false suppresses the "are you sure" dialog but
    # not the password prompt itself — we want that prompt.
    try {
        $storeConfig = Get-SecretStoreConfiguration -ErrorAction Stop
        if ($storeConfig.Authentication -ne 'Password' -or
            $storeConfig.Interaction    -ne 'Prompt') {
            Write-Host "  ► Reconfiguring SecretStore (Password auth, Prompt interaction)..." -ForegroundColor Yellow
            Set-SecretStoreConfiguration `
                -Authentication   Password `
                -PasswordTimeout  900 `
                -Interaction      Prompt `
                -Confirm:$false `
                -ErrorAction      Stop
        }
    }
    catch {
        # No existing config — this is a first-run setup. Configure fresh.
        Write-Host "  ► Configuring SecretStore (first-run — you'll be asked to set a master password)..." -ForegroundColor Yellow
        Set-SecretStoreConfiguration `
            -Authentication   Password `
            -PasswordTimeout  900 `
            -Interaction      Prompt `
            -Confirm:$false `
            -ErrorAction      Stop
    }

    Write-Host "  ✔ Vault '$($script:VaultName)' ready" -ForegroundColor Green
}

# ── Public: Config Read/Write ──────────────────────────────────────────────────
function Get-HorizonEnvironment {
    <#
    .SYNOPSIS
        Read a single environment entry from environments.json.
    .PARAMETER Name
        The environment name (e.g. "prod", "test", "dr").
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name
    )

    $path = Get-HorizonEnvConfigPath
    if (-not (Test-Path $path)) {
        throw "Config file not found: $path`nRun Register-HorizonEnvironment.ps1 -Environment $Name to create it."
    }

    $config = Get-Content -Path $path -Raw | ConvertFrom-Json -AsHashtable
    if (-not $config.ContainsKey('environments')) {
        throw "Config file is malformed (missing 'environments' key): $path"
    }
    if (-not $config.environments.ContainsKey($Name)) {
        $available = ($config.environments.Keys | Sort-Object) -join ', '
        throw "Environment '$Name' not found in $path. Available: $available"
    }

    return $config.environments[$Name]
}

function Set-HorizonEnvironment {
    <#
    .SYNOPSIS
        Write (or update) a single environment entry in environments.json.
    .DESCRIPTION
        Creates the config file and parent directory on first use. Preserves
        any other environments already in the file.
    .PARAMETER Name
        Environment name.
    .PARAMETER Config
        Hashtable of environment settings (vcenter, horizon, external_url, etc.)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][hashtable]$Config
    )

    $path = Get-HorizonEnvConfigPath
    $dir  = Split-Path $path -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    # Load existing config or create a new skeleton
    if (Test-Path $path) {
        $data = Get-Content -Path $path -Raw | ConvertFrom-Json -AsHashtable
    }
    else {
        $data = @{
            version             = 1
            default_environment = $Name
            environments        = @{}
        }
    }
    if (-not $data.ContainsKey('environments')) { $data.environments = @{} }

    $data.environments[$Name] = $Config

    $data | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8
    Write-Verbose "Wrote environment '$Name' to $path"
}

# ── Public: Credential Operations ──────────────────────────────────────────────
function Save-HorizonCredentials {
    <#
    .SYNOPSIS
        Store a PSCredential in the HrznHarvester vault, keyed by env + type.
    .PARAMETER Environment
        Environment name (e.g. "prod").
    .PARAMETER Type
        Credential category: vcenter | horizon | netscaler.
    .PARAMETER Credential
        PSCredential to store.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Environment,
        [Parameter(Mandatory)]
        [ValidateSet('vcenter','horizon','netscaler')]
        [string]$Type,
        [Parameter(Mandatory)][System.Management.Automation.PSCredential]$Credential
    )

    $secretName = "hrzn-$Environment-$Type"
    Set-Secret -Name $secretName -Secret $Credential -Vault $script:VaultName
    Write-Verbose "Saved secret '$secretName' to vault '$($script:VaultName)'"
}

function Get-HorizonCredentials {
    <#
    .SYNOPSIS
        Retrieve all credentials for an environment from the vault.
    .PARAMETER Environment
        Environment name.
    .OUTPUTS
        Hashtable with keys: vCenter, Horizon, NetScaler (NetScaler may be $null).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Environment
    )

    $result = @{
        vCenter   = $null
        Horizon   = $null
        NetScaler = $null
    }

    $secretMap = @{
        vCenter   = "hrzn-$Environment-vcenter"
        Horizon   = "hrzn-$Environment-horizon"
        NetScaler = "hrzn-$Environment-netscaler"
    }

    foreach ($key in $secretMap.Keys) {
        $secretName = $secretMap[$key]
        try {
            $result[$key] = Get-Secret -Name $secretName -Vault $script:VaultName -ErrorAction Stop
        }
        catch {
            if ($key -eq 'NetScaler') {
                # NetScaler creds are optional for the no-netscaler variant
                $result[$key] = $null
            }
            else {
                throw "Missing credential '$secretName' in vault '$($script:VaultName)'. Run Register-HorizonEnvironment.ps1 -Environment $Environment to create it."
            }
        }
    }

    return $result
}

Export-ModuleMember -Function @(
    'Initialize-HorizonVault'
    'Get-HorizonEnvConfigPath'
    'Get-HorizonEnvironment'
    'Set-HorizonEnvironment'
    'Get-HorizonCredentials'
    'Save-HorizonCredentials'
)
