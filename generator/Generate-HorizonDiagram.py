#!/usr/bin/env python3
"""
Generate-HorizonDiagram.py
VMware Horizon View Architecture Diagram Generator

Reads the JSON output from Invoke-HorizonHarvester.ps1 and generates
a professional, layered architecture diagram using the `diagrams` library.

Usage:
    python Generate-HorizonDiagram.py --input horizon-environment.json
    python Generate-HorizonDiagram.py --input horizon-environment.json --format svg
    python Generate-HorizonDiagram.py --input horizon-environment.json --format png --dpi 300
    python Generate-HorizonDiagram.py --input horizon-environment.json --drawio

Requirements:
    pip install diagrams graphviz
    # Also requires Graphviz system binary: https://graphviz.org/download/

Author  : ASTGL - As The Geek Learns (astgl.com)
Version : 1.0.0
"""

import json
import argparse
import sys
import os
from pathlib import Path
from datetime import datetime

# ── Dependency Check ──────────────────────────────────────────────────────────
try:
    from diagrams import Diagram, Cluster, Edge
    from diagrams.onprem.network import Nginx, HAProxy, CiscoSwitchL2, CiscoSwitchL3, CiscoRouter
    from diagrams.onprem.compute import Server
    from diagrams.generic.network import Switch, Firewall, Router
    from diagrams.generic.storage import Storage
    from diagrams.generic.compute import Rack

    # Alias to VMware-semantic names for readability throughout the script
    ESXi        = Server
    VCenter     = Server
    ResourcePool = Rack
    NSXManager  = CiscoSwitchL3
    Datastore   = Storage
    SAN         = Storage
    Windows     = Server
except ImportError:
    print("\n[ERROR] The 'diagrams' library is not installed.")
    print("Install it with: pip install diagrams")
    print("You also need Graphviz: https://graphviz.org/download/\n")
    sys.exit(1)


# ══════════════════════════════════════════════════════════════════════════════
# ── Style Definitions ─────────────────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════════════

# Edge styles per tier
EDGE_STYLES = {
    "client-to-dmz":    {"color": "#FF6B35", "style": "bold",   "label_color": "#FF6B35"},
    "dmz-internal":     {"color": "#F7C59F", "style": "bold",   "label_color": "#F7C59F"},
    "horizon-cluster":  {"color": "#4ECDC4", "style": "dashed", "label_color": "#4ECDC4"},
    "horizon-vcenter":  {"color": "#45B7D1", "style": "bold",   "label_color": "#45B7D1"},
    "horizon-internal": {"color": "#96CEB4", "style": "solid",  "label_color": "#96CEB4"},
    "vcenter-compute":  {"color": "#88D8B0", "style": "bold",   "label_color": "#88D8B0"},
    "compute-storage":  {"color": "#FF8C94", "style": "bold",   "label_color": "#FF8C94"},
    "fabric-array":     {"color": "#FF4757", "style": "bold",   "label_color": "#FF4757"},
    "default":          {"color": "#AAAAAA", "style": "solid",  "label_color": "#AAAAAA"},
}

# Graphviz graph attributes for the overall diagram
GRAPH_ATTRS = {
    "fontsize":    "14",
    "fontname":    "Helvetica Neue",
    "bgcolor":     "#1A1A2E",      # Dark navy background
    "pad":         "0.75",
    "splines":     "ortho",        # Right-angle routing (cleaner for network diagrams)
    "nodesep":     "0.6",
    "ranksep":     "1.2",
    "concentrate": "false",
    "fontcolor":   "#E0E0E0",
    "labelloc":    "t",
    "labeljust":   "c",
}

NODE_ATTRS = {
    "fontsize":  "11",
    "fontname":  "Helvetica Neue",
    "fontcolor": "#FFFFFF",
    "shape":     "box",
    "style":     "filled,rounded",
    "fillcolor": "#16213E",
    "color":     "#0F3460",
}

EDGE_ATTRS = {
    "fontsize":  "9",
    "fontname":  "Helvetica Neue",
    "fontcolor": "#CCCCCC",
    "color":     "#555555",
    "penwidth":  "1.5",
    "arrowsize": "0.8",
}


# ══════════════════════════════════════════════════════════════════════════════
# ── Helpers ───────────────────────────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════════════

def load_environment(json_path: str) -> dict:
    """Load and validate the harvested environment JSON."""
    path = Path(json_path)
    if not path.exists():
        print(f"\n[ERROR] Input file not found: {json_path}")
        print("Run Invoke-HorizonHarvester.ps1 first, or use --input sample-environment.json\n")
        sys.exit(1)

    with open(path, encoding="utf-8") as f:
        data = json.load(f)

    required = ["metadata", "dmz", "horizon", "vcenter", "storage", "connections"]
    for key in required:
        if key not in data:
            print(f"[ERROR] Missing required key '{key}' in JSON. Was this produced by the harvester?")
            sys.exit(1)

    return data


def get_edge(tier: str, label: str = "", show_label: bool = True) -> Edge:
    """Return a styled Edge object for a given connection tier."""
    style = EDGE_STYLES.get(tier, EDGE_STYLES["default"])
    edge_label = label if show_label else ""
    return Edge(
        color=style["color"],
        style=style["style"],
        label=edge_label,
        fontcolor=style["label_color"],
        fontsize="9",
        penwidth="2.0" if style["style"] == "bold" else "1.5",
    )


def truncate(text: str, max_len: int = 22) -> str:
    """Truncate long names for cleaner diagram nodes."""
    return text if len(text) <= max_len else text[:max_len - 1] + "…"


def node_label(name: str, extra: str = "") -> str:
    """Format a node label with optional subtitle."""
    label = truncate(name)
    if extra:
        label += f"\n{extra}"
    return label


def print_banner():
    print("\n" + "═" * 60)
    print("  Horizon View Diagram Generator v1.0")
    print("  ASTGL - As The Geek Learns  |  astgl.com")
    print("═" * 60)


def print_step(msg: str):
    print(f"  ► {msg}")


def print_ok(msg: str):
    print(f"  ✔ {msg}")


# ══════════════════════════════════════════════════════════════════════════════
# ── Main Diagram Builder ──────────────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════════════

def build_diagram(env: dict, output_path: str, output_format: str,
                  show_port_labels: bool, show_hosts: bool):
    """
    Build the layered Horizon architecture diagram.

    Layer stack (top → bottom in diagram):
      1. Clients / Internet
      2. DMZ  (NetScaler VIPs, UAGs, Firewall)
      3. Horizon Internal  (Connection Servers, Composer, App Volumes)
      4. vCenter / vSphere Management
      5. Compute  (Clusters with optional host detail)
      6. Storage  (FC Switches, Arrays, Datastores)
    """

    meta     = env.get("metadata", {})
    env_name = meta.get("environment_name", "VMware Horizon View Environment")
    gen_date = meta.get("generated_at", datetime.now().isoformat())[:10]

    diagram_title = f"{env_name}\nGenerated: {gen_date} | ASTGL.com"
    filename      = Path(output_path).stem  # diagrams adds the extension

    print_step(f"Building diagram: {output_path}.{output_format}")

    with Diagram(
        diagram_title,
        filename=filename,
        outformat=output_format,
        direction="TB",
        graph_attr=GRAPH_ATTRS,
        node_attr=NODE_ATTRS,
        edge_attr=EDGE_ATTRS,
        show=False,
    ):

        # ── Layer 0: Clients / Internet ───────────────────────────────────
        print_step("  Adding: Client layer")
        with Cluster("Clients / Internet",
                      graph_attr={"bgcolor": "#0D1B2A", "style": "rounded",
                                  "fontcolor": "#FF6B35", "pencolor": "#FF6B35"}):
            thin_client  = Router(node_label("Thin Client", "Blast / PCoIP"))
            browser      = Windows(node_label("HTML Access", "Browser (443)"))
            fat_client   = Windows(node_label("Horizon Client", "Windows / Mac"))

        # ── Layer 1: DMZ ──────────────────────────────────────────────────
        print_step("  Adding: DMZ layer")
        dmz_data   = env.get("dmz", {})
        ns_data    = dmz_data.get("netscalers", [])
        uag_data   = dmz_data.get("unified_access_gateways", [])
        fw_data    = dmz_data.get("firewalls", [])

        ns_nodes   = {}
        uag_nodes  = {}
        fw_nodes   = {}

        with Cluster("DMZ",
                      graph_attr={"bgcolor": "#1A0A0A", "style": "rounded",
                                  "fontcolor": "#FF6B35", "pencolor": "#FF6B35"}):

            if fw_data:
                with Cluster("Perimeter Firewalls",
                              graph_attr={"bgcolor": "#200A0A"}):
                    for fw in fw_data:
                        fw_nodes[fw["name"]] = Firewall(node_label(fw["name"]))

            if ns_data:
                with Cluster("NetScaler / ADC (Load Balancers)",
                              graph_attr={"bgcolor": "#1F1010",
                                          "fontcolor": "#FF8C00", "pencolor": "#FF8C00"}):
                    for ns in ns_data:
                        vip  = ns.get("vip", "")
                        port = ns.get("port", "")
                        proto = ns.get("protocol", "")
                        lbl  = node_label(ns["name"], f"{vip}:{port} ({proto})")
                        ns_nodes[ns["name"]] = Nginx(lbl)

            if uag_data:
                with Cluster("Unified Access Gateways (UAG)",
                              graph_attr={"bgcolor": "#1F1010",
                                          "fontcolor": "#FFA500", "pencolor": "#FFA500"}):
                    for uag in uag_data:
                        sessions = uag.get("active_sessions", 0)
                        lbl = node_label(uag["name"],
                                         f"{uag.get('address','')}\n{sessions} sessions")
                        uag_nodes[uag["name"]] = NSXManager(lbl)

        # ── Layer 2: Horizon Internal ─────────────────────────────────────
        print_step("  Adding: Horizon Connection Server layer")
        horizon_data = env.get("horizon", {})
        cs_data      = horizon_data.get("connection_servers", [])
        comp_data    = horizon_data.get("composer", [])
        av_data      = horizon_data.get("app_volumes", [])
        enroll_data  = horizon_data.get("enrollment_servers", [])
        pool_data    = horizon_data.get("desktop_pools", [])

        cs_nodes     = {}
        comp_nodes   = {}
        av_nodes     = {}

        with Cluster("Horizon Internal",
                      graph_attr={"bgcolor": "#0A1A0A", "style": "rounded",
                                  "fontcolor": "#4ECDC4", "pencolor": "#4ECDC4"}):

            with Cluster("Connection Servers (HA Cluster)",
                          graph_attr={"bgcolor": "#0D1F0D",
                                      "fontcolor": "#4ECDC4", "pencolor": "#4ECDC4"}):
                for cs in cs_data:
                    version = cs.get("version", "")
                    status  = cs.get("status", "")
                    lbl     = node_label(cs["name"],
                                         f"v{version} | {status}")
                    cs_nodes[cs["name"]] = Switch(lbl)

            side_nodes_present = comp_data or av_data or enroll_data
            if side_nodes_present:
                with Cluster("Supporting Services",
                              graph_attr={"bgcolor": "#0D1F0D"}):

                    for comp in comp_data:
                        lbl = node_label("Composer", comp.get("address", ""))
                        comp_nodes[comp.get("address", "composer")] = Rack(lbl)

                    for av in av_data:
                        lbl = node_label("App Volumes", av.get("address", ""))
                        av_nodes[av.get("address", "appvol")] = Rack(lbl)

                    for es in enroll_data:
                        lbl = node_label("Enrollment Server", es.get("address", ""))
                        Rack(lbl)  # True SSO

            # Desktop Pool summary nodes
            if pool_data:
                with Cluster("Desktop Pools",
                              graph_attr={"bgcolor": "#0D1F0D",
                                          "fontcolor": "#96CEB4", "pencolor": "#96CEB4"}):
                    pool_nodes = []
                    for pool in pool_data[:8]:  # Cap at 8 for readability
                        machines = pool.get("machine_count", 0)
                        sessions = pool.get("session_count", 0)
                        src      = pool.get("source", "").replace("_", " ")
                        lbl      = node_label(pool["name"],
                                              f"{machines} VMs | {sessions} sessions\n{src}")
                        pool_nodes.append(ResourcePool(lbl))

        # ── Layer 3: vCenter ──────────────────────────────────────────────
        print_step("  Adding: vCenter layer")
        vc_data      = env.get("vcenter", {})
        vc_servers   = vc_data.get("server", [])
        dvs_data     = env.get("networking", {}).get("distributed_switches", [])

        vc_nodes     = {}

        with Cluster("vSphere Platform",
                      graph_attr={"bgcolor": "#0A0A1A", "style": "rounded",
                                  "fontcolor": "#45B7D1", "pencolor": "#45B7D1"}):

            for vc in vc_servers:
                lbl = node_label(vc["name"], f"v{vc.get('version','')}")
                vc_nodes[vc["name"]] = VCenter(lbl)

            if dvs_data:
                with Cluster("Distributed Virtual Switches",
                              graph_attr={"bgcolor": "#0D0D1F"}):
                    for dvs in dvs_data[:3]:  # Cap display
                        pg_count = len(dvs.get("port_groups", []))
                        lbl = node_label(dvs["name"],
                                         f"MTU:{dvs.get('mtu',1500)} | {pg_count} PGs")
                        Switch(lbl)

        # ── Layer 4: Compute ──────────────────────────────────────────────
        print_step("  Adding: Compute layer")
        cluster_data = vc_data.get("clusters", [])
        host_data    = vc_data.get("hosts", [])
        pool_data2   = horizon_data.get("desktop_pools", [])

        cluster_nodes = {}

        with Cluster("Compute (vSphere Clusters)",
                      graph_attr={"bgcolor": "#0A1A10", "style": "rounded",
                                  "fontcolor": "#88D8B0", "pencolor": "#88D8B0"}):

            for cluster in cluster_data:
                host_count  = cluster.get("host_count", 0)
                total_mem   = cluster.get("total_memory_gb", 0)
                total_cpu   = cluster.get("total_cpu_ghz", 0)
                ha          = "HA+DRS" if cluster.get("ha_enabled") else "No HA"

                cluster_lbl = (f"{cluster['name']}\n"
                               f"{host_count} Hosts | {total_mem}GB RAM\n"
                               f"{total_cpu}GHz | {ha}")

                with Cluster(cluster["name"],
                              graph_attr={"bgcolor": "#0D1F12",
                                          "fontcolor": "#88D8B0", "pencolor": "#88D8B0"}):
                    cluster_node = Rack(cluster_lbl)
                    cluster_nodes[cluster["name"]] = cluster_node

                    # Show individual hosts only if requested and count is manageable
                    if show_hosts:
                        host_list = [h for h in host_data
                                     if h.get("cluster") == cluster["name"]]
                        display_hosts = host_list[:6]  # Cap at 6 for readability
                        for host in display_hosts:
                            mem = host.get("memory_gb", 0)
                            model = host.get("model", "")
                            esxi_v = host.get("esxi_version", "")
                            h_lbl = node_label(host["name"].split(".")[0],
                                               f"{model}\n{mem}GB | ESXi {esxi_v}")
                            ESXi(h_lbl)

                        if len(host_list) > 6:
                            ESXi(f"+ {len(host_list)-6} more hosts…")

        # ── Layer 5: Storage ──────────────────────────────────────────────
        print_step("  Adding: Storage layer")
        storage_data  = env.get("storage", {})
        ds_data       = storage_data.get("datastores", [])
        fc_sw_data    = storage_data.get("fc_switches", [])
        array_data    = storage_data.get("arrays", [])
        fc_hba_data   = storage_data.get("fc_hbas", [])

        fc_sw_nodes   = {}
        array_nodes   = {}

        with Cluster("Storage",
                      graph_attr={"bgcolor": "#1A0A0A", "style": "rounded",
                                  "fontcolor": "#FF8C94", "pencolor": "#FF8C94"}):

            # FC Fabric
            if fc_sw_data:
                with Cluster("Fibre Channel Fabric",
                              graph_attr={"bgcolor": "#1F0D0D",
                                          "fontcolor": "#FF4757", "pencolor": "#FF4757"}):
                    for sw in fc_sw_data:
                        lbl = node_label(sw["name"],
                                         f"{sw.get('vendor','')} {sw.get('model','')}\n"
                                         f"{sw.get('ports',0)} ports | {sw.get('speed','')}")
                        fc_sw_nodes[sw["name"]] = Switch(lbl)

            # Storage Arrays
            if array_data:
                with Cluster("All-Flash Arrays",
                              graph_attr={"bgcolor": "#1F0D0D",
                                          "fontcolor": "#FF6B6B", "pencolor": "#FF6B6B"}):
                    for arr in array_data:
                        used_pct = arr.get("used_pct", 0)
                        lbl = node_label(arr["name"],
                                         f"{arr.get('vendor','')} {arr.get('model','')}\n"
                                         f"{arr.get('usable_tb',0)}TB usable | {used_pct}% used")
                        array_nodes[arr["name"]] = SAN(lbl)

            # Datastores (summary)
            if ds_data:
                with Cluster("Datastores",
                              graph_attr={"bgcolor": "#1F0D0D"}):
                    for ds in ds_data[:6]:  # Cap for readability
                        used = ds.get("used_pct", 0)
                        cap  = ds.get("capacity_gb", 0)
                        lbl  = node_label(ds["name"],
                                          f"{ds.get('type','')} | {cap}GB\n{used}% used")
                        Datastore(lbl)

            # HBA Summary (if no FC switches defined, show HBA count)
            if fc_hba_data and not fc_sw_data:
                hba_hosts = list(set(h["host"] for h in fc_hba_data))
                fc_sw_nodes["FC-Fabric"] = Switch(
                    f"FC Fabric\n{len(fc_hba_data)} HBA ports\n{len(hba_hosts)} hosts"
                )

        # ── Draw Connections from Edge List ───────────────────────────────
        print_step("  Drawing connection edges...")

        # Build a lookup: name → node object
        all_nodes = {}
        all_nodes.update(ns_nodes)
        all_nodes.update(uag_nodes)
        all_nodes.update(fw_nodes)
        all_nodes.update(cs_nodes)
        all_nodes.update(comp_nodes)
        all_nodes.update(av_nodes)
        all_nodes.update(vc_nodes)
        all_nodes.update(cluster_nodes)
        all_nodes.update(fc_sw_nodes)
        all_nodes.update(array_nodes)

        # Canonical client node (merge all client types)
        # Clients → NetScalers: connect fat_client as representative
        client_nodes = [thin_client, browser, fat_client]

        connections = env.get("connections", [])
        drawn = 0
        skipped = 0

        for conn in connections:
            from_name = conn.get("from", "")
            to_name   = conn.get("to", "")
            tier      = conn.get("tier", "default")
            label     = conn.get("label", "") if show_port_labels else ""

            # Handle special "Internet/Clients" source
            if from_name == "Internet/Clients":
                to_node = all_nodes.get(to_name)
                if to_node:
                    edge = get_edge(tier, label, show_port_labels)
                    for cn in client_nodes:
                        cn >> edge >> to_node
                    drawn += 1
                continue

            from_node = all_nodes.get(from_name)
            to_node   = all_nodes.get(to_name)

            if from_node and to_node:
                edge = get_edge(tier, label, show_port_labels)
                from_node >> edge >> to_node
                drawn += 1
            else:
                # Try partial match for FQDNs
                from_match = next((v for k, v in all_nodes.items()
                                   if from_name in k or k in from_name), None)
                to_match   = next((v for k, v in all_nodes.items()
                                   if to_name in k or k in to_name), None)
                if from_match and to_match:
                    edge = get_edge(tier, label, show_port_labels)
                    from_match >> edge >> to_match
                    drawn += 1
                else:
                    skipped += 1

        print_ok(f"  Drew {drawn} edges ({skipped} skipped — nodes not in diagram scope)")

    print_ok(f"Diagram written: {filename}.{output_format}")


# ══════════════════════════════════════════════════════════════════════════════
# ── Draw.io XML Export (Bonus) ────────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════════════

def build_drawio_xml(env: dict, output_path: str):
    """
    Generate a Draw.io compatible XML file from the environment JSON.
    This produces an editable diagram that can be opened in app.diagrams.net
    or the Draw.io desktop app.
    """

    meta      = env.get("metadata", {})
    env_name  = meta.get("environment_name", "Horizon View")
    gen_date  = meta.get("generated_at", "")[:10]

    # Tier layout: y-coordinate bands
    TIER_Y = {
        "client":   80,
        "dmz":      280,
        "horizon":  480,
        "vcenter":  680,
        "compute":  880,
        "storage":  1100,
    }

    TIER_COLORS = {
        "client":   "#FF6B35",
        "dmz":      "#FF8C00",
        "horizon":  "#4ECDC4",
        "vcenter":  "#45B7D1",
        "compute":  "#88D8B0",
        "storage":  "#FF8C94",
    }

    cells = []
    id_counter = [10]  # mutable counter

    def next_id():
        id_counter[0] += 1
        return str(id_counter[0])

    def add_node(label, x, y, width=160, height=60,
                 style="", tooltip="", cell_id=None):
        nid = cell_id or next_id()
        default_style = (
            "rounded=1;whiteSpace=wrap;html=1;"
            "fillColor=#1A1A2E;strokeColor=#4ECDC4;"
            "fontColor=#FFFFFF;fontSize=10;fontFamily=Helvetica;"
        )
        cells.append(f"""    <mxCell id="{nid}" value="{label}" style="{style or default_style}" """
                     f"""vertex="1" parent="1" tooltip="{tooltip}">
      <mxGeometry x="{x}" y="{y}" width="{width}" height="{height}" as="geometry" />
    </mxCell>""")
        return nid

    def add_group(label, x, y, width, height, color="#333333", cell_id=None):
        gid = cell_id or next_id()
        style = (
            f"swimlane;startSize=30;fillColor={color}22;"
            f"strokeColor={color};fontColor={color};"
            f"fontSize=11;fontStyle=1;fontFamily=Helvetica;"
        )
        cells.append(f"""    <mxCell id="{gid}" value="{label}" style="{style}" """
                     f"""vertex="1" parent="1">
      <mxGeometry x="{x}" y="{y}" width="{width}" height="{height}" as="geometry" />
    </mxCell>""")
        return gid

    def add_edge(src_id, tgt_id, label="", color="#AAAAAA"):
        eid = next_id()
        style = (
            f"edgeStyle=orthogonalEdgeStyle;rounded=1;"
            f"exitX=0.5;exitY=1;entryX=0.5;entryY=0;"
            f"strokeColor={color};strokeWidth=2;"
            f"fontColor={color};fontSize=9;fontFamily=Helvetica;"
        )
        cells.append(f"""    <mxCell id="{eid}" value="{label}" style="{style}" """
                     f"""edge="1" source="{src_id}" target="{tgt_id}" parent="1">
      <mxGeometry relative="1" as="geometry" />
    </mxCell>""")

    # ── Build Nodes ───────────────────────────────────────────────────────

    node_ids = {}   # name → cell_id

    # Title node
    add_node(f"{env_name}&#xa;Generated: {gen_date}",
             x=20, y=10, width=960, height=40,
             style=(
                 "text;html=1;strokeColor=none;fillColor=#1A1A2E;"
                 "align=center;verticalAlign=middle;whiteSpace=wrap;"
                 "fontSize=14;fontStyle=1;fontColor=#4ECDC4;"
             ))

    # Clients
    grp_client = add_group("Clients / Internet", 20, TIER_Y["client"]-10,
                            960, 140, TIER_COLORS["client"])
    for i, label in enumerate(["Thin Client\n(Blast/PCoIP)", "Browser\n(HTML Access 443)",
                                "Horizon Client\n(Windows/Mac)"]):
        nid = add_node(label.replace("\n", "&#xa;"), x=80 + i*300, y=TIER_Y["client"]+50,
                       width=150, height=60,
                       style=("rounded=1;whiteSpace=wrap;html=1;fillColor=#FF6B3522;"
                              "strokeColor=#FF6B35;fontColor=#FF6B35;fontSize=10;"))
        node_ids[f"client-{i}"] = nid

    # DMZ — NetScalers
    grp_dmz = add_group("DMZ", 20, TIER_Y["dmz"]-10, 960, 170, TIER_COLORS["dmz"])
    dmz_data = env.get("dmz", {})
    x_offset = 60
    for ns in dmz_data.get("netscalers", []):
        tooltip = f"VIP: {ns.get('vip','')}  Port: {ns.get('port','')}  Proto: {ns.get('protocol','')}"
        nid = add_node(
            f"{ns['name']}&#xa;{ns.get('vip','')}:{ns.get('port','')}",
            x=x_offset, y=TIER_Y["dmz"]+50, width=160, height=70,
            style=("rounded=1;whiteSpace=wrap;html=1;fillColor=#FF8C0022;"
                   "strokeColor=#FF8C00;fontColor=#FFFFFF;fontSize=10;"),
            tooltip=tooltip,
        )
        node_ids[ns["name"]] = nid
        x_offset += 200

    # UAGs
    x_offset = 60
    for uag in dmz_data.get("unified_access_gateways", []):
        tooltip = (f"Address: {uag.get('address','')}  "
                   f"Version: {uag.get('version','')}  "
                   f"Sessions: {uag.get('active_sessions',0)}")
        nid = add_node(
            f"{uag['name']}&#xa;{uag.get('address','')}&#xa;{uag.get('active_sessions',0)} sessions",
            x=x_offset + 500, y=TIER_Y["dmz"]+50, width=160, height=80,
            style=("rounded=1;whiteSpace=wrap;html=1;fillColor=#FFA50022;"
                   "strokeColor=#FFA500;fontColor=#FFFFFF;fontSize=10;"),
            tooltip=tooltip,
        )
        node_ids[uag["name"]] = nid
        x_offset += 180

    # Horizon Connection Servers
    grp_horizon = add_group("Horizon Connection Servers", 20, TIER_Y["horizon"]-10,
                             960, 160, TIER_COLORS["horizon"])
    x_offset = 60
    for cs in env.get("horizon", {}).get("connection_servers", []):
        tooltip = (f"FQDN: {cs.get('fqdn','')}  Version: {cs.get('version','')}  "
                   f"Status: {cs.get('status','')}  Blast: {cs.get('blast_enabled',False)}")
        port_list = ", ".join([str(p["port"]) for p in cs.get("ports", [])])
        nid = add_node(
            f"{cs['name']}&#xa;v{cs.get('version','')} | {cs.get('status','')}&#xa;Ports: {port_list}",
            x=x_offset, y=TIER_Y["horizon"]+50, width=200, height=80,
            style=("rounded=1;whiteSpace=wrap;html=1;fillColor=#4ECDC422;"
                   "strokeColor=#4ECDC4;fontColor=#FFFFFF;fontSize=9;"),
            tooltip=tooltip,
        )
        node_ids[cs["name"]] = nid
        x_offset += 230

    # Composer / App Volumes
    for comp in env.get("horizon", {}).get("composer", []):
        nid = add_node(
            f"View Composer&#xa;{comp.get('address','')}&#xa;Port: {comp.get('port',18443)}",
            x=740, y=TIER_Y["horizon"]+50, width=170, height=70,
            style=("rounded=1;whiteSpace=wrap;html=1;fillColor=#96CEB422;"
                   "strokeColor=#96CEB4;fontColor=#FFFFFF;fontSize=9;"),
        )
        node_ids[comp.get("address", "composer")] = nid

    # vCenter
    grp_vc = add_group("vSphere Platform", 20, TIER_Y["vcenter"]-10,
                        960, 130, TIER_COLORS["vcenter"])
    x_offset = 60
    for vc in env.get("vcenter", {}).get("server", []):
        nid = add_node(
            f"vCenter&#xa;{vc['name']}&#xa;v{vc.get('version','')}",
            x=x_offset, y=TIER_Y["vcenter"]+40, width=200, height=70,
            style=("rounded=1;whiteSpace=wrap;html=1;fillColor=#45B7D122;"
                   "strokeColor=#45B7D1;fontColor=#FFFFFF;fontSize=10;"),
        )
        node_ids[vc["name"]] = nid
        x_offset += 250

    # Clusters
    grp_compute = add_group("Compute (vSphere Clusters)", 20, TIER_Y["compute"]-10,
                             960, 150, TIER_COLORS["compute"])
    x_offset = 60
    for cluster in env.get("vcenter", {}).get("clusters", []):
        ha     = "HA+DRS" if cluster.get("ha_enabled") else "No HA"
        tooltip = (f"Hosts: {cluster.get('host_count',0)}  "
                   f"RAM: {cluster.get('total_memory_gb',0)}GB  "
                   f"CPU: {cluster.get('total_cpu_ghz',0)}GHz")
        nid = add_node(
            f"{cluster['name']}&#xa;{cluster.get('host_count',0)} hosts | "
            f"{cluster.get('total_memory_gb',0)}GB&#xa;{ha}",
            x=x_offset, y=TIER_Y["compute"]+45, width=200, height=80,
            style=("rounded=1;whiteSpace=wrap;html=1;fillColor=#88D8B022;"
                   "strokeColor=#88D8B0;fontColor=#FFFFFF;fontSize=9;"),
            tooltip=tooltip,
        )
        node_ids[cluster["name"]] = nid
        x_offset += 250

    # FC Switches
    grp_storage = add_group("Storage", 20, TIER_Y["storage"]-10,
                             960, 170, TIER_COLORS["storage"])
    x_offset = 60
    storage = env.get("storage", {})
    for sw in storage.get("fc_switches", []):
        nid = add_node(
            f"FC Switch&#xa;{sw['name']}&#xa;{sw.get('vendor','')} {sw.get('model','')}&#xa;"
            f"{sw.get('ports',0)} ports | {sw.get('speed','')}",
            x=x_offset, y=TIER_Y["storage"]+50, width=170, height=90,
            style=("rounded=1;whiteSpace=wrap;html=1;fillColor=#FF475722;"
                   "strokeColor=#FF4757;fontColor=#FFFFFF;fontSize=9;"),
        )
        node_ids[sw["name"]] = nid
        x_offset += 200

    # Arrays
    for arr in storage.get("arrays", []):
        nid = add_node(
            f"All-Flash Array&#xa;{arr['name']}&#xa;{arr.get('vendor','')} {arr.get('model','')}&#xa;"
            f"{arr.get('usable_tb',0)}TB | {arr.get('used_pct',0)}% used",
            x=x_offset, y=TIER_Y["storage"]+50, width=200, height=90,
            style=("rounded=1;whiteSpace=wrap;html=1;fillColor=#FF6B6B22;"
                   "strokeColor=#FF6B6B;fontColor=#FFFFFF;fontSize=9;"),
        )
        node_ids[arr["name"]] = nid
        x_offset += 250

    # ── Draw Edges ────────────────────────────────────────────────────────
    tier_edge_colors = {
        "client-to-dmz":    "#FF6B35",
        "dmz-internal":     "#F7C59F",
        "horizon-cluster":  "#4ECDC4",
        "horizon-vcenter":  "#45B7D1",
        "horizon-internal": "#96CEB4",
        "vcenter-compute":  "#88D8B0",
        "compute-storage":  "#FF8C94",
        "fabric-array":     "#FF4757",
        "default":          "#AAAAAA",
    }

    for conn in env.get("connections", []):
        from_name = conn.get("from", "")
        to_name   = conn.get("to", "")
        tier      = conn.get("tier", "default")
        label     = conn.get("label", "")
        color     = tier_edge_colors.get(tier, "#AAAAAA")

        # Clients → first NS node
        if from_name == "Internet/Clients":
            for cid in list(node_ids.values())[:3]:  # client nodes
                for ns_key in dmz_data.get("netscalers", [])[:1]:
                    tgt = node_ids.get(ns_key["name"])
                    if tgt:
                        add_edge(cid, tgt, label, color)
            continue

        src_id = node_ids.get(from_name)
        tgt_id = node_ids.get(to_name)

        # Fuzzy match
        if not src_id:
            src_id = next((v for k, v in node_ids.items()
                           if from_name in k or k in from_name), None)
        if not tgt_id:
            tgt_id = next((v for k, v in node_ids.items()
                           if to_name in k or k in to_name), None)

        if src_id and tgt_id:
            add_edge(src_id, tgt_id, label, color)

    # ── Write XML ─────────────────────────────────────────────────────────
    xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<mxfile host="ASTGL Horizon Harvester" version="21.6.5">
  <diagram name="{env_name}" id="horizon-diagram">
    <mxGraphModel dx="1422" dy="762" grid="1" gridSize="10" guides="1"
                  tooltips="1" connect="1" arrows="1" fold="1"
                  page="0" pageScale="1" pageWidth="1400" pageHeight="1600"
                  math="0" shadow="1" background="#1A1A2E">
      <root>
        <mxCell id="0" />
        <mxCell id="1" parent="0" />
{chr(10).join(cells)}
      </root>
    </mxGraphModel>
  </diagram>
</mxfile>"""

    with open(output_path, "w", encoding="utf-8") as f:
        f.write(xml)

    print_ok(f"Draw.io XML written: {output_path}")
    print("  ► Open in https://app.diagrams.net or Draw.io Desktop to view and edit")


# ══════════════════════════════════════════════════════════════════════════════
# ── Summary Report ────────────────────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════════════

def print_environment_summary(env: dict):
    """Print a quick human-readable summary of what was found."""
    meta    = env.get("metadata", {})
    dmz     = env.get("dmz", {})
    horizon = env.get("horizon", {})
    vcenter = env.get("vcenter", {})
    storage = env.get("storage", {})
    conns   = env.get("connections", [])

    total_machines = sum(p.get("machine_count", 0)
                         for p in horizon.get("desktop_pools", []))
    total_sessions = sum(p.get("session_count", 0)
                         for p in horizon.get("desktop_pools", []))
    total_mem_gb   = sum(c.get("total_memory_gb", 0)
                         for c in vcenter.get("clusters", []))
    total_ds_gb    = sum(d.get("capacity_gb", 0)
                         for d in storage.get("datastores", []))

    print("\n" + "─" * 60)
    print(f"  Environment: {meta.get('environment_name', 'Horizon View')}")
    print(f"  Scanned   : {meta.get('generated_at','')[:10]}")
    print("─" * 60)
    print(f"  NetScaler VIPs      : {len(dmz.get('netscalers', []))}")
    print(f"  UAGs                : {len(dmz.get('unified_access_gateways', []))}")
    print(f"  Connection Servers  : {len(horizon.get('connection_servers', []))}")
    print(f"  Desktop Pools       : {len(horizon.get('desktop_pools', []))}")
    print(f"  Total VMs           : {total_machines:,}")
    print(f"  Active Sessions     : {total_sessions:,}")
    print(f"  vSphere Clusters    : {len(vcenter.get('clusters', []))}")
    print(f"  Compute RAM (total) : {total_mem_gb:,} GB")
    print(f"  FC HBA Ports        : {len(storage.get('fc_hbas', []))}")
    print(f"  Datastores          : {len(storage.get('datastores', []))} ({total_ds_gb:,} GB)")
    print(f"  Connection Edges    : {len(conns)}")
    print("─" * 60)


# ══════════════════════════════════════════════════════════════════════════════
# ── Entry Point ───────────────────────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════════════

def main():
    print_banner()

    parser = argparse.ArgumentParser(
        description="Generate a Horizon View architecture diagram from harvested JSON",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python Generate-HorizonDiagram.py --input horizon-environment.json
  python Generate-HorizonDiagram.py --input horizon-environment.json --format svg
  python Generate-HorizonDiagram.py --input horizon-environment.json --drawio
  python Generate-HorizonDiagram.py --input horizon-environment.json --format png --show-hosts
  python Generate-HorizonDiagram.py --input horizon-environment.json --no-port-labels
        """
    )
    parser.add_argument("--input",    "-i", default="horizon-environment.json",
                        help="Path to JSON from Invoke-HorizonHarvester.ps1")
    parser.add_argument("--output",   "-o", default="",
                        help="Output filename stem (no extension). Defaults to env name.")
    parser.add_argument("--format",   "-f", default="png",
                        choices=["png", "svg", "pdf"],
                        help="Output format for diagrams library render (default: png)")
    parser.add_argument("--drawio",   "-d", action="store_true",
                        help="Also generate a Draw.io editable XML file")
    parser.add_argument("--show-hosts", action="store_true",
                        help="Show individual ESXi hosts inside cluster boxes (can be busy)")
    parser.add_argument("--no-port-labels", action="store_true",
                        help="Hide port/protocol labels on edges (cleaner for presentations)")
    parser.add_argument("--summary-only", action="store_true",
                        help="Print environment summary and exit without generating diagram")

    args = parser.parse_args()

    # Load environment data
    env = load_environment(args.input)
    print_environment_summary(env)

    if args.summary_only:
        return

    # Determine output filename
    meta = env.get("metadata", {})
    env_name = meta.get("environment_name", "horizon-view-diagram")
    safe_name = env_name.lower().replace(" ", "-").replace("/", "-")

    output_stem = args.output if args.output else safe_name
    show_ports  = not args.no_port_labels

    # Generate diagrams library PNG/SVG/PDF
    print_step(f"Generating {args.format.upper()} diagram...")
    build_diagram(
        env         = env,
        output_path = output_stem,
        output_format = args.format,
        show_port_labels = show_ports,
        show_hosts  = args.show_hosts,
    )

    # Optionally generate Draw.io XML
    if args.drawio:
        print_step("Generating Draw.io XML...")
        drawio_path = f"{output_stem}.drawio"
        build_drawio_xml(env, drawio_path)

    print("\n╔══════════════════════════════════════════════════════════╗")
    print("║                   Diagram Complete!                     ║")
    print("╠══════════════════════════════════════════════════════════╣")
    print(f"║  PNG/SVG : {(output_stem + '.' + args.format).ljust(45)} ║")
    if args.drawio:
        print(f"║  Draw.io : {(output_stem + '.drawio').ljust(45)} ║")
    print("╚══════════════════════════════════════════════════════════╝\n")


if __name__ == "__main__":
    main()
