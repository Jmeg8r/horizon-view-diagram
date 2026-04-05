#Requires -Version 5.1
<#
.SYNOPSIS
    Horizon View Environment Harvester
    Scans VMware Horizon, vCenter, NetScaler, and FC Storage — outputs normalized JSON
    for automated diagram generation.

.DESCRIPTION
    This script collects infrastructure data from:
        - VMware vCenter (hosts, clusters, datastores, HBAs, port groups)
        - VMware Horizon View REST API (connection servers, UAGs, pools, farms, composer)
        - Citrix NetScaler / ADC NITRO API (VIPs, services, SSL bindings, ports)
        - Fibre Channel fabric (via ESXi HBA data and optional storage array APIs)

    Output is a single normalized JSON file consumed by Generate-HorizonDiagram.py

.PARAMETER OutputPath
    Path to write the output JSON file. Defaults to .\horizon-environment.json

.PARAMETER vCenterServer
    FQDN or IP of your vCenter Server.

.PARAMETER HorizonServer
    FQDN or IP of a Horizon Connection Server (used for REST API calls).

.PARAMETER NetScalerServer
    FQDN or IP of your NetScaler / Citrix ADC management IP.

.PARAMETER SkipNetScaler
    Switch to skip NetScaler data collection.

.PARAMETER SkipStorage
    Switch to skip Fibre Channel / datastore deep collection.

.PARAMETER SkipCertificateCheck
    Bypass SSL certificate validation (useful in labs or with self-signed certs).

.EXAMPLE
    .\Invoke-HorizonHarvester.ps1 `
        -vCenterServer vcenter.example.org `
        -HorizonServer horizon-cs01.example.org `
        -NetScalerServer ns-vip.example.org `
        -OutputPath C:\Diagrams\horizon-environment.json

.NOTES
    Author  : ASTGL - As The Geek Learns (astgl.com)
    Version : 1.0.0
    Requires: VMware.PowerCLI module (Install-Module VMware.PowerCLI)
    Horizon : Uses REST API (Horizon 7.8+)
    NetScaler: Uses NITRO REST API v1
#>

[CmdletBinding()]
param(
    [string]$OutputPath        = ".\horizon-environment.json",
    [Parameter(Mandatory)][string]$vCenterServer,
    [Parameter(Mandatory)][string]$HorizonServer,
    [string]$NetScalerServer   = "",
    [switch]$SkipNetScaler,
    [switch]$SkipStorage,
    [switch]$SkipCertificateCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region ── Helpers ─────────────────────────────────────────────────────────────

function Write-Section {
    param([string]$Title)
    Write-Host "`n$(('─' * 60))" -ForegroundColor DarkGray
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "$(('─' * 60))" -ForegroundColor DarkGray
}

function Write-Step {
    param([string]$Message)
    Write-Host "  ► $Message" -ForegroundColor Yellow
}

function Write-OK {
    param([string]$Message)
    Write-Host "  ✔ $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  ⚠ $Message" -ForegroundColor Magenta
}

function ConvertTo-SafeJson {
    param($Object)
    # Avoid circular references by serializing depth-limited
    return $Object | ConvertTo-Json -Depth 8 -Compress:$false
}

# Ignore SSL errors if requested (lab/dev environments with self-signed certs)
if ($SkipCertificateCheck) {
    if (-not ([System.Management.Automation.PSTypeName]'TrustAllCerts').Type) {
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCerts : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert,
        WebRequest req, int prob) { return true; }
}
"@
    }
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCerts
    [System.Net.ServicePointManager]::SecurityProtocol  = [System.Net.SecurityProtocolType]::Tls12
}

#endregion

#region ── Credential Collection ───────────────────────────────────────────────

Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║        Horizon View Environment Harvester v1.0          ║" -ForegroundColor Cyan
Write-Host "║           ASTGL - As The Geek Learns                    ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

Write-Host "Enter credentials for each system below." -ForegroundColor White
Write-Host "(Credentials are used in-memory only and not written to disk)`n" -ForegroundColor DarkGray

$vCenterCred  = Get-Credential -Message "vCenter ($vCenterServer) credentials"
$horizonCred  = Get-Credential -Message "Horizon Connection Server ($HorizonServer) credentials"

if (-not $SkipNetScaler -and $NetScalerServer) {
    $nsCred = Get-Credential -Message "NetScaler ($NetScalerServer) credentials"
}

#endregion

#region ── Data Container ──────────────────────────────────────────────────────

$environment = [ordered]@{
    metadata           = [ordered]@{
        generated_at   = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
        generator      = "Invoke-HorizonHarvester.ps1 v1.0"
        vcenter_server = $vCenterServer
        horizon_server = $HorizonServer
    }
    dmz                = [ordered]@{
        netscalers     = @()
        unified_access_gateways = @()
        firewalls      = @()
    }
    horizon            = [ordered]@{
        connection_servers = @()
        composer           = @()
        app_volumes        = @()
        enrollment_servers = @()
        desktop_pools      = @()
        rds_farms          = @()
    }
    vcenter            = [ordered]@{
        server         = @()
        datacenters    = @()
        clusters       = @()
        hosts          = @()
        port_groups    = @()
    }
    storage            = [ordered]@{
        datastores     = @()
        fc_hbas        = @()
        fc_switches    = @()
        arrays         = @()
    }
    networking         = [ordered]@{
        vmkernel_adapters = @()
        distributed_switches = @()
    }
    connections        = @()   # Populated last — edge list for diagram
}

#endregion

#region ── Stage 1: vCenter / ESXi (PowerCLI) ─────────────────────────────────

Write-Section "Stage 1: vCenter / ESXi Data Collection"

# Verify PowerCLI is available
if (-not (Get-Module -ListAvailable -Name VMware.PowerCLI)) {
    Write-Warn "VMware.PowerCLI module not found. Install with: Install-Module VMware.PowerCLI"
    Write-Warn "Skipping vCenter collection..."
}
else {
    try {
        Write-Step "Connecting to vCenter: $vCenterServer"
        Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
        $vc = Connect-VIServer -Server $vCenterServer -Credential $vCenterCred -WarningAction SilentlyContinue

        # ── vCenter Server Info ───────────────────────────────────────────
        $environment.vcenter.server += [ordered]@{
            name    = $vc.Name
            version = $vc.Version
            build   = $vc.Build
            os_type = $vc.ProductLine
        }
        Write-OK "Connected to vCenter $($vc.Name) v$($vc.Version)"

        # ── Datacenters ───────────────────────────────────────────────────
        Write-Step "Collecting Datacenters..."
        $datacenters = Get-Datacenter
        foreach ($dc in $datacenters) {
            $environment.vcenter.datacenters += [ordered]@{
                name = $dc.Name
                id   = $dc.Id
            }
        }
        Write-OK "Found $($datacenters.Count) datacenter(s)"

        # ── Clusters ──────────────────────────────────────────────────────
        Write-Step "Collecting Clusters..."
        $clusters = Get-Cluster
        foreach ($cluster in $clusters) {
            $clusterHosts = Get-VMHost -Location $cluster | Select-Object -ExpandProperty Name
            $environment.vcenter.clusters += [ordered]@{
                name               = $cluster.Name
                datacenter         = (Get-Datacenter -Cluster $cluster).Name
                ha_enabled         = $cluster.HAEnabled
                drs_enabled        = $cluster.DrsEnabled
                drs_mode           = $cluster.DrsAutomationLevel.ToString()
                host_count         = $cluster.ExtensionData.Summary.NumHosts
                total_cpu_ghz      = [math]::Round($cluster.ExtensionData.Summary.TotalCpu / 1000, 1)
                total_memory_gb    = [math]::Round($cluster.ExtensionData.Summary.TotalMemory / 1GB, 0)
                hosts              = $clusterHosts
            }
        }
        Write-OK "Found $($clusters.Count) cluster(s)"

        # ── ESXi Hosts ────────────────────────────────────────────────────
        Write-Step "Collecting ESXi Hosts (this may take a moment)..."
        $allHosts = Get-VMHost
        foreach ($vmHost in $allHosts) {
            $hostCluster = try { (Get-Cluster -VMHost $vmHost).Name } catch { "Standalone" }
            $hostNics = Get-VMHostNetworkAdapter -VMHost $vmHost -Physical |
                Select-Object Name, Mac, BitRatePerSec,
                    @{N="SpeedGbps";E={[math]::Round($_.BitRatePerSec / 1000, 0)}}

            $environment.vcenter.hosts += [ordered]@{
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
                physical_nics    = @($hostNics)
            }
        }
        Write-OK "Found $($allHosts.Count) ESXi host(s)"

        # ── VMkernel Adapters ─────────────────────────────────────────────
        Write-Step "Collecting VMkernel Adapters..."
        $vmkAdapters = Get-VMHostNetworkAdapter -VMKernel
        foreach ($vmk in $vmkAdapters) {
            $services = @()
            if ($vmk.ManagementTrafficEnabled)        { $services += "Management" }
            if ($vmk.VMotionEnabled)                  { $services += "vMotion" }
            if ($vmk.FaultToleranceLoggingEnabled)    { $services += "FT Logging" }
            if ($vmk.VsanTrafficEnabled)              { $services += "vSAN" }

            $environment.networking.vmkernel_adapters += [ordered]@{
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

        # ── Distributed Virtual Switches ──────────────────────────────────
        Write-Step "Collecting Distributed Switches..."
        $dvSwitches = Get-VDSwitch -ErrorAction SilentlyContinue
        foreach ($dvs in $dvSwitches) {
            $dvPGs = Get-VDPortgroup -VDSwitch $dvs |
                Select-Object Name, VlanConfiguration, @{N="Ports";E={$_.NumPorts}}

            $environment.networking.distributed_switches += [ordered]@{
                name       = $dvs.Name
                version    = $dvs.Version
                mtu        = $dvs.Mtu
                uplinks    = $dvs.NumUplinkPorts
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

        # ── Port Groups (Standard vSwitches) ──────────────────────────────
        Write-Step "Collecting Standard vSwitch Port Groups..."
        $portGroups = Get-VirtualPortGroup -Standard -ErrorAction SilentlyContinue
        foreach ($pg in $portGroups) {
            $environment.vcenter.port_groups += [ordered]@{
                name         = $pg.Name
                vlan_id      = $pg.VLanId
                virtual_switch = $pg.VirtualSwitchName
                host         = $pg.VMHostId
            }
        }
        Write-OK "Found $($portGroups.Count) standard port group(s)"

        # ── Datastores ────────────────────────────────────────────────────
        if (-not $SkipStorage) {
            Write-Step "Collecting Datastores..."
            $datastores = Get-Datastore
            foreach ($ds in $datastores) {
                $dsObj = [ordered]@{
                    name          = $ds.Name
                    type          = $ds.Type.ToString()
                    capacity_gb   = [math]::Round($ds.CapacityGB, 1)
                    free_gb       = [math]::Round($ds.FreeSpaceGB, 1)
                    used_pct      = [math]::Round((($ds.CapacityGB - $ds.FreeSpaceGB) / $ds.CapacityGB) * 100, 1)
                    host_count    = ($ds | Get-VMHost).Count
                    state         = $ds.State.ToString()
                    scsi_luns     = @()
                }

                # For VMFS datastores, get the backing SCSI LUN details
                if ($ds.Type -eq "VMFS") {
                    try {
                        $luns = $ds | Get-ScsiLun -ErrorAction SilentlyContinue
                        foreach ($lun in $luns) {
                            $dsObj.scsi_luns += [ordered]@{
                                canonical_name    = $lun.CanonicalName
                                capacity_gb       = [math]::Round($lun.CapacityGB, 1)
                                multipath_policy  = $lun.MultipathPolicy.ToString()
                                vendor            = $lun.Vendor.Trim()
                                model             = $lun.Model.Trim()
                                lun_type          = $lun.LunType.ToString()
                            }
                        }
                    } catch {
                        # ScsiLun not always available from all hosts — skip silently
                    }
                }
                $environment.storage.datastores += $dsObj
            }
            Write-OK "Found $($datastores.Count) datastore(s)"

            # ── Fibre Channel HBAs ────────────────────────────────────────
            Write-Step "Collecting Fibre Channel HBAs..."
            $fcHBAs = Get-VMHostHba -Type FibreChannel -ErrorAction SilentlyContinue
            foreach ($hba in $fcHBAs) {
                # Format WWPN/WWNN from decimal to colon-separated hex
                $wwpnHex = "{0:X16}" -f $hba.PortWorldWideName
                $wwpn = ($wwpnHex -split "(?<=\G.{2})(?=.)" | Select-Object -First 8) -join ":"

                $wwnnHex = "{0:X16}" -f $hba.NodeWorldWideName
                $wwnn = ($wwnnHex -split "(?<=\G.{2})(?=.)" | Select-Object -First 8) -join ":"

                $environment.storage.fc_hbas += [ordered]@{
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
    }
}

#endregion

#region ── Stage 2: Horizon View REST API ─────────────────────────────────────

Write-Section "Stage 2: Horizon View REST API Collection"

function Invoke-HorizonAPI {
    param(
        [string]$BaseUri,
        [string]$Endpoint,
        [hashtable]$Headers,
        [string]$Method = "GET",
        [object]$Body = $null
    )
    $uri = "$BaseUri$Endpoint"
    $params = @{
        Uri         = $uri
        Method      = $Method
        Headers     = $Headers
        ContentType = "application/json"
    }
    if ($Body) { $params.Body = ($Body | ConvertTo-Json -Depth 5) }
    try {
        return Invoke-RestMethod @params
    }
    catch {
        Write-Warn "Horizon API call failed [$Endpoint]: $($_.Exception.Message)"
        return $null
    }
}

try {
    $hvBase = "https://$HorizonServer"

    Write-Step "Authenticating to Horizon REST API..."
    $loginBody = @{
        domain   = $horizonCred.GetNetworkCredential().Domain
        username = $horizonCred.GetNetworkCredential().UserName
        password = $horizonCred.GetNetworkCredential().Password
    }

    $authResponse = Invoke-RestMethod -Uri "$hvBase/rest/login" `
        -Method POST `
        -Body ($loginBody | ConvertTo-Json) `
        -ContentType "application/json"

    $hvHeaders = @{
        Authorization  = "Bearer $($authResponse.access_token)"
        "Content-Type" = "application/json"
    }
    Write-OK "Authenticated to Horizon at $HorizonServer"

    # ── Connection Servers ────────────────────────────────────────────────
    Write-Step "Collecting Connection Servers..."
    $connServers = Invoke-HorizonAPI -BaseUri $hvBase `
        -Endpoint "/rest/monitor/v2/connection-servers" -Headers $hvHeaders

    foreach ($cs in $connServers) {
        $environment.horizon.connection_servers += [ordered]@{
            name             = $cs.name
            version          = $cs.version
            build            = $cs.build
            status           = $cs.status
            enabled          = $cs.enabled
            cs_replication   = $cs.cs_replication_status
            tunnel_enabled   = $cs.tunnel_connection_enabled
            blast_enabled    = $cs.blast_secure_gateway_enabled
            pcoip_enabled    = $cs.pcoip_gateway_enabled
            certificate_health = $cs.certificate_health?.status
            fqdn             = $cs.fqdn
            # Ports in use (standard Horizon ports)
            ports            = @(
                @{ port=443;   protocol="HTTPS"; service="Blast/Admin/HTML Access" }
                @{ port=8443;  protocol="HTTPS"; service="Blast Extreme" }
                @{ port=4172;  protocol="TCP/UDP"; service="PCoIP" }
                @{ port=4001;  protocol="TCP"; service="JMS (CS Cluster)" }
                @{ port=22443; protocol="UDP"; service="Blast Extreme UDP" }
            )
        }
    }
    Write-OK "Found $($connServers.Count) Connection Server(s)"

    # ── Unified Access Gateways ───────────────────────────────────────────
    Write-Step "Collecting Unified Access Gateways..."
    $uags = Invoke-HorizonAPI -BaseUri $hvBase `
        -Endpoint "/rest/monitor/v2/gateways" -Headers $hvHeaders

    foreach ($uag in $uags) {
        $environment.dmz.unified_access_gateways += [ordered]@{
            name             = $uag.name
            type             = $uag.type          # INTERNAL or UAG
            address          = $uag.address
            version          = $uag.version
            status           = $uag.status
            active_sessions  = $uag.active_connections
            gateway_zone     = $uag.gateway_zone_type
            paired_connection_server = $uag.connection_server_id
            ports            = @(
                @{ port=443;   protocol="HTTPS"; service="Blast/HTML Access" }
                @{ port=8443;  protocol="HTTPS"; service="Blast Extreme" }
                @{ port=4172;  protocol="TCP/UDP"; service="PCoIP" }
            )
        }
    }
    Write-OK "Found $($uags.Count) UAG(s)"

    # ── Desktop Pools ─────────────────────────────────────────────────────
    Write-Step "Collecting Desktop Pools..."
    $pools = Invoke-HorizonAPI -BaseUri $hvBase `
        -Endpoint "/rest/inventory/v7/desktop-pools" -Headers $hvHeaders

    foreach ($pool in $pools) {
        $environment.horizon.desktop_pools += [ordered]@{
            id               = $pool.id
            name             = $pool.name
            display_name     = $pool.display_name
            description      = $pool.description
            type             = $pool.type              # AUTOMATED, MANUAL, RDS
            source           = $pool.source            # INSTANT_CLONE, LINKED_CLONE, FULL_CLONE
            provisioning     = $pool.provisioning_type
            enabled          = $pool.enabled
            protocol_default = $pool.default_display_protocol
            vcenter_id       = $pool.vcenter_id
            cluster_id       = $pool.vc_display_name
            machine_count    = $pool.machine_count
            session_count    = $pool.num_desktops_with_sessions
        }
    }
    Write-OK "Found $($pools.Count) Desktop Pool(s)"

    # ── RDS Farms ─────────────────────────────────────────────────────────
    Write-Step "Collecting RDS Farms..."
    $farms = Invoke-HorizonAPI -BaseUri $hvBase `
        -Endpoint "/rest/inventory/v2/farms" -Headers $hvHeaders

    foreach ($farm in $farms) {
        $environment.horizon.rds_farms += [ordered]@{
            id          = $farm.id
            name        = $farm.name
            type        = $farm.type        # AUTOMATED or MANUAL
            source      = $farm.source
            enabled     = $farm.enabled
            server_count = $farm.rds_server_count
            session_count = $farm.num_sessions
        }
    }
    Write-OK "Found $($farms.Count) RDS Farm(s)"

    # ── Instant Clone Domain Admins / Composer ────────────────────────────
    Write-Step "Collecting View Composer / Instant Clone info..."
    $vcServers = Invoke-HorizonAPI -BaseUri $hvBase `
        -Endpoint "/rest/config/v2/virtual-centers" -Headers $hvHeaders

    foreach ($vcs in $vcServers) {
        # Composer is attached to vCenter in Horizon config
        if ($vcs.composer_server_address) {
            $environment.horizon.composer += [ordered]@{
                name       = "View Composer"
                address    = $vcs.composer_server_address
                port       = $vcs.composer_server_port
                vcenter    = $vcs.server_name
                version    = $vcs.composer_server_version
                ports      = @(
                    @{ port=18443; protocol="HTTPS"; service="Composer SOAP API" }
                    @{ port=443;   protocol="HTTPS"; service="Composer Admin" }
                )
            }
        }
    }
    Write-OK "Composer info collected"

    # ── App Volumes Managers ──────────────────────────────────────────────
    Write-Step "Collecting App Volumes Managers..."
    $appVolMgrs = Invoke-HorizonAPI -BaseUri $hvBase `
        -Endpoint "/rest/config/v3/app-volumes-managers" -Headers $hvHeaders

    if ($appVolMgrs) {
        foreach ($avm in $appVolMgrs) {
            $environment.horizon.app_volumes += [ordered]@{
                name    = $avm.server_address
                address = $avm.server_address
                port    = $avm.server_port
                status  = $avm.health?.status
                ports   = @(
                    @{ port=443; protocol="HTTPS"; service="App Volumes Manager" }
                )
            }
        }
        Write-OK "Found $($appVolMgrs.Count) App Volumes Manager(s)"
    }

    # ── Enrollment Servers (True SSO) ─────────────────────────────────────
    Write-Step "Checking for Enrollment Servers (True SSO)..."
    $enrollServers = Invoke-HorizonAPI -BaseUri $hvBase `
        -Endpoint "/rest/config/v2/enrollment-servers" -Headers $hvHeaders

    if ($enrollServers) {
        foreach ($es in $enrollServers) {
            $environment.horizon.enrollment_servers += [ordered]@{
                name    = $es.server_address
                address = $es.server_address
                status  = $es.status
                ports   = @(
                    @{ port=32111; protocol="TCP"; service="Enrollment Server" }
                )
            }
        }
        Write-OK "Found $($enrollServers.Count) Enrollment Server(s)"
    }
    else {
        Write-OK "No Enrollment Servers found (True SSO not configured)"
    }

    # ── Logout from Horizon ───────────────────────────────────────────────
    Invoke-RestMethod -Uri "$hvBase/rest/logout" -Method POST `
        -Headers $hvHeaders -ContentType "application/json" | Out-Null
    Write-OK "Logged out from Horizon REST API"
}
catch {
    Write-Warn "Horizon collection failed: $($_.Exception.Message)"
}

#endregion

#region ── Stage 3: NetScaler NITRO API ───────────────────────────────────────

Write-Section "Stage 3: NetScaler / Citrix ADC Collection"

if ($SkipNetScaler -or -not $NetScalerServer) {
    Write-Warn "NetScaler collection skipped (use -NetScalerServer to enable)"
}
else {
    function Invoke-NitroAPI {
        param(
            [string]$BaseUri,
            [string]$Resource,
            [hashtable]$Headers,
            [string]$Method = "GET"
        )
        try {
            $result = Invoke-RestMethod -Uri "$BaseUri/nitro/v1/config/$Resource" `
                -Method $Method -Headers $Headers
            return $result.$Resource
        }
        catch {
            Write-Warn "NITRO API call failed [$Resource]: $($_.Exception.Message)"
            return @()
        }
    }

    try {
        $nsBase    = "https://$NetScalerServer"
        $nsUser    = $nsCred.GetNetworkCredential().UserName
        $nsPass    = $nsCred.GetNetworkCredential().Password
        $nsEncoded = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$nsUser`:$nsPass"))
        $nsHeaders = @{
            Authorization  = "Basic $nsEncoded"
            "Content-Type" = "application/json"
        }

        Write-Step "Testing NetScaler connectivity..."
        $nsInfo = Invoke-RestMethod -Uri "$nsBase/nitro/v1/config/nsversion" `
            -Headers $nsHeaders
        Write-OK "Connected to NetScaler - Version: $($nsInfo.nsversion.version)"

        # ── LB vServers (VIPs) ────────────────────────────────────────────
        Write-Step "Collecting LB vServers (VIPs)..."
        $lbvServers = Invoke-NitroAPI -BaseUri $nsBase -Resource "lbvserver" -Headers $nsHeaders

        foreach ($vs in $lbvServers) {
            $environment.dmz.netscalers += [ordered]@{
                name             = $vs.name
                type             = "LB vServer"
                vip              = $vs.ipv46
                port             = [int]$vs.port
                protocol         = $vs.servicetype
                lb_method        = $vs.lbmethod
                persistence      = $vs.persistencetype
                state            = $vs.curstate
                effective_state  = $vs.effectivestate
                active_services  = [int]$vs.actsvcs
                total_services   = [int]$vs.totvsserv
                current_sessions = [int]$vs.cursrvrconnections
                comment          = $vs.comment
                services         = @()
            }
        }
        Write-OK "Found $($lbvServers.Count) LB vServer(s)"

        # ── SSL vServers ──────────────────────────────────────────────────
        Write-Step "Collecting SSL vServer bindings..."
        $sslvServers = Invoke-NitroAPI -BaseUri $nsBase -Resource "sslvserver" -Headers $nsHeaders

        foreach ($sslvs in $sslvServers) {
            $nsEntry = $environment.dmz.netscalers | Where-Object { $_.name -eq $sslvs.vservername }
            if ($nsEntry) {
                $nsEntry.ssl_protocol = $sslvs.ssl3
                $nsEntry.tls10        = $sslvs.tls1
                $nsEntry.tls11        = $sslvs.tls11
                $nsEntry.tls12        = $sslvs.tls12
                $nsEntry.tls13        = $sslvs.tls13
                $nsEntry.cipher_redirect = $sslvs.cipherredirect
            }
        }
        Write-OK "SSL vServer bindings collected"

        # ── Services (Real Servers behind VIPs) ───────────────────────────
        Write-Step "Collecting Services (real servers)..."
        $nsServices = Invoke-NitroAPI -BaseUri $nsBase -Resource "service" -Headers $nsHeaders

        foreach ($svc in $nsServices) {
            $environment.dmz.netscalers | ForEach-Object {
                # This is a simplified binding; full binding requires lbvserver_service_binding query
                $_ | Add-Member -MemberType NoteProperty -Name "_all_services" -Value @() -Force -ErrorAction SilentlyContinue
            }
        }

        # ── Service Groups ────────────────────────────────────────────────
        Write-Step "Collecting Service Groups..."
        $svcGroups = Invoke-NitroAPI -BaseUri $nsBase -Resource "servicegroup" -Headers $nsHeaders
        Write-OK "Found $($svcGroups.Count) service group(s)"

        # ── NetScaler System Info ─────────────────────────────────────────
        Write-Step "Collecting NetScaler system info..."
        $nsHW = Invoke-RestMethod -Uri "$nsBase/nitro/v1/config/nshardware" -Headers $nsHeaders
        $environment.dmz.netscalers | Add-Member -MemberType NoteProperty `
            -Name "appliance_model" -Value $nsHW.nshardware.hwdescription `
            -Force -ErrorAction SilentlyContinue

        Write-OK "NetScaler collection complete"
    }
    catch {
        Write-Warn "NetScaler collection failed: $($_.Exception.Message)"
    }
}

#endregion

#region ── Stage 4: Build Connection Edge List ────────────────────────────────

Write-Section "Stage 4: Building Connection Graph (Edge List)"
Write-Step "Mapping relationships between components..."

$connections = @()

# Clients → NetScaler
foreach ($ns in $environment.dmz.netscalers) {
    $connections += [ordered]@{
        from     = "Internet/Clients"
        to       = $ns.name
        port     = $ns.port
        protocol = $ns.protocol
        label    = "$($ns.protocol) $($ns.port)"
        tier     = "client-to-dmz"
    }
}

# NetScaler → UAGs
foreach ($ns in $environment.dmz.netscalers) {
    foreach ($uag in $environment.dmz.unified_access_gateways) {
        $connections += [ordered]@{
            from     = $ns.name
            to       = $uag.name
            port     = 8443
            protocol = "HTTPS/Blast"
            label    = "Blast 8443"
            tier     = "dmz-internal"
        }
    }
}

# UAGs → Connection Servers
foreach ($uag in $environment.dmz.unified_access_gateways) {
    foreach ($cs in $environment.horizon.connection_servers) {
        $connections += [ordered]@{
            from     = $uag.name
            to       = $cs.name
            port     = 8443
            protocol = "HTTPS"
            label    = "Blast 8443"
            tier     = "dmz-internal"
        }
    }
}

# Connection Servers → vCenter
foreach ($cs in $environment.horizon.connection_servers) {
    foreach ($vc in $environment.vcenter.server) {
        $connections += [ordered]@{
            from     = $cs.name
            to       = $vc.name
            port     = 443
            protocol = "HTTPS"
            label    = "vSphere API 443"
            tier     = "horizon-vcenter"
        }
    }
}

# Connection Servers → Composer
foreach ($cs in $environment.horizon.connection_servers) {
    foreach ($comp in $environment.horizon.composer) {
        $connections += [ordered]@{
            from     = $cs.name
            to       = $comp.address
            port     = 18443
            protocol = "HTTPS/SOAP"
            label    = "SOAP 18443"
            tier     = "horizon-internal"
        }
    }
}

# Connection Servers (cluster replication)
for ($i = 0; $i -lt $environment.horizon.connection_servers.Count - 1; $i++) {
    $connections += [ordered]@{
        from     = $environment.horizon.connection_servers[$i].name
        to       = $environment.horizon.connection_servers[$i + 1].name
        port     = 4001
        protocol = "TCP/JMS"
        label    = "JMS 4001 (Cluster)"
        tier     = "horizon-cluster"
    }
}

# ESXi → FC Switches
foreach ($hba in $environment.storage.fc_hbas) {
    $connections += [ordered]@{
        from     = $hba.host
        to       = "FC Fabric"
        port     = $null
        protocol = "Fibre Channel"
        label    = "FC $($hba.speed)Gbps"
        tier     = "compute-storage"
        wwpn     = $hba.wwpn
    }
}

$environment.connections = $connections
Write-OK "Generated $($connections.Count) connection edge(s)"

#endregion

#region ── Output ──────────────────────────────────────────────────────────────

Write-Section "Output"
Write-Step "Writing JSON to: $OutputPath"

$jsonOutput = $environment | ConvertTo-Json -Depth 10
$jsonOutput | Out-File -FilePath $OutputPath -Encoding UTF8

$fileSizeKB = [math]::Round((Get-Item $OutputPath).Length / 1KB, 1)

Write-OK "Output written: $OutputPath ($fileSizeKB KB)"

Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║              Harvest Complete! Summary                  ║" -ForegroundColor Green
Write-Host "╠══════════════════════════════════════════════════════════╣" -ForegroundColor Green
Write-Host "║  vCenter Clusters      : $($environment.vcenter.clusters.Count.ToString().PadRight(28)) ║" -ForegroundColor Green
Write-Host "║  ESXi Hosts            : $($environment.vcenter.hosts.Count.ToString().PadRight(28)) ║" -ForegroundColor Green
Write-Host "║  Datastores            : $($environment.storage.datastores.Count.ToString().PadRight(28)) ║" -ForegroundColor Green
Write-Host "║  FC HBA Ports          : $($environment.storage.fc_hbas.Count.ToString().PadRight(28)) ║" -ForegroundColor Green
Write-Host "║  Connection Servers    : $($environment.horizon.connection_servers.Count.ToString().PadRight(28)) ║" -ForegroundColor Green
Write-Host "║  UAGs                  : $($environment.dmz.unified_access_gateways.Count.ToString().PadRight(28)) ║" -ForegroundColor Green
Write-Host "║  Desktop Pools         : $($environment.horizon.desktop_pools.Count.ToString().PadRight(28)) ║" -ForegroundColor Green
Write-Host "║  NetScaler VIPs        : $($environment.dmz.netscalers.Count.ToString().PadRight(28)) ║" -ForegroundColor Green
Write-Host "║  Connection Edges      : $($environment.connections.Count.ToString().PadRight(28)) ║" -ForegroundColor Green
Write-Host "╠══════════════════════════════════════════════════════════╣" -ForegroundColor Green
Write-Host "║  JSON Output : $($OutputPath.PadRight(41)) ║" -ForegroundColor Green
Write-Host "║  Next Step   : python Generate-HorizonDiagram.py        ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════════╝`n" -ForegroundColor Green

#endregion
