# dynavlan positioning brief

Draft for expansion. Not committed; refine before publishing.

## One-liner

Auto-discover and configure every VLAN on every trunk a Linux box is plugged into, with zero switch-side changes and zero SSH.

## The gap

Enterprise networks have GVRP/MVRP and 802.1x RADIUS VLAN push for dynamic VLAN assignment, but all of those require switch-side configuration and often a RADIUS server. On the host side, VLANs are statically declared in netplan/networkd YAML or pushed by Ansible. Nobody built the inverse: a host-side tool that passively discovers what the switch is already trunking and brings each VLAN up with DHCP.

The gap exists because most environments control both ends and configure statically. The "plug in a box and let it find its VLANs" use case is narrow but real: monitoring appliances, edge sensors, kiosk/signage deployments, MSP boxes dropped at client sites.

## Who it's for

- **MSPs and integrators** deploying monitoring appliances (Domotz, PRTG, Auvik probes) at client sites with no switch access and no site visit budget for VLAN changes
- **Edge/IoT deployments** where boxes are shipped preconfigured and plugged into whatever trunk port is available
- **Lab and staging environments** where VLAN topology changes frequently and static config is churn
- **Any headless Linux box** that needs to reach multiple VLANs without manual network configuration

## What it does

1. Discovers every trunk port the box is connected to (passive 802.1Q sniff + LLDP)
2. Brings up each detected VLAN with DHCP, fully route-isolated by default
3. Runs at boot (full reconcile) and on a timer (rescan: adds new VLANs, and prunes a trunk's VLANs after a sustained carrier-down loss)
4. Never touches the base network config; owns exactly one netplan file
5. Auto-reverts on failure (netplan try + routing health check), so a bad apply never strands a headless box

## Anticipated objections and answers

### "Isn't auto-joining VLANs a security risk?"

dynavlan discovers what's already trunked to the port. It doesn't negotiate trunk status or request VLANs the switch isn't sending. If those VLANs shouldn't reach the box, the fix is at the switch port, not the host. VLAN_IGNORE provides host-side opt-out for specific VLANs (guest, voice, contractually off-limits segments).

Default mode is fully route-isolated: DHCP address only, no routes, no DNS, no NTP from VLAN subnets. The box is present on each VLAN L2/L3 but doesn't route through them.

### "Will it slow down my box?"

VLAN subinterfaces are lightweight kernel constructs (a netdev + a DHCP lease). The cost is lease renewal traffic, which is negligible. On a trunk with many VLANs, VLAN_LIMIT caps the total (default 64) and VLAN_WARN alerts before it gets there. Detection is a single 60s passive capture per trunk, not per VLAN.

### "What if it breaks my network connection?"

This is the strongest objection and the strongest answer. Every apply goes through netplan try with a health check gated on the pre-apply default route. If the uplink disappears, the change auto-reverts. VLAN lease failures never trigger a revert. The entire design is built around "never strand a headless box."

The revert path is hardware-validated: tested on real appliances with console access, including forced failures.

### "What about VLANs removed from the switch?"

Two removal paths, both conservative by design (a false removal on a remote box may be unrecoverable): a VLAN detagged from a still-live trunk is removed only when the trunk has carrier AND two independent detection passes both confirm it's gone. A trunk that goes fully carrier-down (cable pull, switch reboot) has all its VLANs removed after a debounced confirmation, but only while the box still has healthy routing elsewhere - if the dead trunk doubles as the box's only route, its VLANs are preserved instead of attempting a doomed removal. Both paths run at boot and on the rescan timer.

### "Why only netplan/systemd-networkd?"

Current scope. The backend is structured as a seam (generate/validate/apply/remove are isolated functions), so a NetworkManager or raw-networkd backend is possible. Covers Ubuntu 22.04+ and Debian with netplan, which is the common base for appliance images.

### "How is this different from 802.1x / GVRP / MVRP?"

Those are switch-side protocols that push VLAN membership decisions from the network to the host. dynavlan is host-side only: it observes what the switch is already doing and configures accordingly. No switch changes, no RADIUS server, no protocol negotiation. Complements rather than replaces switch-side automation.

## Competitive landscape

There is no direct competitor. Adjacent tools:

| Tool/approach | What it does | Why it's not this |
|---|---|---|
| Static netplan YAML | Declares VLANs by hand | Requires SSH, site knowledge, per-box config |
| Ansible/Puppet | Pushes VLAN config from a controller | Requires inventory, connectivity, VLAN list |
| GVRP/MVRP | Switch-side dynamic VLAN registration | Requires switch support and config |
| 802.1x + RADIUS | Assigns VLANs based on auth | Requires RADIUS infra and switch config |
| PyScanVLAN, pentest tools | Discover VLANs for auditing | Not built for unattended DHCP provisioning |
| vconfig/ip link add | Manual VLAN creation | No discovery, no DHCP, no lifecycle |

## Key differentiators

1. **Host-side, zero switch changes**: works on any vendor's trunk port
2. **Safe by default**: netplan try + health check + auto-revert; route-isolated VLANs
3. **Truly unattended**: boot + timer, no SSH needed after initial install
4. **Multi-trunk**: discovers and provisions every trunk, not just one
5. **Single file, no dependencies**: one bash script, standard Linux tools (tcpdump, lldpctl, netplan)

## Open questions for positioning

- Pricing model: open-source core + commercial support? Pure open-source with consulting?
- Name recognition: "dynavlan" is descriptive and available but not memorable. Rebrand before launch?
- Target channel: direct to MSPs? Bundled with monitoring vendors (Domotz marketplace)? Linux appliance builders?
- Documentation site: GitHub Pages, standalone docs site, or README-only for now?
