# hrzn-view-diagram

**Automated VMware Horizon View architecture diagram generator.**
Scans your environment via PowerCLI, the Horizon REST API, and the NetScaler
NITRO API — then renders a layered, professional architecture diagram as PNG,
SVG, or an editable Draw.io file.

> Built by James Cruce · [ASTGL - As The Geek Learns](https://astgl.com)

---

## Project Structure

```
hrzn-view-diagram/
├── harvester/
│   ├── Invoke-HorizonHarvester.ps1              # Full scan (with NetScaler)
│   └── Invoke-HorizonHarvester-NoNetScaler.ps1  # DNS+port-probe inference variant
├── generator/
│   └── Generate-HorizonDiagram.py               # Diagram renderer
├── sample-data/
│   └── sample-environment.json                  # Test data — no live env needed
├── output/                                      # Generated diagrams (gitignored)
├── requirements.txt
└── README.md
```

---

## Quick Start

### 1 — Install Python dependencies

```bash
# macOS (Homebrew Graphviz required)
brew install graphviz
pip install -r requirements.txt
```

### 2 — Install PowerCLI (Windows / PowerShell 7)

```powershell
Install-Module -Name VMware.PowerCLI -Scope CurrentUser -AllowClobber
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false
```

### 3 — Run the Harvester

**With NetScaler credentials:**
```powershell
.\harvester\Invoke-HorizonHarvester.ps1 `
    -vCenterServer vcenter.example.org `
    -HorizonServer horizon-cs01.example.org `
    -NetScalerServer netscaler-mgmt.example.org `
    -OutputPath .\horizon-environment.json
```

**Without NetScaler credentials (uses DNS + TCP probing):**
```powershell
.\harvester\Invoke-HorizonHarvester-NoNetScaler.ps1 `
    -vCenterServer vcenter.example.org `
    -HorizonServer horizon-cs01.example.org `
    -HorizonExternalURL vdi.example.org `
    -OutputPath .\horizon-environment.json
```

### 4 — Generate the Diagram

```bash
# PNG + editable Draw.io file
python generator/Generate-HorizonDiagram.py \
    --input horizon-environment.json \
    --format png \
    --drawio

# SVG (vector — best for documentation)
python generator/Generate-HorizonDiagram.py \
    --input horizon-environment.json \
    --format svg

# Clean version without port labels (exec presentations)
python generator/Generate-HorizonDiagram.py \
    --input horizon-environment.json \
    --no-port-labels

# Test with sample data (no live environment needed)
python generator/Generate-HorizonDiagram.py \
    --input sample-data/sample-environment.json \
    --drawio
```

---

## Diagram Layers

| Layer | Components |
|-------|-----------|
| Clients / Internet | Thin clients, browsers, Horizon Client |
| DMZ | NetScaler VIPs, UAGs (Unified Access Gateways) |
| Horizon Internal | Connection Servers, Composer, App Volumes, Desktop Pools |
| vSphere Platform | vCenter, Distributed Virtual Switches |
| Compute | vSphere Clusters (optionally with individual ESXi hosts) |
| Storage | FC Switches (Fabric A/B), All-Flash Arrays, Datastores |

---

## NetScaler Variants

| Variant | NetScaler Data | Method |
|---------|---------------|--------|
| `Invoke-HorizonHarvester.ps1` | Full — VIPs, LB method, persistence, cipher suites, HA pair | NITRO REST API |
| `Invoke-HorizonHarvester-NoNetScaler.ps1` | Inferred — VIP FQDN/IP, open ports, SSL cert | DNS + TCP probe + TLS handshake |

**What's missing without NetScaler credentials:**
- Load balancing algorithm (round-robin, least-connections, etc.)
- Persistence type (source IP, cookie, etc.)
- TLS cipher suites and policy names
- SSL offload vs. passthrough configuration
- Content switching policies
- Health monitor configuration
- HA pair nodes (primary/secondary appliances)
- Appliance model and firmware version

**What's inferred without credentials:**
- VIP FQDN (from Horizon Connection Server `external_url` property)
- VIP IP address (DNS resolution)
- Open ports (TCP `Test-NetConnection` probe)
- SSL certificate subject, issuer, SAN, and expiry date

---

## Generator Options

```
--input FILE          Path to JSON from harvester (required)
--output STEM         Output filename stem (no extension)
--format FORMAT       png | svg | pdf  (default: png)
--drawio              Also generate a Draw.io editable XML file
--show-hosts          Show individual ESXi hosts inside cluster boxes
--no-port-labels      Hide port/protocol labels on edges (cleaner for presentations)
--summary-only        Print environment summary without generating diagram
```

---

## Scheduling as a Living Document

```powershell
# Weekly automated re-harvest (Sunday 2AM) — keeps diagram current
$action = New-ScheduledTaskAction `
    -Execute "pwsh.exe" `
    -Argument "-NonInteractive -File $PWD\harvester\Invoke-HorizonHarvester-NoNetScaler.ps1 ..."

$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 2am

Register-ScheduledTask -TaskName "Horizon Diagram Harvester" `
    -Action $action -Trigger $trigger -RunLevel Highest
```

---

## Environment

- **PowerShell**: 5.1+ or 7+
- **VMware PowerCLI**: 13.0+
- **Horizon**: 7.8+ (REST API required)
- **Python**: 3.8+
- **Graphviz**: System binary required (see Quick Start)

---

## License

MIT — use freely, attribution appreciated.
