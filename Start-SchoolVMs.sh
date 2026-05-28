#!/usr/bin/env bash
# ==============================================================
#  Start-SchoolVMs.sh
#  Starts all 6 SchoolVMs on VMware Workstation Pro 17 (Linux)
#  and configures static IPs mirroring FWCS Haley IDF layout.
#
#  NETWORK LAYOUT
#    Subnet  : 192.168.4.0/24
#    Gateway : 192.168.4.1
#    DNS     : 192.168.4.30  (WinServer2022-1, Domain Controller)
#
#    .30  WinServer2022-1   Primary DC / AD / DNS
#    .31  WinServer2022-2   Secondary DC / File Server
#    .32  WinServer2022-3   DHCP / Print Relay
#    .33  Ubuntu2204-1      Linux Server Workstation
#    .34  Ubuntu2204-2      Linux Server Workstation
#    .35  RockyLinux9-1     Linux Server / RHEL Lab Node
#
#  EXISTING DEVICES ON 192.168.4.x (not touched):
#    .1   Router/Gateway         50:27:A9:F7:1A:AD
#    .21  Amazon device          F8:54:B8:1F:BB:DE
#    .22  HP Print Server        30:24:A9:BD:B2:52  (HPBDB252)
#    .23  Unknown                02:93:69:61:16:54
#    .24  Unknown                84:C8:A0:AD:28:04
#    .25  WIN-GP0I1JBMRPO        00:CE:39:D4:FD:CC
#    .58  Unknown                AC:15:18:05:4B:D8
#    .59  Espressif (IoT)        7C:87:CE:8E:40:83
#    .87  Unknown                F6:3C:9D:90:75:8C
#
#  USAGE:
#    chmod +x Start-SchoolVMs.sh
#    ./Start-SchoolVMs.sh
# ==============================================================

set -euo pipefail

# ── Colours ────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; GRAY='\033[0;37m'
NC='\033[0m'

ok()  { echo -e "  ${GREEN}[OK] ${NC} $*"; }
inf() { echo -e "  ${CYAN}[-->]${NC} $*"; }
err() { echo -e "  ${RED}[!!] ${NC} $*"; }
wrn() { echo -e "  ${YELLOW}[**] ${NC} $*"; }
hdr() {
    echo ""
    echo -e "${YELLOW}$(printf '=%.0s' {1..64})${NC}"
    echo -e "${YELLOW}  $*${NC}"
    echo -e "${YELLOW}$(printf '=%.0s' {1..64})${NC}"
}
div() { echo -e "${GRAY}$(printf -- '-%.0s' {1..64})${NC}"; }

# ── Configuration ──────────────────────────────────────────────
VM_BASE="${HOME}/VMs/SchoolVMs"
GATEWAY="192.168.4.1"
NETMASK="255.255.255.0"
PREFIX="24"
DOMAIN="fwcs.lab"
DNS1="192.168.4.30"
DNS2="192.168.4.31"

# VM name | IP | role | OS type
declare -a VM_NAMES=("WinServer2022-1" "WinServer2022-2" "WinServer2022-3" "Ubuntu2204-1"             "Ubuntu2204-2"             "RockyLinux9-1")
declare -a VM_IPS=(  "192.168.4.30"    "192.168.4.31"    "192.168.4.32"    "192.168.4.33"             "192.168.4.34"             "192.168.4.35")
declare -a VM_ROLES=("Primary DC/AD/DNS" "Secondary DC/File Server" "DHCP/Print Relay" "Linux Server Workstation" "Linux Server Workstation" "Linux Server/RHEL Lab")
declare -a VM_OS=(   "windows"          "windows"         "windows"         "linux"                    "linux"                    "linux")

# ── Locate vmrun ───────────────────────────────────────────────
VMRUN=""
for candidate in \
    "/usr/bin/vmrun" \
    "/usr/local/bin/vmrun" \
    "${HOME}/vmware/vmrun" \
    "/opt/vmware/workstation/bin/vmrun"; do
    if [[ -x "$candidate" ]]; then
        VMRUN="$candidate"
        break
    fi
done

# Try PATH as fallback
if [[ -z "$VMRUN" ]] && command -v vmrun &>/dev/null; then
    VMRUN=$(command -v vmrun)
fi

# ── STEP 1 — Locate vmrun ──────────────────────────────────────
hdr "Step 1: Locating VMware vmrun"

if [[ -z "$VMRUN" ]]; then
    err "vmrun not found. Is VMware Workstation Pro 17 installed?"
    err "Common path: /usr/bin/vmrun — check with: which vmrun"
    exit 1
fi
ok "vmrun : $VMRUN"

# ── STEP 2 — Verify VMX files ──────────────────────────────────
hdr "Step 2: Verifying VMX files"

MISSING=0
for i in "${!VM_NAMES[@]}"; do
    name="${VM_NAMES[$i]}"
    vmx="${VM_BASE}/${name}/${name}.vmx"
    if [[ -f "$vmx" ]]; then
        ok "${name}  ->  ${vmx}"
    else
        err "Missing VMX: ${vmx}"
        MISSING=$((MISSING + 1))
    fi
done

if [[ $MISSING -gt 0 ]]; then
    echo ""
    err "Cannot continue — run Create-SchoolVMs.ps1 (Windows) first to build the missing VMs."
    exit 1
fi

# ── STEP 3 — Inject network config as VMware guest variables ───
hdr "Step 3: Writing static IP config into each VM (guestinfo vars)"

set_guest_var() {
    local vmx="$1" key="$2" value="$3"

    # Write via vmrun if VM is already powered on
    "$VMRUN" -T ws writeVariable "$vmx" guestVar "$key" "$value" 2>/dev/null || true

    # Also bake into VMX directly so it survives cold boot
    local entry="guestinfo.${key} = \"${value}\""
    if grep -q "guestinfo\.${key}" "$vmx" 2>/dev/null; then
        sed -i "s|^guestinfo\.${key}\s*=.*|${entry}|" "$vmx"
    else
        echo "$entry" >> "$vmx"
    fi
}

for i in "${!VM_NAMES[@]}"; do
    name="${VM_NAMES[$i]}"
    ip="${VM_IPS[$i]}"
    role="${VM_ROLES[$i]}"
    os="${VM_OS[$i]}"
    vmx="${VM_BASE}/${name}/${name}.vmx"

    inf "Setting network config for ${name}  (${ip})"
    set_guest_var "$vmx" "hostname" "$name"
    set_guest_var "$vmx" "ip"       "$ip"
    set_guest_var "$vmx" "netmask"  "$NETMASK"
    set_guest_var "$vmx" "gateway"  "$GATEWAY"
    set_guest_var "$vmx" "dns1"     "$DNS1"
    set_guest_var "$vmx" "dns2"     "$DNS2"
    set_guest_var "$vmx" "domain"   "$DOMAIN"
    set_guest_var "$vmx" "role"     "$role"

    if [[ "$os" == "linux" ]]; then
        set_guest_var "$vmx" "netscript" "/usr/local/bin/fwcs-netconfig.sh"
    fi

    ok "${name} -> IP=${ip}  GW=${GATEWAY}  DNS=${DNS1}"
done

# ── STEP 4 — Power on all VMs ─────────────────────────────────
hdr "Step 4: Powering on all 6 VMs"

declare -a RESULTS_STATUS

for i in "${!VM_NAMES[@]}"; do
    name="${VM_NAMES[$i]}"
    ip="${VM_IPS[$i]}"
    role="${VM_ROLES[$i]}"
    vmx="${VM_BASE}/${name}/${name}.vmx"
    num=$((i + 1))

    echo ""
    div
    echo -e "  ${WHITE}VM ${num} of ${#VM_NAMES[@]}  :  ${name}  [${role}]${NC}"
    echo -e "  ${GRAY}IP : ${ip}   GW : ${GATEWAY}   DNS : ${DNS1}${NC}"
    div

    # Check if already running
    if "$VMRUN" -T ws list 2>/dev/null | grep -qF "$vmx"; then
        wrn "${name} is already powered on — skipping."
        RESULTS_STATUS[$i]="Already running"
    else
        inf "Starting ${name} (nogui)..."
        if "$VMRUN" -T ws start "$vmx" nogui 2>&1; then
            ok "${name} started."
            RESULTS_STATUS[$i]="Started"
        else
            err "Failed to start ${name}."
            RESULTS_STATUS[$i]="FAILED"
        fi
    fi

    if [[ $((i + 1)) -lt ${#VM_NAMES[@]} ]]; then
        echo -e "  ${GRAY}Waiting 10 seconds before next VM...${NC}"
        sleep 10
    fi
done

# ── STEP 5 — First-boot network setup instructions ─────────────
hdr "Step 5: First-boot network setup (run inside each VM)"

echo ""
echo -e "  ${CYAN}── WINDOWS SERVER VMs (.30, .31, .32) ─────────────────────${NC}"
echo -e "  ${WHITE}Run in elevated PowerShell inside each Windows VM:${NC}"
echo ""
cat <<'WINCMDS'
  # Replace $ip with the VM's assigned IP (.30, .31, or .32)
  $ip      = "192.168.4.30"
  $adapter = Get-NetAdapter | Where-Object Status -eq "Up" | Select-Object -First 1
  New-NetIPAddress -InterfaceIndex $adapter.ifIndex `
      -IPAddress $ip -PrefixLength 24 -DefaultGateway "192.168.4.1"
  Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex `
      -ServerAddresses ("192.168.4.30","192.168.4.31")
  Rename-Computer -NewName "WinServer2022-1"   # change per VM
  Restart-Computer

  # Then on WinServer2022-1 only — promote to Domain Controller:
  Install-WindowsFeature AD-Domain-Services -IncludeManagementTools
  Install-ADDSForest -DomainName "fwcs.lab" -InstallDns
WINCMDS

echo ""
echo -e "  ${CYAN}── UBUNTU SERVER 22.04 VMs (.33, .34) ───────────────────────${NC}"
echo -e "  ${WHITE}Edit /etc/netplan/00-installer-config.yaml inside each VM:${NC}"
echo -e "  ${GRAY}  NOTE: VMware interface is typically ens33; newer hardware${NC}"
echo -e "  ${GRAY}  profiles may present it as ens160 — check with: ip link${NC}"
echo ""
cat <<'UBUCMDS'
  # /etc/netplan/00-installer-config.yaml
  # Adjust 'addresses' and 'hostname' per VM (.33 or .34)
  network:
    version: 2
    ethernets:
      ens33:                              # or ens160 — verify with: ip link
        dhcp4: no
        addresses:
          - 192.168.4.33/24              # use 192.168.4.34/24 for Ubuntu2204-2
        routes:
          - to: default
            via: 192.168.4.1
        nameservers:
          search: [fwcs.lab]
          addresses: [192.168.4.30, 192.168.4.31]

  sudo netplan apply
  sudo hostnamectl set-hostname Ubuntu2204-1   # or Ubuntu2204-2
UBUCMDS

echo ""
echo -e "  ${CYAN}── ROCKY LINUX 9 VM (.35) ───────────────────────────────────${NC}"
echo -e "  ${WHITE}Run inside the RockyLinux VM:${NC}"
echo ""
cat <<'ROCKYCMDS'
  # Verify the connection name first (usually 'ens33' or 'Wired connection 1')
  nmcli con show

  sudo nmcli con mod ens33 ipv4.method manual \
      ipv4.addresses 192.168.4.35/24 \
      ipv4.gateway 192.168.4.1 \
      ipv4.dns "192.168.4.30 192.168.4.31" \
      ipv4.dns-search "fwcs.lab"
  sudo nmcli con up ens33
  sudo hostnamectl set-hostname RockyLinux9-1

  # Optional: disable firewalld if using host-only/bridged lab networking
  # sudo systemctl disable --now firewalld
ROCKYCMDS

# ── STEP 6 — Summary table ─────────────────────────────────────
hdr "Done — VM Status"

echo ""
printf "  %-4s  %-20s  %-15s  %-26s  %-16s\n" "#" "VM" "IP" "Role" "Status"
printf "  %-4s  %-20s  %-15s  %-26s  %-16s\n" "----" "--------------------" "---------------" "--------------------------" "----------------"
for i in "${!VM_NAMES[@]}"; do
    printf "  %-4s  %-20s  %-15s  %-26s  %-16s\n" \
        "$((i+1))" "${VM_NAMES[$i]}" "${VM_IPS[$i]}" "${VM_ROLES[$i]}" "${RESULTS_STATUS[$i]:-Unknown}"
done

echo ""
echo -e "  ${CYAN}Subnet  : 192.168.4.0/24   Gateway : 192.168.4.1${NC}"
echo -e "  ${CYAN}Domain  : fwcs.lab         DNS     : 192.168.4.30 / .31${NC}"
echo ""
echo -e "  ${YELLOW}HP Print Server at .22 (HPBDB252) is already on your LAN.${NC}"
echo -e "  ${YELLOW}Point WinServer2022-3 print relay at 192.168.4.22 to mirror${NC}"
echo -e "  ${YELLOW}the Haley IDF print server configuration.${NC}"
echo ""
echo -e "  ${GRAY}To stop all VMs:${NC}"
echo -e "  ${GRAY}  for vmx in \$(find \"${VM_BASE}\" -name '*.vmx'); do${NC}"
echo -e "  ${GRAY}    \"${VMRUN}\" -T ws stop \"\$vmx\" soft; done${NC}"
echo ""
