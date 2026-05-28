#Requires -Version 5.1
<#
.SYNOPSIS
    Creates 9 VMs on VMware Workstation Pro 17 — builds VMX and VMDK only, does NOT power them on.
    3x Windows Server 2022  |  3x Rocky Linux 9.0  |  3x Ubuntu 22.04 Live Server

.NOTES
    Run as Administrator in Windows Terminal:
        Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
        & "$env:USERPROFILE\Downloads\Create-SchoolVMs.ps1"

    ISOs required in Downloads with EXACT filenames:
        Windows Server 2022 Build 20348.iso
        Rocky-9-0-x86_64-dvd.iso
        ubuntu-22.04-live-server-prealpha1-x64.iso

    VM SPECS:
        Windows Server 2022     -> 60 GB | 2048 MB RAM | 2 CPU | e1000 NAT
        Rocky Linux 9.0         -> 20 GB | 1024 MB RAM | 1 CPU | e1000 NAT
        Ubuntu 22.04 Server     -> 20 GB | 1024 MB RAM | 1 CPU | e1000 NAT

    INSTALL NOTES:
        Windows Server 2022  : Standard graphical setup wizard.
        Rocky Linux 9.0      : Anaconda graphical installer (single DVD ISO).
        Ubuntu 22.04 Server  : Subiquity text/TUI installer (live server ISO).
          All three: disconnect the ISO before rebooting after install:
          VM -> Removable Devices -> CD/DVD (IDE 1:0) -> Disconnect

    DISK / HARDWARE NOTES:
        - virtualHW.version = "14" for all VMs — modern AHCI/IDE support.
        - ide0:0.deviceType = "disk" — plain ATA disk, not scsi-hardDisk.
        - vdiskmanager -a ide matches ide0:0 bus type end-to-end.
        - NIC is e1000 — inbox driver on all three install media.
        - bios.bootOrder = "cdrom,hdd" + bios.bootDelay = "2000" prevents
          network-boot timeout causing "no boot device found".
        - ethernet0.bootProto = "none" disables PXE on the NIC.
#>

# ============================================================
#  CONFIGURATION
# ============================================================
$VmBasePath   = "$env:USERPROFILE\VMs\SchoolVMs"
$DownloadsDir = "$env:USERPROFILE\Downloads"

$VmDefs = @(
    @{ Name="WinServer2022-1"; OS="win2022srv"; IsoKey="2022";   RAM=2048; Disk=60; CPU=2 },
    @{ Name="WinServer2022-2"; OS="win2022srv"; IsoKey="2022";   RAM=2048; Disk=60; CPU=2 },
    @{ Name="WinServer2022-3"; OS="win2022srv"; IsoKey="2022";   RAM=2048; Disk=60; CPU=2 },
    @{ Name="Rocky9-1";        OS="rocky9";     IsoKey="rocky9"; RAM=1024; Disk=20; CPU=1 },
    @{ Name="Rocky9-2";        OS="rocky9";     IsoKey="rocky9"; RAM=1024; Disk=20; CPU=1 },
    @{ Name="Rocky9-3";        OS="rocky9";     IsoKey="rocky9"; RAM=1024; Disk=20; CPU=1 },
    @{ Name="Ubuntu2204-1";    OS="ubuntu22";   IsoKey="ubu22";  RAM=1024; Disk=20; CPU=1 },
    @{ Name="Ubuntu2204-2";    OS="ubuntu22";   IsoKey="ubu22";  RAM=1024; Disk=20; CPU=1 },
    @{ Name="Ubuntu2204-3";    OS="ubuntu22";   IsoKey="ubu22";  RAM=1024; Disk=20; CPU=1 }
)

$ExactIsoNames = @{
    "2022"   = "Windows Server 2022 Build 20348.iso"
    "rocky9" = "Rocky-9-0-x86_64-dvd.iso"
    "ubu22"  = "ubuntu-22.04-live-server-prealpha1-x64.iso"
}

# ============================================================
#  HELPERS
# ============================================================
function Write-OK  ($msg) { Write-Host "  [OK]  $msg" -ForegroundColor Green   }
function Write-INF ($msg) { Write-Host "  [-->] $msg" -ForegroundColor Cyan    }
function Write-ERR ($msg) { Write-Host "  [!!]  $msg" -ForegroundColor Red     }
function Write-WRN ($msg) { Write-Host "  [**]  $msg" -ForegroundColor Yellow  }
function Write-HDR ($msg) {
    Write-Host ""
    Write-Host ("=" * 64) -ForegroundColor Yellow
    Write-Host "  $msg" -ForegroundColor Yellow
    Write-Host ("=" * 64) -ForegroundColor Yellow
}

# ============================================================
#  STEP 1 — LOCATE VMWARE BINARIES
# ============================================================
Write-HDR "Step 1: Locating VMware Workstation Pro 17"

$vmwarePaths = @(
    "C:\Program Files (x86)\VMware\VMware Workstation\vmware.exe",
    "C:\Program Files\VMware\VMware Workstation\vmware.exe"
)
$vdiskPaths = @(
    "C:\Program Files (x86)\VMware\VMware Workstation\vmware-vdiskmanager.exe",
    "C:\Program Files\VMware\VMware Workstation\vmware-vdiskmanager.exe"
)

$vmwareExe = $vmwarePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
$vdiskMgr  = $vdiskPaths  | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $vmwareExe) {
    Write-ERR "vmware.exe not found. Is VMware Workstation Pro 17 installed?"
    exit 1
}
Write-OK "vmware.exe   : $vmwareExe"
if ($vdiskMgr) { Write-OK "vdiskmanager : $vdiskMgr" }
else            { Write-WRN "vdiskmanager not found — VMware will create disks on first boot." }

# ============================================================
#  STEP 2 — VERIFY ISOs
# ============================================================
Write-HDR "Step 2: Verifying ISO files in Downloads"

$IsoMap = @{}
foreach ($key in $ExactIsoNames.Keys) {
    $fullPath = Join-Path $DownloadsDir $ExactIsoNames[$key]
    if (Test-Path $fullPath) {
        $sizeMB = [math]::Round((Get-Item $fullPath).Length / 1MB, 1)
        Write-OK "$($ExactIsoNames[$key])  ($sizeMB MB)"
        $IsoMap[$key] = $fullPath
    } else {
        Write-ERR "Missing: $fullPath"
        Write-ERR "All 3 ISOs must be in Downloads with exact filenames listed above."
        exit 1
    }
}

# ============================================================
#  STEP 3 — VM STORAGE FOLDER
# ============================================================
Write-HDR "Step 3: Preparing VM storage folder"

if (-not (Test-Path $VmBasePath)) {
    New-Item -ItemType Directory -Path $VmBasePath -Force | Out-Null
    Write-OK "Created: $VmBasePath"
} else {
    Write-OK "Using:   $VmBasePath"
}

# ============================================================
#  FUNCTION — Build clean VMX + VMDK for one VM
#
#  ALL THREE OS TYPES use virtualHW.version = "14" and e1000 NIC.
#
#  WINDOWS SERVER 2022:
#    guestOS = "windows2019srvNext-64"
#    Disk: 60 GB IDE
#
#  ROCKY LINUX 9.0:
#    guestOS = "centos-64"  (Rocky is RHEL-compatible; VMware has no
#      dedicated Rocky type — centos-64 is the correct family match)
#    Disk: 20 GB IDE
#
#  UBUNTU 22.04 SERVER:
#    guestOS = "ubuntu-64"
#    Disk: 20 GB IDE
#
#  DISK CHAIN — must all agree across all OS types:
#    vdiskmanager -a ide         disk geometry: IDE
#    ide0:0.present              IDE bus, channel 0, device 0
#    ide0:0.deviceType = "disk"  plain ATA hard disk (not scsi-hardDisk)
#    bios.bootOrder = "cdrom,hdd"  boot ISO first, then disk
#    ethernet0.bootProto = "none"  PXE disabled — prevents "no boot found"
# ============================================================
function New-VMwareVM ($def, $isoPath) {
    $vmDir = Join-Path $VmBasePath $def.Name
    $vmx   = Join-Path $vmDir "$($def.Name).vmx"
    $vmdk  = Join-Path $vmDir "$($def.Name).vmdk"

    # Remove stale VMX and lock folders from prior runs
    if (Test-Path $vmx) {
        Write-INF "Deleting old VMX — rebuilding clean for $($def.Name)"
        Remove-Item $vmx -Force -ErrorAction SilentlyContinue
    }
    Get-ChildItem -Path $vmDir -Filter "*.lck" -Directory -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    New-Item -ItemType Directory -Path $vmDir -Force | Out-Null

    $guestOS = switch ($def.OS) {
        "win2022srv" { "windows2019srvNext-64" }
        "rocky9"     { "centos-64"             }
        "ubuntu22"   { "ubuntu-64"             }
        default      { "other-64"              }
    }

    # Create virtual disk — adapter MUST be ide to match ide0:0 bus
    if (-not (Test-Path $vmdk)) {
        if ($vdiskMgr) {
            $diskMB = $def.Disk * 1024
            Write-INF "Creating $($def.Disk) GB IDE virtual disk..."
            & $vdiskMgr -c -s "${diskMB}MB" -a ide -t 0 "$vmdk" 2>&1 | Out-Null
            if (Test-Path $vmdk) { Write-OK "Disk created: $vmdk" }
            else                  { Write-WRN "VMware will create the disk on first boot." }
        } else {
            Write-WRN "No vdiskmanager — VMware creates the $($def.Disk) GB disk on first boot."
        }
    } else {
        Write-INF "Existing disk kept: $vmdk"
    }

    $ramMB = $def.RAM
    $cpus  = $def.CPU

    $vmxContent = @"
.encoding = "UTF-8"
config.version = "8"
virtualHW.version = "14"
displayName = "$($def.Name)"
guestOS = "$guestOS"

numvcpus = "$cpus"
memsize = "$ramMB"

ide0:0.present = "TRUE"
ide0:0.fileName = "$($def.Name).vmdk"
ide0:0.deviceType = "disk"
ide0:0.mode = "persistent"
ide0:0.startConnected = "TRUE"

ide1:0.present = "TRUE"
ide1:0.fileName = "$isoPath"
ide1:0.deviceType = "cdrom-image"
ide1:0.startConnected = "TRUE"
ide1:0.autodetect = "FALSE"

ethernet0.present = "TRUE"
ethernet0.connectionType = "nat"
ethernet0.virtualDev = "e1000"
ethernet0.addressType = "generated"
ethernet0.wakeOnPcktRcv = "FALSE"
ethernet0.startConnected = "TRUE"
ethernet0.pciSlotNumber = "32"
ethernet0.bootProto = "none"

usb.present = "TRUE"
ehci.present = "TRUE"
sound.present = "FALSE"
floppy0.present = "FALSE"

tools.syncTime = "TRUE"

bios.bootOrder = "cdrom,hdd"
bios.bootDelay = "2000"
bios.hddOrder = "ide0:0"
bios.cdromOrder = "ide1:0"

extendedConfigFile = "$($def.Name).vmxf"
"@

    Set-Content -Path $vmx -Value $vmxContent -Encoding UTF8
    Write-OK "VMX written: $vmx"
    return $vmx
}

# ============================================================
#  FUNCTION — Rocky Linux 9.0 Boot Repair
#  Call this if a Rocky VM boots to a GRUB2 error or kernel
#  panic after install.
# ============================================================
function Repair-RockyBoot {
    param(
        [ValidateSet("Rocky9-1","Rocky9-2","Rocky9-3")]
        [string]$VMName = "Rocky9-1"
    )

    $vmDir = Join-Path $VmBasePath $VMName
    $vmx   = Join-Path $vmDir "$VMName.vmx"
    $iso   = $IsoMap["rocky9"]

    if (-not (Test-Path $vmx)) {
        Write-ERR "$VMName VMX not found at $vmx — run the main script first."
        return
    }

    Write-HDR "Rocky Linux 9.0 Boot Repair — Rescue Mode  ($VMName)"
    Write-INF "Patching VMX to boot DVD ISO in rescue mode..."

    $content = Get-Content $vmx -Raw

    if ($content -notmatch 'ide1:0') {
        Add-Content $vmx "`nide1:0.present = `"TRUE`""
        Add-Content $vmx "ide1:0.fileName = `"$iso`""
        Add-Content $vmx "ide1:0.deviceType = `"cdrom-image`""
        Add-Content $vmx "ide1:0.startConnected = `"TRUE`""
        Add-Content $vmx "ide1:0.autodetect = `"FALSE`""
    } else {
        $content = $content -replace '(?m)^ide1:0\.fileName\s*=\s*".*?"',       "ide1:0.fileName = `"$iso`""
        $content = $content -replace '(?m)^ide1:0\.startConnected\s*=\s*".*?"', 'ide1:0.startConnected = "TRUE"'
    }

    $content = $content -replace 'bios\.bootOrder\s*=\s*".*?"', 'bios.bootOrder = "cdrom,hdd"'
    Set-Content $vmx $content -Encoding UTF8

    Write-OK "VMX patched — DVD ISO boots first."
    Write-INF "Launching $VMName into rescue mode now..."
    Start-Process -FilePath $vmwareExe -ArgumentList "-x `"$vmx`"" | Out-Null

    Write-Host ""
    Write-Host ("=" * 64) -ForegroundColor Magenta
    Write-Host "  INSIDE THE ROCKY 9.0 INSTALLER — DO THIS:" -ForegroundColor Magenta
    Write-Host ("=" * 64) -ForegroundColor Magenta
    Write-Host ""
    Write-Host "  1. At the GRUB boot menu, select:" -ForegroundColor White
    Write-Host "       Troubleshooting -> Rescue a Rocky Linux system" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  2. Choose 'Continue' to mount your install at /mnt/sysimage" -ForegroundColor White
    Write-Host ""
    Write-Host "  3. At the rescue shell, run:" -ForegroundColor White
    Write-Host ""
    Write-Host "       chroot /mnt/sysimage" -ForegroundColor Green
    Write-Host "       grub2-install /dev/sda" -ForegroundColor Green
    Write-Host "       grub2-mkconfig -o /boot/grub2/grub.cfg" -ForegroundColor Green
    Write-Host "       exit" -ForegroundColor Green
    Write-Host "       reboot" -ForegroundColor Green
    Write-Host ""
    Write-Host "  4. After reboot, disconnect the ISO:" -ForegroundColor White
    Write-Host "     VM -> Removable Devices -> CD/DVD (IDE 1:0) -> Disconnect" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  To repair a different VM:" -ForegroundColor DarkGray
    Write-Host "    Repair-RockyBoot -VMName Rocky9-2" -ForegroundColor Cyan
    Write-Host "    Repair-RockyBoot -VMName Rocky9-3" -ForegroundColor Cyan
    Write-Host ""
}

# ============================================================
#  FUNCTION — Ubuntu 22.04 Boot Repair
#  Call this if an Ubuntu VM boots to a GRUB error after install.
# ============================================================
function Repair-UbuntuBoot {
    param(
        [ValidateSet("Ubuntu2204-1","Ubuntu2204-2","Ubuntu2204-3")]
        [string]$VMName = "Ubuntu2204-1"
    )

    $vmDir = Join-Path $VmBasePath $VMName
    $vmx   = Join-Path $vmDir "$VMName.vmx"
    $iso   = $IsoMap["ubu22"]

    if (-not (Test-Path $vmx)) {
        Write-ERR "$VMName VMX not found at $vmx — run the main script first."
        return
    }

    Write-HDR "Ubuntu 22.04 Boot Repair — Rescue Mode  ($VMName)"
    Write-INF "Patching VMX to boot live server ISO in rescue mode..."

    $content = Get-Content $vmx -Raw

    if ($content -notmatch 'ide1:0') {
        Add-Content $vmx "`nide1:0.present = `"TRUE`""
        Add-Content $vmx "ide1:0.fileName = `"$iso`""
        Add-Content $vmx "ide1:0.deviceType = `"cdrom-image`""
        Add-Content $vmx "ide1:0.startConnected = `"TRUE`""
        Add-Content $vmx "ide1:0.autodetect = `"FALSE`""
    } else {
        $content = $content -replace '(?m)^ide1:0\.fileName\s*=\s*".*?"',       "ide1:0.fileName = `"$iso`""
        $content = $content -replace '(?m)^ide1:0\.startConnected\s*=\s*".*?"', 'ide1:0.startConnected = "TRUE"'
    }

    $content = $content -replace 'bios\.bootOrder\s*=\s*".*?"', 'bios.bootOrder = "cdrom,hdd"'
    Set-Content $vmx $content -Encoding UTF8

    Write-OK "VMX patched — live server ISO boots first."
    Write-INF "Launching $VMName into rescue mode now..."
    Start-Process -FilePath $vmwareExe -ArgumentList "-x `"$vmx`"" | Out-Null

    Write-Host ""
    Write-Host ("=" * 64) -ForegroundColor Magenta
    Write-Host "  INSIDE THE UBUNTU 22.04 INSTALLER — DO THIS:" -ForegroundColor Magenta
    Write-Host ("=" * 64) -ForegroundColor Magenta
    Write-Host ""
    Write-Host "  1. At the boot menu, select:" -ForegroundColor White
    Write-Host "       Try or Install Ubuntu Server" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  2. At the Subiquity menu, drop to a shell:" -ForegroundColor White
    Write-Host "       Help -> Enter shell" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  3. At the shell, run:" -ForegroundColor White
    Write-Host ""
    Write-Host "       mount /dev/sda2 /mnt         # or sda1 if no EFI partition" -ForegroundColor Green
    Write-Host "       mount --bind /dev  /mnt/dev" -ForegroundColor Green
    Write-Host "       mount --bind /proc /mnt/proc" -ForegroundColor Green
    Write-Host "       mount --bind /sys  /mnt/sys" -ForegroundColor Green
    Write-Host "       chroot /mnt" -ForegroundColor Green
    Write-Host "       grub-install /dev/sda" -ForegroundColor Green
    Write-Host "       update-grub" -ForegroundColor Green
    Write-Host "       exit && reboot" -ForegroundColor Green
    Write-Host ""
    Write-Host "  4. After reboot, disconnect the ISO:" -ForegroundColor White
    Write-Host "     VM -> Removable Devices -> CD/DVD (IDE 1:0) -> Disconnect" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  To repair a different VM:" -ForegroundColor DarkGray
    Write-Host "    Repair-UbuntuBoot -VMName Ubuntu2204-2" -ForegroundColor Cyan
    Write-Host "    Repair-UbuntuBoot -VMName Ubuntu2204-3" -ForegroundColor Cyan
    Write-Host ""
}

# ============================================================
#  STEP 4 — MAIN: CREATE AND LAUNCH ALL 9 VMs ONE BY ONE
# ============================================================
Write-HDR "Step 4: Building all 9 VMs"

$total   = $VmDefs.Count
$current = 0
$results = @()

foreach ($def in $VmDefs) {
    $current++

    $isoPath  = $IsoMap[$def.IsoKey]
    $isoLabel = $ExactIsoNames[$def.IsoKey]

    Write-Host ""
    Write-Host ("─" * 64) -ForegroundColor DarkGray
    Write-Host "  VM $current of $total  :  $($def.Name)" -ForegroundColor White
    Write-Host "  Disk: $($def.Disk) GB  |  RAM: $($def.RAM) MB  |  CPU: $($def.CPU)  |  NIC: e1000 NAT  |  IDE" -ForegroundColor DarkGray
    Write-Host "  ISO : $isoLabel" -ForegroundColor DarkGray
    Write-Host ("─" * 64) -ForegroundColor DarkGray

    try {
        $vmxPath = New-VMwareVM $def $isoPath

        $results += [pscustomobject]@{
            "#"    = $current
            VM     = $def.Name
            Disk   = "$($def.Disk) GB (IDE)"
            RAM    = "$($def.RAM) MB"
            CPU    = $def.CPU
            Status = "Launched"
        }
    } catch {
        Write-ERR "Error on $($def.Name): $_"
        $results += [pscustomobject]@{
            "#"    = $current
            VM     = $def.Name
            Disk   = "$($def.Disk) GB"
            RAM    = "$($def.RAM) MB"
            CPU    = $def.CPU
            Status = "FAILED: $_"
        }
    }


}

# ============================================================
#  STEP 5 — SUMMARY
# ============================================================
Write-HDR "Done — All 9 VMs Created"
$results | Format-Table -AutoSize

Write-Host "  VM files : $VmBasePath" -ForegroundColor Cyan
Write-Host ""
Write-Host "  VMs are built but NOT powered on." -ForegroundColor Yellow
Write-Host "  To start a VM, open VMware Workstation and double-click it, or run:" -ForegroundColor Yellow
Write-Host '    & "$vmwareExe" -x "<path-to-vm>.vmx"' -ForegroundColor Cyan
Write-Host ""
Write-Host "  When you start a VM it will boot from the ISO automatically." -ForegroundColor Yellow
Write-Host ""
Write-Host "  WINDOWS SERVER 2022 : Graphical setup wizard." -ForegroundColor Yellow
Write-Host "    Boots from ISO -> setup wizard -> install to disk." -ForegroundColor Yellow
Write-Host ""
Write-Host "  ROCKY LINUX 9.0 : Anaconda graphical installer (DVD ISO)." -ForegroundColor Yellow
Write-Host "    Boots from ISO -> graphical installer -> install to disk." -ForegroundColor Yellow
Write-Host "    After install, disconnect the ISO before rebooting:" -ForegroundColor Yellow
Write-Host "    VM -> Removable Devices -> CD/DVD (IDE 1:0) -> Disconnect" -ForegroundColor Cyan
Write-Host ""
Write-Host "  UBUNTU 22.04 SERVER : Subiquity TUI installer (live server ISO)." -ForegroundColor Yellow
Write-Host "    Boots from ISO -> text/TUI installer -> install to disk." -ForegroundColor Yellow
Write-Host "    After install, disconnect the ISO before rebooting:" -ForegroundColor Yellow
Write-Host "    VM -> Removable Devices -> CD/DVD (IDE 1:0) -> Disconnect" -ForegroundColor Cyan
Write-Host ""
Write-Host "  If a Rocky VM boots to a GRUB2 error after install, run:" -ForegroundColor Magenta
Write-Host "    Repair-RockyBoot                 # fixes Rocky9-1" -ForegroundColor Cyan
Write-Host "    Repair-RockyBoot -VMName Rocky9-2" -ForegroundColor Cyan
Write-Host "    Repair-RockyBoot -VMName Rocky9-3" -ForegroundColor Cyan
Write-Host ""
Write-Host "  If an Ubuntu VM boots to a GRUB error after install, run:" -ForegroundColor Magenta
Write-Host "    Repair-UbuntuBoot                   # fixes Ubuntu2204-1" -ForegroundColor Cyan
Write-Host "    Repair-UbuntuBoot -VMName Ubuntu2204-2" -ForegroundColor Cyan
Write-Host "    Repair-UbuntuBoot -VMName Ubuntu2204-3" -ForegroundColor Cyan
Write-Host "  (functions are already loaded — just type and press Enter)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  To delete a VM:" -ForegroundColor DarkGray
Write-Host "    Remove-Item -Recurse -Force `"$VmBasePath\VMName`"" -ForegroundColor DarkGray
Write-Host ""
