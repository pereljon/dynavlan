# Domotz Deployment Guide (Protectli / Ubuntu Server)

A reference runbook for provisioning a Domotz monitoring agent on a Protectli (Intel) box running Ubuntu Server. dynavlan automates the VLAN portion of step 8; this guide documents the surrounding manual deployment.

## 1. Install Ubuntu Server

- Minimum install.
- Auto-partition with LVM.
- Create an admin user:
  - Name: `<Admin Name>`
  - Username: `<admin>`
  - Password: stored in your password manager
- Set a hostname.
- Pull the SSH public key from your provisioning account: `https://github.com/<your-tech-account>.keys`
- Disable SSH password authentication.
- Don't install any extra services during install.

## 2. Log Into Device

```
ssh -i ~/.ssh/<your_tech_key> <admin>@IP_ADDRESS
```

## 3. Update OS

```
sudo apt -y remove needrestart
sudo apt update && sudo apt -y dist-upgrade
sudo apt -y autoremove
```

## 4. Install UFW

```
sudo apt -y install ufw
sudo ufw allow ssh
sudo ufw enable
```

## 5. Set Up Domotz

```
sudo snap install domotzpro-agent-publicstore
sudo snap connect domotzpro-agent-publicstore:firewall-control
sudo snap connect domotzpro-agent-publicstore:network-observe
sudo snap connect domotzpro-agent-publicstore:raw-usb
sudo snap connect domotzpro-agent-publicstore:shutdown
sudo snap connect domotzpro-agent-publicstore:system-observe
sudo sh -c 'echo tun >> /etc/modules'
sudo modprobe tun
sudo ufw allow 3000
```

## 6. Install iPerf3

```
sudo apt -y install iperf3
sudo ufw allow 5210
```

## 7. Install Additional Packages

```
sudo apt -y install apt-utils iputils-ping net-tools nano lldpd screen tcpdump
```

## 8. Set Up Networking (netplan)

The static configuration below is the manual approach dynavlan replaces. It declares a fixed set of VLANs by hand; dynavlan discovers them automatically instead (see `docs/dynavlan-PRD.md`).

```
sudo nano /etc/netplan/01-netcfg.yaml
```

Example `/etc/netplan/01-netcfg.yaml` (VLAN IDs are an example set; adjust per site):

```yaml
# Network config for Domotz
# /etc/netplan/01-netcfg.yaml
# sudo netplan apply
network:
  version: 2
  renderer: networkd
  ethernets:
    enp1s0:
      dhcp4: true
      dhcp4-overrides:
        route-metric: 10
    enp2s0:
      dhcp4: true
      dhcp4-overrides:
        route-metric: 20
  vlans:
    vlan1:
      id: 1
      link: enp1s0
      dhcp4: true
      dhcp4-overrides:
        route-metric: 100
    vlan11:
      id: 11
      link: enp1s0
      dhcp4: true
      dhcp4-overrides:
        route-metric: 200
    vlan19:
      id: 19
      link: enp1s0
      dhcp4: true
      dhcp4-overrides:
        route-metric: 300
    vlan20:
      id: 20
      link: enp1s0
      dhcp4: true
      dhcp4-overrides:
        route-metric: 400
    vlan21:
      id: 21
      link: enp1s0
      dhcp4: true
      dhcp4-overrides:
        route-metric: 500
    vlan22:
      id: 22
      link: enp1s0
      dhcp4: true
      dhcp4-overrides:
        route-metric: 600
    vlan23:
      id: 23
      link: enp1s0
      dhcp4: true
      dhcp4-overrides:
        route-metric: 700
```

```
sudo chmod go-r /etc/netplan/01-netcfg.yaml
sudo netplan apply
```
