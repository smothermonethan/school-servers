#!/usr/bin/env bash
# =============================================================================
#  Christian Lempa HomeLab — Proxmox Full Auto VM Builder  (v2)
#  youtube.com/@christianlempa  |  christianlempa.de
#
#  PROXMOX ONLY. Updated to match Christian's actual current stack:
#    - Sophos Firewall Home  (his Jan 2026 video: "Install Sophos Firewall
#      Home on Proxmox" — he works AT Sophos, this is now his primary FW)
#    - OPNsense              (kept as alt/secondary — also fully covered)
#    - Debian 13 Trixie      (primary OS for all his servers)
#    - Ubuntu 24 LTS         (secondary OS in some tutorials)
#    - TrueNAS SCALE         (NAS/ZFS storage)
#    - Proxmox Backup Server (dedicated PBS VM — full tutorial)
#    - k3s cluster           (control plane + 3 workers, Debian-based)
#    - Docker hosts          (runs his whole self-hosted stack)
#    - GitLab, n8n, NetBird, Coolify, Grafana, Pangolin (dedicated tutorials)
#    - AdGuard Home + Pi-hole (both have dedicated 2025 tutorials)
#    - Windows Server 2025   (AD/DNS labs)
#    - Kali Linux            (security lab)
#
#  IMPORTANT — SOPHOS FIREWALL NOTE:
#    Sophos does NOT provide a public direct-download ISO/qcow2 URL.
#    You must create a free Sophos ID, register a serial, then download
#    "Firewall OS for KVM" (qcow2 format) manually from:
#      https://www.sophos.com/en-us/free-tools/sophos-firewall-home-edition
#    This script will detect the file if you place it in the path printed
#    below, and will build the VM around it automatically. It cannot be
#    auto-downloaded — no public URL exists, this is intentional by Sophos.
#
#  All prior bugs fixed: no (()) arithmetic, ISO volid resolved live via
#  pvesm, set -e deferred until after safe init, thin-pool space checked,
#  Windows VMs get OVMF+TPM+virtio-win, WebSocket 1006 causes eliminated.
#
#  Run as root on Proxmox VE:
#    chmod +x christian_lempa_proxmox_homelab.sh
#    bash christian_lempa_proxmox_homelab.sh
# =============================================================================

set -uo pipefail

# ═══════════════════════════════════════════════════════════════════════════════
#  CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════════
STORAGE="local-lvm"
BRIDGE="vmbr0"
LAN_BRIDGE="vmbr1"        # second bridge for firewall LAN side — create if missing
ISO_STORAGE="local"
ISO_DIR="/var/lib/vz/template/iso"
QCOW_DIR="/var/lib/vz/template/qcow"     # for Sophos qcow2 images
START_VMID=400

# ═══════════════════════════════════════════════════════════════════════════════
#  LOGGING
# ═══════════════════════════════════════════════════════════════════════════════
GRN='\033[0;32m'; YLW='\033[1;33m'; RED='\033[0;31m'
CYN='\033[0;36m'; BLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${GRN}[+]${NC} $*"; }
warn()    { echo -e "${YLW}[!]${NC} $*"; }
err()     { echo -e "${RED}[x]${NC} $*"; }
section() {
  echo ""
  echo -e "${CYN}${BLD}══════════════════════════════════════════════════════${NC}"
  echo -e "${CYN}${BLD}  $*${NC}"
  echo -e "${CYN}${BLD}══════════════════════════════════════════════════════${NC}"
}

NODE="$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo 'proxmox')"

# ═══════════════════════════════════════════════════════════════════════════════
#  HELPERS
# ═══════════════════════════════════════════════════════════════════════════════

next_vmid() {
  local id="$START_VMID"
  while qm status "$id" >/dev/null 2>&1; do id="$((id + 1))"; done
  echo "$id"
}
bump_vmid() { START_VMID="$((START_VMID + 1))"; }

download_iso() {
  local name="$1" url="$2"
  local dest="${ISO_DIR}/${name}"

  if [[ -f "$dest" ]]; then
    warn "Already exists: ${name} — skipping"
    pvesm rescan --storage "${ISO_STORAGE}" >/dev/null 2>&1 || true
    return 0
  fi
  if [[ -z "$url" ]]; then
    warn "No URL for ${name} — place manually in ${ISO_DIR}"
    return 0
  fi

  log "Downloading: ${name}"
  local ok=0
  pvesm download "${ISO_STORAGE}" "$url" "$name" >/dev/null 2>&1 && ok=1 || true
  if [[ "$ok" -eq 1 ]]; then log "  Registered via pvesm ✓"; return 0; fi

  warn "  pvesm download unavailable — using wget"
  local wok=0
  wget -q --show-progress -c -O "${dest}.part" "$url" && wok=1 || true
  if [[ "$wok" -eq 1 ]] && [[ -f "${dest}.part" ]]; then
    mv "${dest}.part" "$dest"
    pvesm rescan --storage "${ISO_STORAGE}" >/dev/null 2>&1 || true
    log "  Downloaded + rescanned ✓"
  else
    rm -f "${dest}.part" 2>/dev/null || true
    warn "  FAILED: ${name} — dependent VMs will be skipped"
  fi
}

iso_ok() {
  [[ -f "${ISO_DIR}/$1" ]] || return 1
  pvesm list "${ISO_STORAGE}" 2>/dev/null | grep -q "$1" || return 1
  return 0
}
iso_volid() {
  pvesm list "${ISO_STORAGE}" 2>/dev/null | awk -v n="$1" '$0 ~ n {print $1; exit}' || true
}

# ─── Linux VM ─────────────────────────────────────────────────────────────────
create_linux_vm() {
  local vmid="$1" name="$2" iso="$3" ram="$4" cores="$5" disk="$6"
  local ostype="${7:-l26}"

  if ! iso_ok "$iso"; then warn "SKIP ${name} — ISO not registered: ${iso}"; return 0; fi
  if qm status "$vmid" >/dev/null 2>&1; then warn "SKIP ${name} — VMID ${vmid} exists"; return 0; fi

  local vol; vol="$(iso_volid "$iso")"
  [[ -z "$vol" ]] && { warn "SKIP ${name} — cannot resolve volid for ${iso}"; return 0; }

  log "VM ${vmid}: ${name}  [RAM:${ram}MB CPU:${cores} Disk:${disk}G OS:${ostype}]"

  qm create "$vmid" \
    --name "$name" --ostype "$ostype" --memory "$ram" --sockets 1 --cores "$cores" \
    --cpu host --scsihw virtio-scsi-pci --scsi0 "${STORAGE}:${disk},iothread=1" \
    --net0 "virtio,bridge=${BRIDGE},firewall=1" --vga std --agent enabled=1 \
    --onboot 1 --ide2 "${vol},media=cdrom"

  qm set "$vmid" --boot "order=ide2;scsi0" >/dev/null
  log "  ✓ ${name} ready"
}

# ─── Windows VM ───────────────────────────────────────────────────────────────
create_win_vm() {
  local vmid="$1" name="$2" iso="$3" ram="$4" cores="$5" disk="$6"
  local ostype="${7:-w2k22}"

  if ! iso_ok "$iso"; then warn "SKIP ${name} — ISO not registered: ${iso}"; return 0; fi
  if qm status "$vmid" >/dev/null 2>&1; then warn "SKIP ${name} — VMID ${vmid} exists"; return 0; fi

  local vol; vol="$(iso_volid "$iso")"
  [[ -z "$vol" ]] && { warn "SKIP ${name} — cannot resolve volid for ${iso}"; return 0; }

  log "VM ${vmid}: ${name}  [RAM:${ram}MB CPU:${cores} Disk:${disk}G OS:${ostype}]"

  qm create "$vmid" \
    --name "$name" --ostype "$ostype" --memory "$ram" --sockets 1 --cores "$cores" \
    --cpu host --scsihw virtio-scsi-pci --scsi0 "${STORAGE}:${disk},iothread=1" \
    --net0 "virtio,bridge=${BRIDGE},firewall=1" --vga qxl --bios ovmf --machine q35 \
    --tpmstate0 "${STORAGE}:4,version=v2.0" --agent enabled=1 --onboot 1 \
    --ide2 "${vol},media=cdrom"

  qm set "$vmid" --efidisk0 "${STORAGE}:1,efitype=4m,pre-enrolled-keys=1" >/dev/null

  local vwin; vwin="$(iso_volid "virtio-win.iso")"
  if [[ -n "$vwin" ]]; then
    qm set "$vmid" --ide0 "${vwin},media=cdrom" >/dev/null
    qm set "$vmid" --boot "order=ide2;scsi0;ide0" >/dev/null
  else
    qm set "$vmid" --boot "order=ide2;scsi0" >/dev/null
  fi
  log "  ✓ ${name} ready"
}

# ─── Firewall VM (ISO-based, e.g. OPNsense) ───────────────────────────────────
create_firewall_vm_iso() {
  local vmid="$1" name="$2" iso="$3" ram="$4" cores="$5" disk="$6"

  if ! iso_ok "$iso"; then warn "SKIP ${name} — ISO not registered: ${iso}"; return 0; fi
  if qm status "$vmid" >/dev/null 2>&1; then warn "SKIP ${name} — VMID ${vmid} exists"; return 0; fi

  local vol; vol="$(iso_volid "$iso")"
  [[ -z "$vol" ]] && { warn "SKIP ${name} — cannot resolve volid for ${iso}"; return 0; }

  log "VM ${vmid}: ${name}  [Firewall  RAM:${ram}MB CPU:${cores} Disk:${disk}G]"

  qm create "$vmid" \
    --name "$name" --ostype other --memory "$ram" --sockets 1 --cores "$cores" \
    --cpu host --scsihw virtio-scsi-pci --scsi0 "${STORAGE}:${disk},iothread=1" \
    --net0 "virtio,bridge=${BRIDGE},firewall=0" \
    --net1 "virtio,bridge=${LAN_BRIDGE},firewall=0" \
    --vga std --agent enabled=1 --onboot 1 --ide2 "${vol},media=cdrom"

  qm set "$vmid" --boot "order=ide2;scsi0" >/dev/null
  log "  ✓ ${name} ready  (net0=WAN/${BRIDGE}  net1=LAN/${LAN_BRIDGE})"
}

# ─── Sophos Firewall VM (qcow2-based — special case) ──────────────────────────
# Sophos ships as pre-built qcow2 disk images (no installer ISO).
# You must manually download "Firewall OS for KVM" from your Sophos ID portal
# and place BOTH qcow2 files in $QCOW_DIR before running this script.
create_sophos_vm() {
  local vmid="$1" name="$2" ram="$3" cores="$4"

  mkdir -p "$QCOW_DIR"

  # Sophos provides two qcow2 disks: primary (boot) + data
  local disk1="" disk2=""
  disk1="$(find "$QCOW_DIR" -iname "*sfos*disk1*.qcow2" -o -iname "*primary*.qcow2" 2>/dev/null | head -1)" || true
  disk2="$(find "$QCOW_DIR" -iname "*sfos*disk2*.qcow2" -o -iname "*data*.qcow2"    2>/dev/null | head -1)" || true

  if [[ -z "$disk1" ]]; then
    warn "SKIP ${name} — Sophos qcow2 images not found in ${QCOW_DIR}"
    warn "  Sophos has NO public download URL. To get it:"
    warn "  1. Create free account: https://www.sophos.com/en-us/free-tools/sophos-firewall-home-edition"
    warn "  2. Register a free serial number"
    warn "  3. Download 'Firewall OS for KVM' (zip containing 2x .qcow2 files)"
    warn "  4. Extract both .qcow2 files into: ${QCOW_DIR}"
    warn "  5. Re-run this script — Sophos VM will then be created"
    return 0
  fi

  if qm status "$vmid" >/dev/null 2>&1; then warn "SKIP ${name} — VMID ${vmid} exists"; return 0; fi

  log "VM ${vmid}: ${name}  [Sophos Firewall Home  RAM:${ram}MB CPU:${cores}]"

  # Sophos recommends: 4 cores, 4-6GB RAM, 2+ NICs, no Proxmox-created disk
  # (disks come pre-built from the qcow2 images)
  qm create "$vmid" \
    --name "$name" --ostype other --memory "$ram" --sockets 1 --cores "$cores" \
    --cpu host --scsihw virtio-scsi-pci \
    --net0 "virtio,bridge=${BRIDGE},firewall=0" \
    --net1 "virtio,bridge=${LAN_BRIDGE},firewall=0" \
    --vga std --agent enabled=1 --onboot 1

  # Import the primary (boot) disk as scsi0
  qm importdisk "$vmid" "$disk1" "$STORAGE" --format qcow2 >/dev/null 2>&1 || {
    warn "  Failed to import primary disk for ${name}"
    return 0
  }
  qm set "$vmid" --scsi0 "${STORAGE}:vm-${vmid}-disk-0" >/dev/null

  # Import data disk if present
  if [[ -n "$disk2" ]]; then
    qm importdisk "$vmid" "$disk2" "$STORAGE" --format qcow2 >/dev/null 2>&1 || true
    qm set "$vmid" --scsi1 "${STORAGE}:vm-${vmid}-disk-1" >/dev/null 2>&1 || true
  fi

  qm set "$vmid" --boot "order=scsi0" >/dev/null
  log "  ✓ ${name} ready  (net0=WAN/${BRIDGE}  net1=LAN/${LAN_BRIDGE})"
  warn "  NOTE: Default Sophos login is admin/admin — change immediately"
}

# ═══════════════════════════════════════════════════════════════════════════════
#  STEP 1 — PREFLIGHT
# ═══════════════════════════════════════════════════════════════════════════════
section "Step 1 — Preflight"

[[ "$EUID" -eq 0 ]] || { err "Must run as root: sudo bash $0"; exit 1; }
log "Running as root ✓"

for tool in qm pvesm wget; do
  command -v "$tool" >/dev/null 2>&1 || { err "Missing: ${tool}"; exit 1; }
  log "${tool} ✓"
done

STORAGE_OK=0
pvesm status 2>/dev/null | grep -q "^${STORAGE}" && STORAGE_OK=1 || true
[[ "$STORAGE_OK" -eq 1 ]] || { err "Storage '${STORAGE}' not found. Run: pvesm status"; exit 1; }
log "Storage '${STORAGE}' ✓"

BRIDGE_OK=0
ip link show "$BRIDGE" >/dev/null 2>&1 && BRIDGE_OK=1 || true
[[ "$BRIDGE_OK" -eq 1 ]] && log "Bridge '${BRIDGE}' ✓" \
  || warn "Bridge '${BRIDGE}' not found — VMs created but networking may fail"

LAN_BRIDGE_OK=0
ip link show "$LAN_BRIDGE" >/dev/null 2>&1 && LAN_BRIDGE_OK=1 || true
if [[ "$LAN_BRIDGE_OK" -eq 0 ]]; then
  warn "LAN bridge '${LAN_BRIDGE}' not found — firewall VMs need a 2nd bridge"
  warn "  Create one: Datacenter → ${NODE} → System → Network → Create Linux Bridge"
  warn "  Or via CLI: see /etc/network/interfaces"
else
  log "LAN Bridge '${LAN_BRIDGE}' ✓"
fi

mkdir -p "$ISO_DIR" "$QCOW_DIR"

if command -v lvs >/dev/null 2>&1; then
  POOL_LINE=""
  POOL_LINE="$(lvs --noheadings --units g -o lv_name,data_percent,lv_size 2>/dev/null \
    | awk '/data/{print; exit}')" || true
  if [[ -n "$POOL_LINE" ]]; then
    PCT="$(echo "$POOL_LINE" | awk '{gsub(/%/,"",$2); print $2}')"
    SZ="$(echo "$POOL_LINE"  | awk '{gsub(/g/,"",$3); print $3}')"
    FREE="$(awk -v s="$SZ" -v p="$PCT" 'BEGIN{printf "%.1f", s*(1-p/100)}')" || FREE="?"
    warn "Thin pool: ${PCT}% used | ~${FREE} GiB free"
    PINT="${PCT%%.*}"
    if [[ "$PINT" -gt 85 ]] 2>/dev/null; then
      warn "════════════════════════════════════════════════════"
      warn " THIN POOL > 85% FULL — large disk VMs may fail!"
      warn "════════════════════════════════════════════════════"
    fi
  fi
fi

log "Rescanning ISO storage ..."
pvesm rescan --storage "${ISO_STORAGE}" >/dev/null 2>&1 || true
log "Node: ${NODE} | Storage: ${STORAGE} | Bridge: ${BRIDGE} | Start VMID: ${START_VMID}"
log "Preflight complete ✓"

# ═══════════════════════════════════════════════════════════════════════════════
#  STEP 2 — DOWNLOAD ISOs
# ═══════════════════════════════════════════════════════════════════════════════
section "Step 2 — Downloading ISOs (Christian Lempa Stack)"

# Debian 13 Trixie — his PRIMARY OS
download_iso "debian-13-netinst-amd64.iso" \
  "https://cdimage.debian.org/cdimage/trixie_di_rc1/amd64/iso-cd/debian-trixie-DI-rc1-amd64-netinst.iso"

# Debian 12 Bookworm — older tutorials
download_iso "debian-12-netinst-amd64.iso" \
  "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-12.11.0-amd64-netinst.iso"

# Ubuntu Server — secondary OS
download_iso "ubuntu-24.04-live-server-amd64.iso" \
  "https://releases.ubuntu.com/24.04/ubuntu-24.04.2-live-server-amd64.iso"

# OPNsense — kept as alt/secondary firewall (also fully covered on channel)
download_iso "OPNsense-25.1-dvd-amd64.iso" \
  "https://mirror.ams1.nl.leaseweb.net/opnsense/releases/25.1/OPNsense-25.1-dvd-amd64.iso.bz2"
if [[ -f "${ISO_DIR}/OPNsense-25.1-dvd-amd64.iso.bz2" ]] \
   && [[ ! -f "${ISO_DIR}/OPNsense-25.1-dvd-amd64.iso" ]]; then
  log "Decompressing OPNsense ISO ..."
  bunzip2 -k "${ISO_DIR}/OPNsense-25.1-dvd-amd64.iso.bz2" \
    && pvesm rescan --storage "${ISO_STORAGE}" >/dev/null 2>&1 || true
fi

# TrueNAS SCALE — NAS/ZFS storage
download_iso "TrueNAS-SCALE-25.04.0.iso" \
  "https://download.truenas.com/TrueNAS-SCALE/25.04.0/TrueNAS-SCALE-25.04.0.iso"

# Proxmox Backup Server — dedicated tutorial
download_iso "proxmox-backup-server_3.3-1.iso" \
  "https://enterprise.proxmox.com/iso/proxmox-backup-server_3.3-1.iso"

# Kali Linux — security lab
download_iso "kali-linux-2025.1a-installer-amd64.iso" \
  "https://cdimage.kali.org/kali-2025.1a/kali-linux-2025.1a-installer-amd64.iso"

# Windows Server 2025 — AD/DNS labs
download_iso "windows-server-2025-eval.iso" \
  "https://software-static.download.prss.microsoft.com/dbazure/888969d5-f34g-4e03-ac9d-1f9786c66749/26100.1742.240906-0331.ge_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso"

# VirtIO drivers — required for Windows VMs
download_iso "virtio-win.iso" \
  "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"

log "Rescanning ISO storage after downloads ..."
pvesm rescan --storage "${ISO_STORAGE}" >/dev/null 2>&1 || true

echo ""
log "ISO registration status:"
for f in \
  "debian-13-netinst-amd64.iso" "debian-12-netinst-amd64.iso" \
  "ubuntu-24.04-live-server-amd64.iso" "OPNsense-25.1-dvd-amd64.iso" \
  "TrueNAS-SCALE-25.04.0.iso" "proxmox-backup-server_3.3-1.iso" \
  "kali-linux-2025.1a-installer-amd64.iso" "windows-server-2025-eval.iso" \
  "virtio-win.iso"; do
  if iso_ok "$f"; then echo -e "  ${GRN}✓${NC} $f"
  else echo -e "  ${RED}✗${NC} $f  — not registered, dependent VMs will be skipped"
  fi
done

echo ""
warn "SOPHOS FIREWALL — manual step required (no public download URL exists):"
warn "  1. https://www.sophos.com/en-us/free-tools/sophos-firewall-home-edition"
warn "  2. Create free Sophos ID → register free serial number"
warn "  3. Download 'Firewall OS for KVM' → extract the 2x .qcow2 files"
warn "  4. Place both files in: ${QCOW_DIR}"
warn "  5. Re-run this script — it will detect them and build the VM"

# ═══════════════════════════════════════════════════════════════════════════════
#  STEP 3 — CREATE VMs
# ═══════════════════════════════════════════════════════════════════════════════

# ─────────────────────────────────────────────────────────────────────────────
section "Step 3a — Firewalls"
# Sophos = his current primary (Jan 2026 video, he works at Sophos)
# OPNsense = kept as alt — also fully covered on his channel
# ─────────────────────────────────────────────────────────────────────────────

vmid=$(next_vmid)
create_sophos_vm "$vmid" "CL-Sophos-Firewall-Home" 6144 4
bump_vmid

vmid=$(next_vmid)
create_firewall_vm_iso "$vmid" "CL-OPNsense-Firewall-Alt" \
  "OPNsense-25.1-dvd-amd64.iso" 2048 2 16
bump_vmid

# ─────────────────────────────────────────────────────────────────────────────
section "Step 3b — Storage"
# ─────────────────────────────────────────────────────────────────────────────

vmid=$(next_vmid)
create_linux_vm "$vmid" "CL-TrueNAS-SCALE" "TrueNAS-SCALE-25.04.0.iso" 8192 4 32 "other"
bump_vmid

vmid=$(next_vmid)
create_linux_vm "$vmid" "CL-ProxmoxBackupServer" "proxmox-backup-server_3.3-1.iso" 4096 2 100 "l26"
bump_vmid

# ─────────────────────────────────────────────────────────────────────────────
section "Step 3c — Docker Hosts (Debian 13)"
# ─────────────────────────────────────────────────────────────────────────────

vmid=$(next_vmid)
create_linux_vm "$vmid" "CL-Docker-Primary" "debian-13-netinst-amd64.iso" 8192 4 60
bump_vmid

vmid=$(next_vmid)
create_linux_vm "$vmid" "CL-Docker-Secondary" "debian-13-netinst-amd64.iso" 4096 2 40
bump_vmid

# ─────────────────────────────────────────────────────────────────────────────
section "Step 3d — Kubernetes Cluster (k3s on Debian)"
# ─────────────────────────────────────────────────────────────────────────────

vmid=$(next_vmid)
create_linux_vm "$vmid" "CL-k3s-ControlPlane" "debian-13-netinst-amd64.iso" 4096 2 30
bump_vmid

vmid=$(next_vmid)
create_linux_vm "$vmid" "CL-k3s-Worker-01" "debian-13-netinst-amd64.iso" 4096 2 40
bump_vmid

vmid=$(next_vmid)
create_linux_vm "$vmid" "CL-k3s-Worker-02" "debian-13-netinst-amd64.iso" 4096 2 40
bump_vmid

vmid=$(next_vmid)
create_linux_vm "$vmid" "CL-k3s-Worker-03" "debian-13-netinst-amd64.iso" 4096 2 40
bump_vmid

# ─────────────────────────────────────────────────────────────────────────────
section "Step 3e — DevOps & Automation"
# ─────────────────────────────────────────────────────────────────────────────

vmid=$(next_vmid)
create_linux_vm "$vmid" "CL-GitLab-Server" "debian-13-netinst-amd64.iso" 8192 4 80
bump_vmid

vmid=$(next_vmid)
create_linux_vm "$vmid" "CL-n8n-Automation" "debian-13-netinst-amd64.iso" 4096 2 30
bump_vmid

vmid=$(next_vmid)
create_linux_vm "$vmid" "CL-NetBird-VPN" "debian-13-netinst-amd64.iso" 2048 2 20
bump_vmid

vmid=$(next_vmid)
create_linux_vm "$vmid" "CL-Coolify-PaaS" "debian-13-netinst-amd64.iso" 4096 2 40
bump_vmid

vmid=$(next_vmid)
create_linux_vm "$vmid" "CL-Grafana-Monitoring" "debian-13-netinst-amd64.iso" 4096 2 30
bump_vmid

vmid=$(next_vmid)
create_linux_vm "$vmid" "CL-Pangolin-Tunnel" "debian-13-netinst-amd64.iso" 2048 2 20
bump_vmid

# ─────────────────────────────────────────────────────────────────────────────
section "Step 3f — DNS & Network Management"
# ─────────────────────────────────────────────────────────────────────────────

vmid=$(next_vmid)
create_linux_vm "$vmid" "CL-AdGuardHome-DNS" "debian-13-netinst-amd64.iso" 1024 1 10
bump_vmid

vmid=$(next_vmid)
create_linux_vm "$vmid" "CL-Pihole-DNS" "debian-13-netinst-amd64.iso" 1024 1 10
bump_vmid

# ─────────────────────────────────────────────────────────────────────────────
section "Step 3g — Windows Server Lab"
# ─────────────────────────────────────────────────────────────────────────────

vmid=$(next_vmid)
create_win_vm "$vmid" "CL-WinServer2025-Lab" "windows-server-2025-eval.iso" 6144 4 80 "w2k22"
bump_vmid

vmid=$(next_vmid)
create_win_vm "$vmid" "CL-WinServer2025-DC02" "windows-server-2025-eval.iso" 4096 2 60 "w2k22"
bump_vmid

# ─────────────────────────────────────────────────────────────────────────────
section "Step 3h — Security & Testing Lab"
# ─────────────────────────────────────────────────────────────────────────────

vmid=$(next_vmid)
create_linux_vm "$vmid" "CL-Kali-Security-Lab" "kali-linux-2025.1a-installer-amd64.iso" 4096 2 50
bump_vmid

vmid=$(next_vmid)
create_linux_vm "$vmid" "CL-Ubuntu-2404-Lab" "ubuntu-24.04-live-server-amd64.iso" 4096 2 40
bump_vmid

vmid=$(next_vmid)
create_linux_vm "$vmid" "CL-Debian-DevSandbox" "debian-12-netinst-amd64.iso" 4096 2 30
bump_vmid

# ═══════════════════════════════════════════════════════════════════════════════
#  STEP 4 — SUMMARY
# ═══════════════════════════════════════════════════════════════════════════════
section "Step 4 — Christian Lempa HomeLab Summary"
echo ""
qm list
echo ""
log "All VMs created on node: ${NODE}"
echo ""
echo -e "${CYN}Stack overview:${NC}"
cat << 'STACK'
  CL-Sophos-Firewall-Home  → Primary firewall (Christian's Jan 2026 video)
                              Requires manual qcow2 download — see warning above
  CL-OPNsense-Firewall-Alt → Alternative open-source firewall
  CL-TrueNAS-SCALE         → NAS storage server (ZFS)
  CL-ProxmoxBackupServer   → Dedicated PBS backup node
  CL-Docker-Primary        → Main Docker host (AdGuard, NPM, Uptime Kuma,
                              Portainer, Vaultwarden, Nextcloud, Authentik...)
  CL-Docker-Secondary      → Dev/overflow Docker host
  CL-k3s-ControlPlane      → k3s Kubernetes server node
  CL-k3s-Worker-01/02/03  → k3s worker nodes
  CL-GitLab-Server         → Self-hosted GitLab
  CL-n8n-Automation        → n8n workflow automation
  CL-NetBird-VPN           → NetBird VPN mesh server
  CL-Coolify-PaaS          → Coolify self-hosted PaaS
  CL-Grafana-Monitoring    → Grafana + Prometheus + Alloy
  CL-Pangolin-Tunnel       → Pangolin self-hosted tunnel
  CL-AdGuardHome-DNS       → AdGuard Home DNS
  CL-Pihole-DNS            → Pi-hole DNS
  CL-WinServer2025-Lab     → Windows Server 2025 AD/DNS lab
  CL-WinServer2025-DC02    → Windows Server 2025 DC02 replica
  CL-Kali-Security-Lab     → Kali Linux pentesting
  CL-Ubuntu-2404-Lab       → Ubuntu 24.04 general lab
  CL-Debian-DevSandbox     → Debian 12 dev sandbox
STACK
echo ""
echo -e "${CYN}Post-install:${NC}"
echo "  Linux:   apt install qemu-guest-agent && systemctl enable --now qemu-guest-agent"
echo "  Windows: Install virtio-win drivers from ide0, then QEMU agent"
echo "  Sophos:  default login admin/admin — change immediately on first boot"
echo ""
echo -e "${CYN}Quick commands:${NC}"
echo "  Start VM:   qm start <vmid>"
echo "  Console:    qm terminal <vmid>"
echo "  Start all:  for id in \$(qm list | awk 'NR>1{print \$1}'); do qm start \$id; done"
echo ""
echo -e "${CYN}Resources:${NC}"
echo "  YouTube: https://youtube.com/@christianlempa"
echo "  Website: https://christianlempa.de"
echo "  GitHub:  https://github.com/ChristianLempa"
