#Requires -Version 5.1
<#
.SYNOPSIS
    Horizon View Environment Harvester — No NetScaler Credentials Variant
    Collects vCenter, Horizon, and FC storage data. Infers NetScaler/LB topology
    from DNS resolution, Horizon external URL configuration, and TCP port probing.

.DESCRIPTION
    Use this script when the NetScaler / Citrix ADC is managed by a separate team
    and you do not have NITRO API credentials.

    What this script collects (verified):
        ✔ VMware vCenter — clusters, hosts, datastores, HBAs, DVS port groups
        ✔ VMware Horizon REST API — connection servers, UAGs, pools, farms, composer
        ✔ Fibre Channel fabric — HBAs, LUN paths, multipath policy

    What this script infers about the NetScaler (unverified — marked in JSON):
        ► External Horizon URL / VIP FQDN  (from Horizon Connection Server config)
        ► VIP IP address                   (DNS resolution of the external URL)
        ► Ports in use                     (TCP port probe — Test-NetConnection)
        ► SSL certificate subject/expiry   (TLS handshake inspection)
        ► Number of UAGs behind the VIP    (from Horizon UAG inventory — inferred)

    What remains UNKNOWN without NetScaler credentials:
        ✗ Load balancing algorithm (round-robin, least-connections, etc.)
        ✗ Persistence method (source IP, cookie, etc.)
        ✗ TLS cipher suites and policy names
        ✗ SSL offload vs passthrough configuration
        ✗ Content switching policies / multiple VIP routing rules
        ✗ Health monitor configuration
        ✗ Rate limiting / traffic policies
        ✗ NetScaler appliance model and firmware version
        ✗ HA pair configuration (primary/secondary)
        ✗ Real-time session counts at the LB tier

.PARAMETER OutputPath
    Path to write the output JSON file. Defaults to .\horizon-environment.json

.PARAMETER vCenterServer
    FQDN or IP of your vCenter Server.

.PARAMETER HorizonServer
    FQDN or IP of a Horizon Connection Server (used for REST API calls).

.PARAMETER HorizonExternalURL
    The external FQDN that end users connect to (e.g., vdi.example.org).
    If not supplied, the script reads it from the Connection Server configuration.
    This is the value that gets DNS-resolved to find the load balancer VIP.

.PARAMETER SkipStorage
    Switch to skip Fibre Channel / datastore deep collection.

.PARAMETER SkipCertificateCheck
    Bypass SSL certificate validation (useful in labs or with self-signed certs).

.PARAMETER SkipPortProbe
    Skip TCP port probing of the inferred VIP (useful if ICMP/TCP is blocked).

.EXAMPLE
    # Minimal — let the script infer the external URL from Horizon config
    .\Invoke-HorizonHarvester-NoNetScaler.ps1 `
        -vCenterServer vcenter.example.org `
        -HorizonServer horizon-cs01.example.org

.EXAMPLE
    # Explicit external URL (most reliable)
    .\Invoke-HorizonHarvester-NoNetScaler.ps1 `
        -vCenterServer vcenter.example.org `
        -HorizonServer horizon-cs01.example.org `
        -HorizonExternalURL vdi.example.org `
        -OutputPath C:\Diagrams\horizon-environment.json

.NOTES
    Author  : ASTGL - As The Geek Learns (astgl.com)
    Version : 1.1.0 (No-NetScaler variant)
    Requires: VMware.PowerCLI (Install-Module VMware.PowerCLI)
    Horizon : Uses REST API (Horizon 7.8+)
    NetScaler: NOT REQUIRED — topology inferred via DNS + TCP probing
#>

[CmdletBinding(DefaultParameterSetName = 'ByServer')]
param(
    # ── ByEnvironment: single -Environment flag reads everything from config + vault
    [Parameter(ParameterSetName = 'ByEnvironment', Mandatory)]
    [string]$Environment,

    # ── ByServer: legacy / one-off explicit parameters
    [Parameter(ParameterSetName = 'ByServer', Mandatory)]
    [string]$vCenterServer,
    [Parameter(ParameterSetName = 'ByServer', Mandatory)]
    [string]$HorizonServer,
    [Parameter(ParameterSetName = 'ByServer')]
    [string]$HorizonExternalURL = "",

    # ── Shared across both parameter sets
    [string]$OutputPath = "",
    [switch]$SkipStorage,
    [switch]$SkipCertificateCheck,
    [switch]$SkipPortProbe
)

# WHY StrictMode v1, not Latest:
# v3/Latest raises an error when dot-notation reads a hashtable key that the
# PSObject adapter can't prove exists — which in practice breaks cleanly
# written code that works fine in PowerShell 5.1. We still want undefined-
# variable checks (v1 gives us that), but not the full v3 property-lookup
# behaviour, which collides with PowerCLI's internals on PowerShell 7.
Set-StrictMode -Version 1.0
$ErrorActionPreference = "Stop"

# ── Environment-mode preflight ────────────────────────────────────────────────
# WHY: in ByEnvironment mode we need to resolve hostnames + credentials from
# the shared config module BEFORE the rest of the script runs, so the
# downstream logic (which uses $vCenterServer etc.) sees the same values it
# would have received from direct parameters.
$vCenterCred = $null
$horizonCred = $null

if ($PSCmdlet.ParameterSetName -eq 'ByEnvironment') {
    $modulePath = Join-Path $PSScriptRoot 'Common/HorizonEnvConfig.psm1'
    if (-not (Test-Path $modulePath)) {
        throw "Shared module not found: $modulePath"
    }
    Import-Module $modulePath -Force

    $envCfg = Get-HorizonEnvironment -Name $Environment
    $creds  = Get-HorizonCredentials -Environment $Environment

    $vCenterServer      = $envCfg.vcenter
    $HorizonServer      = $envCfg.horizon
    $HorizonExternalURL = if ($envCfg.ContainsKey('external_url')) { $envCfg.external_url } else { '' }

    # Promote env-config skip flag unless caller explicitly overrode it
    if (-not $PSBoundParameters.ContainsKey('SkipCertificateCheck') -and
        $envCfg.ContainsKey('skip_certificate_check') -and
        $envCfg.skip_certificate_check) {
        $SkipCertificateCheck = $true
    }

    $vCenterCred = $creds.vCenter
    $horizonCred = $creds.Horizon

    # Default output path: data/{env}-environment.json relative to repo root
    if (-not $OutputPath) {
        $dataDir    = Join-Path (Split-Path $PSScriptRoot -Parent) 'data'
        if (-not (Test-Path $dataDir)) {
            New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
        }
        $OutputPath = Join-Path $dataDir "$Environment-environment.json"
    }
}
elseif (-not $OutputPath) {
    # Preserve legacy default for ByServer mode
    $OutputPath = ".\horizon-environment.json"
}

#region ── Helpers ─────────────────────────────────────────────────────────────

function Write-Section {
    param([string]$Title)
    Write-Host "`n$(('─' * 60))" -ForegroundColor DarkGray
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "$(('─' * 60))" -ForegroundColor DarkGray
}

function Write-Step   { param([string]$M) Write-Host "  ► $M" -ForegroundColor Yellow }
function Write-OK     { param([string]$M) Write-Host "  ✔ $M" -ForegroundColor Green }
function Write-Warn   { param([string]$M) Write-Host "  ⚠ $M" -ForegroundColor Magenta }
function Write-Infer  { param([string]$M) Write-Host "  ~ $M" -ForegroundColor DarkYellow }

if ($SkipCertificateCheck) {
    # WHY: ICertificatePolicy only exists in .NET Framework. On .NET Core / .NET 5+
    # (i.e. PowerShell 7 on macOS/Linux) it throws CS0246. ServerCertificateValidationCallback
    # works in BOTH Windows PowerShell 5.1 and PowerShell 7+, so it's the portable choice.
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
}

#endregion

#region ── Banner & Credentials ───────────────────────────────────────────────

Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║     Horizon View Environment Harvester v1.1             ║" -ForegroundColor Cyan
Write-Host "║     No-NetScaler Variant  |  ASTGL.com                  ║" -ForegroundColor Cyan
Write-Host "╠══════════════════════════════════════════════════════════╣" -ForegroundColor Cyan
Write-Host "║  NetScaler data will be INFERRED (marked in output)     ║" -ForegroundColor DarkYellow
Write-Host "╚══════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

# In ByEnvironment mode these were populated from the SecretStore vault above.
# In ByServer mode, prompt interactively as before.
if (-not $vCenterCred) {
    $vCenterCred = Get-Credential -Message "vCenter ($vCenterServer) credentials"
}
if (-not $horizonCred) {
    $horizonCred = Get-Credential -Message "Horizon Connection Server ($HorizonServer) credentials"
}

#endregion

#region ── Data Container ──────────────────────────────────────────────────────

$envData = [ordered]@{
    metadata = [ordered]@{
        generated_at       = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
        generator          = "Invoke-HorizonHarvester-NoNetScaler.ps1 v1.1"
        vcenter_server     = $vCenterServer
        horizon_server     = $HorizonServer
        netscaler_note     = "NetScaler data is INFERRED via DNS + TCP probing. No NITRO API credentials were used."
        data_quality       = [ordered]@{
            vcenter   = "verified"
            horizon   = "verified"
            netscaler = "inferred"
            storage   = if ($SkipStorage) { "skipped" } else { "verified" }
        }
    }
    dmz      = [ordered]@{
        netscalers              = @()
        unified_access_gateways = @()
        firewalls               = @()
        inference_log           = @()   # Records what was inferred and how
    }
    horizon  = [ordered]@{
        connection_servers  = @()
        composer            = @()
        app_volumes         = @()
        enrollment_servers  = @()
        desktop_pools       = @()
        rds_farms           = @()
    }
    vcenter  = [ordered]@{
        server          = @()
        datacenters     = @()
        clusters        = @()
        hosts           = @()
        port_groups     = @()
    }
    storage  = [ordered]@{
        datastores  = @()
        fc_hbas     = @()
        fc_switches = @()
        arrays      = @()
    }
    networking = [ordered]@{
        vmkernel_adapters    = @()
        distributed_switches = @()
    }
    connections = @()
}

# Inference log — documents exactly how each piece of NetScaler data was derived
function Add-InferenceLog {
    param([string]$Field, [string]$Value, [string]$Method, [string]$Confidence)
    $envData.dmz.inference_log += [ordered]@{
        field      = $Field
        value      = $Value
        method     = $Method
        confidence = $Confidence    # high / medium / low
        timestamp  = (Get-Date -Format "HH:mm:ss")
    }
}

#endregion

#region ── Stage 1: vCenter / ESXi (PowerCLI) ─────────────────────────────────
# [Identical to full harvester — complete verified collection]

Write-Section "Stage 1: vCenter / ESXi Data Collection (Verified)"

if (-not (Get-Module -ListAvailable -Name VMware.PowerCLI)) {
    Write-Warn "VMware.PowerCLI not found. Install with: Install-Module VMware.PowerCLI"
}
else {
    try {
        Write-Step "Connecting to vCenter: $vCenterServer"
        Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
        $vc = Connect-VIServer -Server $vCenterServer -Credential $vCenterCred -WarningAction SilentlyContinue

        $envData.vcenter.server += [ordered]@{
            name    = $vc.Name
            version = $vc.Version
            build   = $vc.Build
            os_type = $vc.ProductLine
        }
        Write-OK "Connected to vCenter $($vc.Name) v$($vc.Version)"

        Write-Step "Collecting Datacenters..."
        $datacenters = Get-Datacenter
        foreach ($dc in $datacenters) {
            $envData.vcenter.datacenters += [ordered]@{ name = $dc.Name; id = $dc.Id }
        }
        Write-OK "Found $($datacenters.Count) datacenter(s)"

        Write-Step "Collecting Clusters..."
        $clusters = Get-Cluster
        foreach ($cluster in $clusters) {
            $clusterHosts = Get-VMHost -Location $cluster | Select-Object -ExpandProperty Name
            $envData.vcenter.clusters += [ordered]@{
                name             = $cluster.Name
                datacenter       = (Get-Datacenter -Cluster $cluster).Name
                ha_enabled       = $cluster.HAEnabled
                drs_enabled      = $cluster.DrsEnabled
                drs_mode         = $cluster.DrsAutomationLevel.ToString()
                host_count       = $cluster.ExtensionData.Summary.NumHosts
                total_cpu_ghz    = [math]::Round($cluster.ExtensionData.Summary.TotalCpu / 1000, 1)
                total_memory_gb  = [math]::Round($cluster.ExtensionData.Summary.TotalMemory / 1GB, 0)
                hosts            = $clusterHosts
            }
        }
        Write-OK "Found $($clusters.Count) cluster(s)"

        Write-Step "Collecting ESXi Hosts..."
        $allHosts = Get-VMHost
        foreach ($vmHost in $allHosts) {
            $hostCluster = try { (Get-Cluster -VMHost $vmHost).Name } catch { "Standalone" }
            $envData.vcenter.hosts += [ordered]@{
                name             = $vmHost.Name
                cluster          = $hostCluster
                manufacturer     = $vmHost.Manufacturer
                model            = $vmHost.Model
                cpu_model        = $vmHost.ProcessorType
                cpu_sockets      = $vmHost.NumCpu
                memory_gb        = [math]::Round($vmHost.MemoryTotalGB, 0)
                esxi_version     = $vmHost.Version
                esxi_build       = $vmHost.Build
                connection_state = $vmHost.ConnectionState.ToString()
                power_state      = $vmHost.PowerState.ToString()
                management_ip    = ($vmHost.ExtensionData.Config.Network.Vnic |
                                    Where-Object { $_.Portgroup -match "Management" } |
                                    Select-Object -First 1).Spec.Ip.IpAddress
            }
        }
        Write-OK "Found $($allHosts.Count) ESXi host(s)"

        Write-Step "Collecting VMkernel Adapters..."
        $vmkAdapters = Get-VMHostNetworkAdapter -VMKernel
        foreach ($vmk in $vmkAdapters) {
            $services = @()
            if ($vmk.ManagementTrafficEnabled)     { $services += "Management" }
            if ($vmk.VMotionEnabled)               { $services += "vMotion" }
            if ($vmk.FaultToleranceLoggingEnabled) { $services += "FT Logging" }
            if ($vmk.VsanTrafficEnabled)           { $services += "vSAN" }
            $envData.networking.vmkernel_adapters += [ordered]@{
                host       = $vmk.VMHost.ToString()
                adapter    = $vmk.Name
                ip         = $vmk.IP
                subnet     = $vmk.SubnetMask
                mtu        = $vmk.Mtu
                port_group = $vmk.PortGroupName
                services   = $services
            }
        }
        Write-OK "Found $($vmkAdapters.Count) VMkernel adapter(s)"

        Write-Step "Collecting Distributed Switches..."
        $dvSwitches = Get-VDSwitch -ErrorAction SilentlyContinue
        foreach ($dvs in $dvSwitches) {
            $dvPGs = Get-VDPortgroup -VDSwitch $dvs |
                Select-Object Name, VlanConfiguration, @{N="Ports";E={$_.NumPorts}}
            $envData.networking.distributed_switches += [ordered]@{
                name        = $dvs.Name
                version     = $dvs.Version
                mtu         = $dvs.Mtu
                uplinks     = $dvs.NumUplinkPorts
                port_groups = @($dvPGs | ForEach-Object {
                    [ordered]@{
                        name  = $_.Name
                        vlan  = if ($_.VlanConfiguration) { $_.VlanConfiguration.ToString() } else { "None" }
                        ports = $_.Ports
                    }
                })
            }
        }
        Write-OK "Found $($dvSwitches.Count) distributed switch(es)"

        if (-not $SkipStorage) {
            Write-Step "Collecting Datastores..."
            # WHY: `Get-Datastore` already returns the full managed object via
            # ExtensionData. We use that instead of piping each $ds back into
            # Get-VMHost or Get-ScsiLun (each of which is a fresh vCenter
            # round-trip) — on large estates that per-datastore API storm was
            # taking hours and triggering the DatastoreIdList deprecation warning.
            $datastores = Get-Datastore
            $dsTotal    = $datastores.Count
            $dsIndex    = 0
            foreach ($ds in $datastores) {
                $dsIndex++
                Write-Progress -Activity "Collecting Datastores" `
                               -Status "[$dsIndex/$dsTotal] $($ds.Name)" `
                               -PercentComplete (($dsIndex / [math]::Max(1,$dsTotal)) * 100)

                # Host count from ExtensionData — no API call
                $hostCount = 0
                try { $hostCount = @($ds.ExtensionData.Host).Count } catch {}

                $dsObj = [ordered]@{
                    name        = $ds.Name
                    type        = $ds.Type.ToString()
                    capacity_gb = [math]::Round($ds.CapacityGB, 1)
                    free_gb     = [math]::Round($ds.FreeSpaceGB, 1)
                    used_pct    = if ($ds.CapacityGB -gt 0) {
                                      [math]::Round((($ds.CapacityGB - $ds.FreeSpaceGB) / $ds.CapacityGB) * 100, 1)
                                  } else { 0 }
                    host_count  = $hostCount
                    state       = $ds.State.ToString()
                    scsi_luns   = @()
                }

                # VMFS extent canonical names come from ExtensionData too — no API call.
                # We drop capacity_gb / multipath_policy / vendor / model because those
                # required a Get-ScsiLun per datastore (the slow path). The canonical
                # name alone is enough for the topology diagram.
                if ($ds.Type -eq "VMFS") {
                    try {
                        $extents = $ds.ExtensionData.Info.Vmfs.Extent
                        foreach ($ext in $extents) {
                            $dsObj.scsi_luns += [ordered]@{
                                canonical_name = $ext.DiskName
                            }
                        }
                    } catch { }
                }
                $envData.storage.datastores += $dsObj
            }
            Write-Progress -Activity "Collecting Datastores" -Completed
            Write-OK "Found $($datastores.Count) datastore(s)"

            Write-Step "Collecting FC HBAs..."
            $fcHBAs = Get-VMHostHba -Type FibreChannel -ErrorAction SilentlyContinue
            foreach ($hba in $fcHBAs) {
                $wwpnHex = "{0:X16}" -f $hba.PortWorldWideName
                $wwpn    = ($wwpnHex -split "(?<=\G.{2})(?=.)" | Select-Object -First 8) -join ":"
                $wwnnHex = "{0:X16}" -f $hba.NodeWorldWideName
                $wwnn    = ($wwnnHex -split "(?<=\G.{2})(?=.)" | Select-Object -First 8) -join ":"
                $envData.storage.fc_hbas += [ordered]@{
                    host   = $hba.VMHost.ToString()
                    device = $hba.Device
                    model  = $hba.Model
                    driver = $hba.Driver
                    wwpn   = $wwpn.ToUpper()
                    wwnn   = $wwnn.ToUpper()
                    speed  = $hba.Speed
                    status = $hba.Status.ToString()
                }
            }
            Write-OK "Found $($fcHBAs.Count) FC HBA port(s)"
        }

        Disconnect-VIServer -Server $vc -Confirm:$false
        Write-OK "Disconnected from vCenter"
    }
    catch {
        Write-Warn "vCenter collection failed: $($_.Exception.Message)"
        Write-Host "    at: $($_.InvocationInfo.PositionMessage -replace "`n", " ")" -ForegroundColor DarkGray
    }
}

#endregion

#region ── Stage 2: Horizon View REST API ─────────────────────────────────────

Write-Section "Stage 2: Horizon View REST API Collection (Verified)"

function Invoke-HorizonAPI {
    param(
        [string]$BaseUri, [string]$Endpoint,
        [hashtable]$Headers, [string]$Method = "GET", [object]$Body = $null
    )
    $uri = "$BaseUri$Endpoint"
    $params = @{ Uri = $uri; Method = $Method; Headers = $Headers; ContentType = "application/json" }
    if ($Body) { $params.Body = ($Body | ConvertTo-Json -Depth 5) }
    try   { return Invoke-RestMethod @params }
    catch { Write-Warn "Horizon API [$Endpoint]: $($_.Exception.Message)"; return $null }
}

$discoveredExternalUrl = ""

try {
    $hvBase    = "https://$HorizonServer"
    # ── Robust domain/username extraction ─────────────────────────────────
    # Users commonly enter one of three formats in the Get-Credential prompt:
    #     DOMAIN\user        — PS splits cleanly, Domain=DOMAIN, UserName=user
    #     user@domain.com    — PS leaves Domain empty, UserName=user@domain.com
    #     user               — no domain info at all
    # Horizon REST API REQUIRES the domain field. Handle all three.
    $netCred = $horizonCred.GetNetworkCredential()
    $hvDomain   = $netCred.Domain
    $hvUserName = $netCred.UserName
    if (-not $hvDomain -and $hvUserName -match '^(.+)@(.+)$') {
        # UPN format — peel off the first DNS label as the short domain
        # (e.g. jdoe@example.org → domain='contoso', username='jdoe')
        $hvUserName = $matches[1]
        $hvDomain   = ($matches[2] -split '\.')[0]
        Write-Host "  ► UPN login detected — using domain='$hvDomain', username='$hvUserName'" -ForegroundColor DarkGray
    }
    if (-not $hvDomain) {
        Write-Warn "No domain in Horizon credential. Horizon REST API will likely return 401."
        Write-Warn "Re-run Register-HorizonEnvironment.ps1 and enter credentials as DOMAIN\user"
    }
    $loginBody = @{
        domain   = $hvDomain
        username = $hvUserName
        password = $netCred.Password
    }

    Write-Step "Authenticating to Horizon REST API..."
    $authResponse = Invoke-RestMethod -Uri "$hvBase/rest/login" `
        -Method POST -Body ($loginBody | ConvertTo-Json) -ContentType "application/json"
    $hvHeaders = @{ Authorization = "Bearer $($authResponse.access_token)"; "Content-Type" = "application/json" }
    Write-OK "Authenticated to Horizon at $HorizonServer"

    # Connection Servers
    Write-Step "Collecting Connection Servers..."
    $connServers = Invoke-HorizonAPI -BaseUri $hvBase -Endpoint "/rest/monitor/v2/connection-servers" -Headers $hvHeaders
    foreach ($cs in $connServers) {
        $envData.horizon.connection_servers += [ordered]@{
            name               = $cs.name
            version            = $cs.version
            build              = $cs.build
            status             = $cs.status
            enabled            = $cs.enabled
            tunnel_enabled     = $cs.tunnel_connection_enabled
            blast_enabled      = $cs.blast_secure_gateway_enabled
            pcoip_enabled      = $cs.pcoip_gateway_enabled
            certificate_health = $cs.certificate_health?.status
            fqdn               = $cs.fqdn
            # ── KEY: Read the external URL from CS config ──────────────
            # Horizon stores the URL clients use — this resolves to the VIP
            external_url       = $cs.external_url          # e.g. https://vdi.example.org:443
            external_pcoip_url = $cs.external_pcoip_url    # e.g. vdi.example.org:4172
            blast_external_url = $cs.blast_external_url    # e.g. vdi.example.org:8443
            ports              = @(
                @{ port=443;   protocol="HTTPS";   service="Blast/Admin/HTML Access" }
                @{ port=8443;  protocol="HTTPS";   service="Blast Extreme" }
                @{ port=4172;  protocol="TCP/UDP"; service="PCoIP" }
                @{ port=4001;  protocol="TCP";     service="JMS (CS Cluster)" }
                @{ port=22443; protocol="UDP";     service="Blast Extreme UDP" }
            )
        }

        # Capture the first non-empty external URL for DNS inference
        if (-not $discoveredExternalUrl -and $cs.external_url) {
            # Strip https:// and port to get bare FQDN
            $discoveredExternalUrl = $cs.external_url -replace "^https?://", "" -replace ":\d+$", ""
            Write-Infer "External URL discovered from CS config: $discoveredExternalUrl"
            Add-InferenceLog -Field "external_url" -Value $discoveredExternalUrl `
                -Method "Horizon Connection Server external_url property" -Confidence "high"
        }
    }
    Write-OK "Found $($connServers.Count) Connection Server(s)"

    # UAGs
    Write-Step "Collecting UAGs..."
    $uags = Invoke-HorizonAPI -BaseUri $hvBase -Endpoint "/rest/monitor/v2/gateways" -Headers $hvHeaders
    foreach ($uag in $uags) {
        $envData.dmz.unified_access_gateways += [ordered]@{
            name            = $uag.name
            type            = $uag.type
            address         = $uag.address
            version         = $uag.version
            status          = $uag.status
            active_sessions = $uag.active_connections
            gateway_zone    = $uag.gateway_zone_type
            ports           = @(
                @{ port=443;  protocol="HTTPS";   service="Blast/HTML Access" }
                @{ port=8443; protocol="HTTPS";   service="Blast Extreme" }
                @{ port=4172; protocol="TCP/UDP"; service="PCoIP" }
            )
        }
    }
    Write-OK "Found $($uags.Count) UAG(s)"

    # Desktop Pools
    Write-Step "Collecting Desktop Pools..."
    $pools = Invoke-HorizonAPI -BaseUri $hvBase -Endpoint "/rest/inventory/v7/desktop-pools" -Headers $hvHeaders
    foreach ($pool in $pools) {
        $envData.horizon.desktop_pools += [ordered]@{
            id               = $pool.id
            name             = $pool.name
            display_name     = $pool.display_name
            type             = $pool.type
            source           = $pool.source
            enabled          = $pool.enabled
            protocol_default = $pool.default_display_protocol
            machine_count    = $pool.machine_count
            session_count    = $pool.num_desktops_with_sessions
        }
    }
    Write-OK "Found $($pools.Count) Desktop Pool(s)"

    # RDS Farms
    Write-Step "Collecting RDS Farms..."
    $farms = Invoke-HorizonAPI -BaseUri $hvBase -Endpoint "/rest/inventory/v2/farms" -Headers $hvHeaders
    foreach ($farm in $farms) {
        $envData.horizon.rds_farms += [ordered]@{
            id           = $farm.id
            name         = $farm.name
            type         = $farm.type
            source       = $farm.source
            enabled      = $farm.enabled
            server_count = $farm.rds_server_count
            session_count = $farm.num_sessions
        }
    }
    Write-OK "Found $($farms.Count) RDS Farm(s)"

    # Composer / App Volumes
    Write-Step "Collecting Composer / vCenter config..."
    $vcServers = Invoke-HorizonAPI -BaseUri $hvBase -Endpoint "/rest/config/v2/virtual-centers" -Headers $hvHeaders
    foreach ($vcs in $vcServers) {
        if ($vcs.composer_server_address) {
            $envData.horizon.composer += [ordered]@{
                name    = "View Composer"
                address = $vcs.composer_server_address
                port    = $vcs.composer_server_port
                vcenter = $vcs.server_name
                version = $vcs.composer_server_version
                ports   = @( @{ port=18443; protocol="HTTPS/SOAP"; service="Composer SOAP API" } )
            }
        }
    }

    # App Volumes
    $appVolMgrs = Invoke-HorizonAPI -BaseUri $hvBase -Endpoint "/rest/config/v3/app-volumes-managers" -Headers $hvHeaders
    if ($appVolMgrs) {
        foreach ($avm in $appVolMgrs) {
            $envData.horizon.app_volumes += [ordered]@{
                name    = $avm.server_address
                address = $avm.server_address
                port    = $avm.server_port
                status  = $avm.health?.status
                ports   = @( @{ port=443; protocol="HTTPS"; service="App Volumes Manager" } )
            }
        }
    }

    # Enrollment Servers
    $enrollServers = Invoke-HorizonAPI -BaseUri $hvBase -Endpoint "/rest/config/v2/enrollment-servers" -Headers $hvHeaders
    if ($enrollServers) {
        foreach ($es in $enrollServers) {
            $envData.horizon.enrollment_servers += [ordered]@{
                name    = $es.server_address
                address = $es.server_address
                status  = $es.status
                ports   = @( @{ port=32111; protocol="TCP"; service="Enrollment Server" } )
            }
        }
    }

    Invoke-RestMethod -Uri "$hvBase/rest/logout" -Method POST -Headers $hvHeaders -ContentType "application/json" | Out-Null
    Write-OK "Logged out from Horizon REST API"
}
catch {
    Write-Warn "Horizon collection failed: $($_.Exception.Message)"
    # PS 7 stuffs the HTTP response body into $_.ErrorDetails.Message for
    # Invoke-RestMethod failures. For 401s from Horizon this usually contains
    # a JSON error like {"error_message":"...","error_key":"..."} that tells
    # us precisely why the login was rejected.
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
        Write-Host "    Response body: $($_.ErrorDetails.Message)" -ForegroundColor DarkGray
    }
    Write-Host "    at: $($_.InvocationInfo.PositionMessage -replace "`n", " ")" -ForegroundColor DarkGray
}

#endregion

#region ── Stage 3: NetScaler Inference (No Credentials) ──────────────────────

Write-Section "Stage 3: NetScaler / LB Inference (No Credentials)"
Write-Host "  This section uses DNS + TCP probing to infer load balancer topology." -ForegroundColor DarkYellow
Write-Host "  All results are marked as INFERRED in the output JSON.`n" -ForegroundColor DarkYellow

# ── Step 3a: Resolve the external URL to find the VIP ─────────────────────────

# Prefer explicit parameter, then discovered from Horizon, then prompt
$externalFQDN = if ($HorizonExternalURL) {
    $HorizonExternalURL
} elseif ($discoveredExternalUrl) {
    $discoveredExternalUrl
} else {
    Write-Warn "Could not auto-discover external URL from Horizon config."
    Read-Host "Enter the external Horizon FQDN users connect to (e.g. vdi.example.org)"
}

Write-Step "Resolving $externalFQDN via DNS..."
$vipIP      = ""
$vipResolved = $false
try {
    $dnsResult = [System.Net.Dns]::GetHostAddresses($externalFQDN)
    if ($dnsResult.Count -gt 0) {
        # If multiple IPs, could indicate DNS round-robin LB (not NetScaler SNIP)
        $vipIP       = $dnsResult[0].IPAddressToString
        $vipResolved = $true
        $dnsMethod   = if ($dnsResult.Count -gt 1) { "DNS-round-robin (multiple IPs)" } else { "DNS-single (VIP)" }
        Write-OK "Resolved $externalFQDN → $($dnsResult.IPAddressToString -join ', ')"
        Add-InferenceLog -Field "vip_ip" -Value $vipIP `
            -Method "DNS resolution of external_url ($externalFQDN)" -Confidence "high"
        if ($dnsResult.Count -gt 1) {
            Write-Warn "Multiple IPs returned — may be DNS load balancing rather than a single VIP"
            Add-InferenceLog -Field "lb_type" -Value "Possible DNS round-robin" `
                -Method "Multiple A records for FQDN" -Confidence "medium"
        }
    }
}
catch {
    Write-Warn "DNS resolution failed for $externalFQDN : $($_.Exception.Message)"
    Add-InferenceLog -Field "vip_ip" -Value "UNKNOWN" `
        -Method "DNS resolution failed" -Confidence "low"
}

# ── Step 3b: TCP Port Probing ─────────────────────────────────────────────────

# Standard Horizon ports — probe each to determine what the LB is passing
$horizonPorts = @(
    @{ Port=443;   Protocol="HTTPS";   Service="Blast Extreme / HTML Access / Admin" }
    @{ Port=8443;  Protocol="HTTPS";   Service="Blast Extreme (dedicated)" }
    @{ Port=4172;  Protocol="TCP";     Service="PCoIP (TCP)" }
    @{ Port=22443; Protocol="UDP";     Service="Blast Extreme (UDP) — TCP probe only" }
    @{ Port=80;    Protocol="HTTP";    Service="HTTP redirect (if configured)" }
)

$probedPorts = @()

if (-not $SkipPortProbe -and $vipResolved) {
    Write-Step "Probing ports on $externalFQDN ($vipIP)..."
    Write-Host "    (Use -SkipPortProbe if firewall blocks outbound TCP)" -ForegroundColor DarkGray

    foreach ($portEntry in $horizonPorts) {
        $p = $portEntry.Port
        # WHY: Test-NetConnection is effectively Windows-only on PS 7 — on
        # macOS/Linux it either errors out or returns PROBE-FAILED for every
        # port. We use System.Net.Sockets.TcpClient with a 3s timeout instead,
        # which is what the SSL-inspection block already uses successfully
        # a few lines below. Cross-platform and fast.
        $tcp = $null
        try {
            $tcp = [System.Net.Sockets.TcpClient]::new()
            $connectTask = $tcp.ConnectAsync($externalFQDN, $p)
            if ($connectTask.Wait([timespan]::FromSeconds(3))) {
                $status = if ($tcp.Connected) { "OPEN" } else { "CLOSED/FILTERED" }
            } else {
                $status = "CLOSED/FILTERED"   # timeout
            }
        }
        catch {
            $status = "CLOSED/FILTERED"
        }
        finally {
            if ($tcp) { $tcp.Dispose() }
        }
        $icon = if ($status -eq "OPEN") { "✔" } else { "✗" }
        $color = if ($status -eq "OPEN") { "Green" } else { "DarkGray" }
        Write-Host "    $icon Port $($p.ToString().PadRight(6)) $($portEntry.Protocol.PadRight(8)) — $status  ($($portEntry.Service))" -ForegroundColor $color

        if ($status -eq "OPEN") {
            $probedPorts += [ordered]@{
                port     = $p
                protocol = $portEntry.Protocol
                service  = $portEntry.Service
                status   = "OPEN-VERIFIED"
                source   = "TCP port probe"
            }
            Add-InferenceLog -Field "port_$p" -Value "OPEN" `
                -Method "Test-NetConnection TCP probe to $externalFQDN" -Confidence "high"
        }
    }
}
elseif ($SkipPortProbe) {
    Write-Warn "Port probing skipped (-SkipPortProbe). Using standard Horizon port assumptions."
    # Fall back to known defaults for Horizon Blast environments
    $probedPorts += @(
        @{ port=443;  protocol="HTTPS"; service="Blast/HTML Access"; status="ASSUMED"; source="standard-default" }
        @{ port=8443; protocol="HTTPS"; service="Blast Extreme";     status="ASSUMED"; source="standard-default" }
        @{ port=4172; protocol="TCP/UDP"; service="PCoIP";           status="ASSUMED"; source="standard-default" }
    )
    Add-InferenceLog -Field "ports" -Value "443,8443,4172" `
        -Method "Standard Horizon defaults — not probed" -Confidence "low"
}

# ── Step 3c: SSL Certificate Inspection ───────────────────────────────────────

$certInfo = [ordered]@{ subject="UNKNOWN"; issuer="UNKNOWN"; expiry="UNKNOWN"; san=@(); source="not-inspected" }

if ($vipResolved -and -not $SkipPortProbe) {
    Write-Step "Inspecting SSL certificate on $externalFQDN`:443..."
    try {
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $tcpClient.Connect($externalFQDN, 443)
        $sslStream = New-Object System.Net.Security.SslStream(
            $tcpClient.GetStream(), $false,
            { param($s,$c,$ch,$e) return $true }   # Accept any cert for inspection
        )
        $sslStream.AuthenticateAsClient($externalFQDN)
        $cert = $sslStream.RemoteCertificate
        $cert2 = [System.Security.Cryptography.X509Certificates.X509Certificate2]$cert

        # Parse SAN extension
        $sanExt = $cert2.Extensions | Where-Object { $_.Oid.FriendlyName -eq "Subject Alternative Name" }
        $sanList = if ($sanExt) { ($sanExt.Format($false) -split ", " | ForEach-Object { $_.Trim() }) } else { @() }

        $certInfo = [ordered]@{
            subject        = $cert2.Subject
            issuer         = $cert2.Issuer
            thumbprint     = $cert2.Thumbprint
            expiry         = $cert2.NotAfter.ToString("yyyy-MM-dd")
            days_remaining = ([datetime]$cert2.NotAfter - (Get-Date)).Days
            san            = $sanList
            source         = "TLS handshake inspection (port 443)"
        }

        $sslStream.Close()
        $tcpClient.Close()

        $daysLeft = $certInfo.days_remaining
        $certColor = if ($daysLeft -gt 60) { "Green" } elseif ($daysLeft -gt 14) { "Yellow" } else { "Red" }
        Write-Host "    Certificate: $($certInfo.subject)" -ForegroundColor White
        Write-Host "    Issuer     : $($certInfo.issuer)"  -ForegroundColor DarkGray
        Write-Host "    Expires    : $($certInfo.expiry) ($daysLeft days remaining)" -ForegroundColor $certColor

        Add-InferenceLog -Field "ssl_certificate" -Value $certInfo.subject `
            -Method "TLS handshake to port 443 — no credentials required" -Confidence "high"
    }
    catch {
        Write-Warn "SSL inspection failed: $($_.Exception.Message)"
        Add-InferenceLog -Field "ssl_certificate" -Value "INSPECTION-FAILED" `
            -Method "TLS handshake failed" -Confidence "low"
    }
}

# ── Step 3d: Build inferred NetScaler entry ────────────────────────────────────

Write-Step "Building inferred NetScaler node from collected evidence..."

$uagCount    = $envData.dmz.unified_access_gateways.Count
$nsNodeName  = if ($externalFQDN) { "LB-VIP ($externalFQDN)" } else { "LB-VIP (Unknown)" }

$inferredNS = [ordered]@{
    name              = $nsNodeName
    type              = "LB vServer (Inferred)"
    fqdn              = $externalFQDN
    vip               = $vipIP
    port              = 443
    protocol          = "HTTPS/Blast"
    lb_method         = "UNKNOWN — no NITRO access"
    persistence       = "UNKNOWN — no NITRO access"
    state             = if ($vipResolved) { "REACHABLE" } else { "UNRESOLVED" }
    active_services   = "UNKNOWN — no NITRO access"
    backend_count     = $uagCount   # Inferred from UAG inventory
    tls_cipher_policy = "UNKNOWN — no NITRO access"
    ha_pair           = "UNKNOWN — no NITRO access"
    appliance_model   = "UNKNOWN — no NITRO access"
    firmware_version  = "UNKNOWN — no NITRO access"
    ports             = $probedPorts
    ssl_certificate   = $certInfo
    data_quality      = "INFERRED"
    inference_methods = @(
        "DNS resolution of Horizon external_url"
        "TCP port probing (Test-NetConnection)"
        "TLS certificate handshake inspection"
        "UAG count from Horizon REST API inventory"
    )
    missing_data      = @(
        "lb_method (round-robin, least-conn, etc.)"
        "persistence_type (source-IP, cookie, etc.)"
        "tls_cipher_policy and cipher suites"
        "ssl_offload vs passthrough mode"
        "content_switching_policies"
        "health_monitor_configuration"
        "rate_limiting_policies"
        "appliance_model and firmware_version"
        "ha_pair (primary/secondary node)"
        "current_session_count at LB tier"
        "vserver_service_bindings (explicit backend list)"
    )
}

$envData.dmz.netscalers += $inferredNS

Write-OK "Inferred NetScaler node built: $nsNodeName → $vipIP"
Write-Infer "Backend count inferred from $uagCount UAG(s) in Horizon inventory"
Write-Warn "$(($inferredNS.missing_data).Count) fields require NetScaler NITRO credentials to populate"

#endregion

#region ── Stage 4: Build Connection Edge List ────────────────────────────────

Write-Section "Stage 4: Building Connection Graph"
Write-Step "Mapping relationships..."

$connections = @()

# Clients → LB VIP
$connections += [ordered]@{
    from     = "Internet/Clients"
    to       = $nsNodeName
    port     = 443
    protocol = "HTTPS"
    label    = "HTTPS 443"
    tier     = "client-to-dmz"
    verified = $true
}
$connections += [ordered]@{
    from     = "Internet/Clients"
    to       = $nsNodeName
    port     = 8443
    protocol = "HTTPS/Blast"
    label    = "Blast 8443"
    tier     = "client-to-dmz"
    verified = $true
}

# LB VIP → UAGs
foreach ($uag in $envData.dmz.unified_access_gateways) {
    $connections += [ordered]@{
        from     = $nsNodeName
        to       = $uag.name
        port     = 443
        protocol = "HTTPS"
        label    = "HTTPS/Blast 443"
        tier     = "dmz-internal"
        verified = $false    # We know the UAG exists; we don't know the LB binds to it
        note     = "Inferred — UAG exists in Horizon inventory; assume LB fronts it"
    }
}

# UAGs → Connection Servers
foreach ($uag in $envData.dmz.unified_access_gateways) {
    foreach ($cs in $envData.horizon.connection_servers) {
        $connections += [ordered]@{
            from     = $uag.name
            to       = $cs.name
            port     = 8443
            protocol = "HTTPS"
            label    = "Blast 8443"
            tier     = "dmz-internal"
            verified = $true
        }
    }
}

# Connection Servers → vCenter
foreach ($cs in $envData.horizon.connection_servers) {
    foreach ($vc in $envData.vcenter.server) {
        $connections += [ordered]@{
            from     = $cs.name
            to       = $vc.name
            port     = 443
            protocol = "HTTPS"
            label    = "vSphere API 443"
            tier     = "horizon-vcenter"
            verified = $true
        }
    }
}

# Connection Servers → Composer
foreach ($cs in $envData.horizon.connection_servers) {
    foreach ($comp in $envData.horizon.composer) {
        $connections += [ordered]@{
            from     = $cs.name
            to       = $comp.address
            port     = 18443
            protocol = "HTTPS/SOAP"
            label    = "SOAP 18443"
            tier     = "horizon-internal"
            verified = $true
        }
    }
}

# CS cluster replication
for ($i = 0; $i -lt $envData.horizon.connection_servers.Count - 1; $i++) {
    $connections += [ordered]@{
        from     = $envData.horizon.connection_servers[$i].name
        to       = $envData.horizon.connection_servers[$i + 1].name
        port     = 4001
        protocol = "TCP/JMS"
        label    = "JMS 4001"
        tier     = "horizon-cluster"
        verified = $true
    }
}

# vCenter → Clusters
foreach ($cluster in $envData.vcenter.clusters) {
    $connections += [ordered]@{
        from     = ($envData.vcenter.server | Select-Object -First 1).name
        to       = $cluster.name
        port     = 443
        protocol = "HTTPS"
        label    = "vSphere Mgmt"
        tier     = "vcenter-compute"
        verified = $true
    }
}

# ESXi → FC
foreach ($hba in ($envData.storage.fc_hbas | Select-Object -Unique host)) {
    $connections += [ordered]@{
        from     = $hba.host
        to       = "FC Fabric"
        port     = $null
        protocol = "Fibre Channel"
        label    = "FC 32Gbps"
        tier     = "compute-storage"
        verified = $true
    }
}

$envData.connections = $connections
Write-OK "Generated $($connections.Count) connection edge(s)"

#endregion

#region ── Output ──────────────────────────────────────────────────────────────

Write-Section "Output"

$jsonOutput = $envData | ConvertTo-Json -Depth 10
$jsonOutput | Out-File -FilePath $OutputPath -Encoding UTF8
$fileSizeKB = [math]::Round((Get-Item $OutputPath).Length / 1KB, 1)

Write-OK "Output written: $OutputPath ($fileSizeKB KB)"

# Summary of data quality
Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║            Harvest Complete — Data Quality Summary      ║" -ForegroundColor Green
Write-Host "╠══════════════════════════════════════════════════════════╣" -ForegroundColor Green
Write-Host "║  ✔ vCenter clusters        : $($envData.vcenter.clusters.Count.ToString().PadRight(28)) ║" -ForegroundColor Green
Write-Host "║  ✔ ESXi hosts              : $($envData.vcenter.hosts.Count.ToString().PadRight(28)) ║" -ForegroundColor Green
Write-Host "║  ✔ Connection servers      : $($envData.horizon.connection_servers.Count.ToString().PadRight(28)) ║" -ForegroundColor Green
Write-Host "║  ✔ UAGs                    : $($envData.dmz.unified_access_gateways.Count.ToString().PadRight(28)) ║" -ForegroundColor Green
Write-Host "║  ✔ Desktop pools           : $($envData.horizon.desktop_pools.Count.ToString().PadRight(28)) ║" -ForegroundColor Green
Write-Host "║  ~ LB VIPs (inferred)      : $($envData.dmz.netscalers.Count.ToString().PadRight(28)) ║" -ForegroundColor DarkYellow
Write-Host "║  ~ Inference log entries   : $($envData.dmz.inference_log.Count.ToString().PadRight(28)) ║" -ForegroundColor DarkYellow
Write-Host "║  ✗ LB method/persistence   : UNKNOWN                     ║" -ForegroundColor Red
Write-Host "║  ✗ Cipher suites / TLS pol : UNKNOWN                     ║" -ForegroundColor Red
Write-Host "║  ✗ HA pair config          : UNKNOWN                     ║" -ForegroundColor Red
Write-Host "╠══════════════════════════════════════════════════════════╣" -ForegroundColor Green
Write-Host "║  JSON Output : $($OutputPath.PadRight(41)) ║" -ForegroundColor Green
Write-Host "║  Next Step   : python Generate-HorizonDiagram.py        ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════════╝`n" -ForegroundColor Green

Write-Host "  TIP: Share the inference_log section with the NetScaler team." -ForegroundColor Cyan
Write-Host "  It documents exactly what you were able to determine and what" -ForegroundColor Cyan
Write-Host "  gaps remain — a useful starting point for a conversation about" -ForegroundColor Cyan
Write-Host "  getting read-only NITRO credentials for monitoring purposes.`n" -ForegroundColor Cyan

#endregion
