#Requires -Version 5.1
<#
.SYNOPSIS
    Creates 9 VMs in VMware Workstation — Generic K-12 School District 2007.
    Builds each VM folder, creates VMDK disks, writes VMX config,
    attaches ISOs, and powers them all on automatically.

    VM LINEUP:
        1.  DC01-Primary       Windows Server 2003 R2 x86     Primary DC / AD / DNS / DHCP
        2.  DC02-Secondary     Windows Server 2003 R2 x86     Secondary DC / GPO
        3.  FS01-Files         Windows Server 2003 R2 x86     File server / student shares
        4.  PS01-Print         Windows Server 2003 R2 x86     Print server / WSUS
        5.  WS-Student01       Windows XP Professional SP3    Student workstation
        6.  WS-Staff01         Windows XP Professional SP3    Staff / teacher workstation
        7.  NW65-Auth          Novell NetWare 6.5              Legacy NDS auth node
        8.  Ubuntu704-Client   Ubuntu 7.04 Feisty Fawn        Linux client / thin client alt
        9.  pfSense12-FW       pfSense 1.2                    School firewall / router

.NOTES
    Run as Administrator in Windows Terminal:
        Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
        & "$env:USERPROFILE\Downloads\Create-SchoolVMs.ps1"

    REQUIRES: VMware Workstation Pro installed.

    ISOs required in Downloads with EXACT filenames:
        en_win_srv_2003_r2_enterprise_x86_cd1.iso
        en_win_srv_2003_r2_enterprise_x86_cd2.iso
        WindowsXP-SP3-x86.iso
        CD1-OSinstall.iso
        CD2-NWproducts.iso
        ubuntu-7.04-desktop-i386.iso
        pfSense-1.2-release-LiveCD-cdrom.iso

    Run Get-SchoolVMs-ISOs.ps1 first to download all ISOs automatically.

    AFTER INSTALL flip boot to HDD:
        Set-BootFromHDD              # all 9 VMs
        Set-BootFromHDD -VMName DC01-Primary
#>

# ============================================================
#  CONFIGURATION
# ============================================================
$VmBasePath   = "$env:USERPROFILE\VMs\K12-2007"
$DownloadsDir = "$env:USERPROFILE\Downloads"

$VmDefs = @(
    @{ Name="DC01-Primary";     GuestOS="winnetenterprise"; IsoKey="2003cd1"; IsoKey2="2003cd2"; RAM=512;  Disk=20; CPU=1 },
    @{ Name="DC02-Secondary";   GuestOS="winnetenterprise"; IsoKey="2003cd1"; IsoKey2="2003cd2"; RAM=512;  Disk=20; CPU=1 },
    @{ Name="FS01-Files";       GuestOS="winnetenterprise"; IsoKey="2003cd1"; IsoKey2="2003cd2"; RAM=512;  Disk=40; CPU=1 },
    @{ Name="PS01-Print";       GuestOS="winnetenterprise"; IsoKey="2003cd1"; IsoKey2="2003cd2"; RAM=512;  Disk=20; CPU=1 },
    @{ Name="WS-Student01";     GuestOS="winxppro";         IsoKey="xpsp3";   IsoKey2=$null;     RAM=512;  Disk=20; CPU=1 },
    @{ Name="WS-Staff01";       GuestOS="winxppro";         IsoKey="xpsp3";   IsoKey2=$null;     RAM=512;  Disk=20; CPU=1 },
    @{ Name="NW65-Auth";        GuestOS="other";            IsoKey="nw65cd1"; IsoKey2="nw65cd2"; RAM=512;  Disk=8;  CPU=1 },
    @{ Name="Ubuntu704-Client"; GuestOS="ubuntu";           IsoKey="ubu704";  IsoKey2=$null;     RAM=384;  Disk=10; CPU=1 },
    @{ Name="pfSense12-FW";     GuestOS="freebsd";          IsoKey="pfsense"; IsoKey2=$null;     RAM=256;  Disk=4;  CPU=1 }
)

$ExactIsoNames = @{
    "2003cd1" = "en_win_srv_2003_r2_enterprise_x86_cd1.iso"
    "2003cd2" = "en_win_srv_2003_r2_enterprise_x86_cd2.iso"
    "xpsp3"   = "WindowsXP-SP3-x86.iso"
    "nw65cd1" = "CD1-OSinstall.iso"
    "nw65cd2" = "CD2-NWproducts.iso"
    "ubu704"  = "ubuntu-7.04-desktop-i386.iso"
    "pfsense" = "pfSense-1.2-release-LiveCD-cdrom.iso"
}

# ============================================================
#  HELPERS
# ============================================================
function Write-OK  ($msg) { Write-Host "  [OK]  $msg" -ForegroundColor Green  }
function Write-INF ($msg) { Write-Host "  [-->] $msg" -ForegroundColor Cyan   }
function Write-ERR ($msg) { Write-Host "  [!!]  $msg" -ForegroundColor Red    }
function Write-WRN ($msg) { Write-Host "  [**]  $msg" -ForegroundColor Yellow }
function Write-HDR ($msg) {
    Write-Host ""
    Write-Host ("=" * 64) -ForegroundColor Yellow
    Write-Host "  $msg" -ForegroundColor Yellow
    Write-Host ("=" * 64) -ForegroundColor Yellow
}

# ============================================================
#  STEP 1 — LOCATE VMWARE TOOLS
# ============================================================
Write-HDR "Step 1: Locating VMware Workstation"

$vmrunPaths = @(
    "C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe",
    "C:\Program Files\VMware\VMware Workstation\vmrun.exe"
)
$vdiskPaths = @(
    "C:\Program Files (x86)\VMware\VMware Workstation\vmware-vdiskmanager.exe",
    "C:\Program Files\VMware\VMware Workstation\vmware-vdiskmanager.exe"
)

$vmrun = $vmrunPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $vmrun) {
    $found = Get-Command vmrun.exe -ErrorAction SilentlyContinue
    if ($found) { $vmrun = $found.Source }
}
if (-not $vmrun) {
    Write-ERR "vmrun.exe not found. Install VMware Workstation."
    exit 1
}

$vdiskManager = $vdiskPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $vdiskManager) {
    $found = Get-Command vmware-vdiskmanager.exe -ErrorAction SilentlyContinue
    if ($found) { $vdiskManager = $found.Source }
}
if (-not $vdiskManager) {
    Write-ERR "vmware-vdiskmanager.exe not found. Is VMware Workstation fully installed?"
    exit 1
}

Write-OK "vmrun          : $vmrun"
Write-OK "vdiskmanager   : $vdiskManager"

# ============================================================
#  STEP 2 — VERIFY ISOs
# ============================================================
Write-HDR "Step 2: Verifying ISO files"

$IsoMap = @{}
foreach ($key in $ExactIsoNames.Keys) {
    $fullPath = Join-Path $DownloadsDir $ExactIsoNames[$key]
    if (Test-Path $fullPath) {
        $sizeMB = [math]::Round((Get-Item $fullPath).Length / 1MB, 1)
        Write-OK "$($ExactIsoNames[$key])  ($sizeMB MB)"
        $IsoMap[$key] = $fullPath
    } else {
        Write-ERR "Missing: $fullPath"
        Write-ERR "Run Get-SchoolVMs-ISOs.ps1 to download all ISOs first."
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
#  FUNCTION — Build one VMware VM
#
#  Adapter / NIC choices:
#    Windows Server 2003 / XP  -> lsilogic SCSI, e1000 NIC
#    NetWare 6.5               -> buslogic SCSI, vlance NIC
#    Ubuntu / pfSense          -> lsilogic SCSI, e1000 NIC
# ============================================================
function New-VMwareVM ($def, $isoPath, $iso2Path = $null) {
    $vmName   = $def.Name
    $vmDir    = Join-Path $VmBasePath $vmName
    $vmxPath  = Join-Path $vmDir "$vmName.vmx"
    $vmdkPath = Join-Path $vmDir "$vmName.vmdk"
    $diskMB   = $def.Disk * 1024

    $isNetWare = ($def.GuestOS -eq "other")
    $scsiType  = if ($isNetWare) { "buslogic" } else { "lsilogic" }
    $nicType   = if ($isNetWare) { "vlance"   } else { "e1000"    }

    # Remove existing VM folder
    if (Test-Path $vmDir) {
        Write-INF "Removing existing VM: $vmName"
        $running = & $vmrun list 2>&1 | Where-Object { $_ -match [regex]::Escape($vmxPath) }
        if ($running) {
            & $vmrun stop $vmxPath hard 2>&1 | Out-Null
            Start-Sleep -Seconds 3
        }
        Remove-Item $vmDir -Recurse -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
    }
    New-Item -ItemType Directory -Path $vmDir -Force | Out-Null

    # Create VMDK
    Write-INF "Creating $($def.Disk) GB VMDK..."
    & $vdiskManager -c -s "${diskMB}MB" -a $scsiType -t 0 $vmdkPath 2>&1 | Out-Null
    if (-not (Test-Path $vmdkPath)) {
        Write-ERR "VMDK creation failed for $vmName"
        return $null
    }
    Write-OK "VMDK created: $vmdkPath"

    # Build VMX
    $cd2Block = ""
    if ($iso2Path) {
        $cd2Block = @"

ide1:1.present = "TRUE"
ide1:1.fileName = "$iso2Path"
ide1:1.deviceType = "cdrom-image"
ide1:1.startConnected = "TRUE"
"@
    }

    $vmxContent = @"
.encoding = "UTF-8"
config.version = "8"
virtualHW.version = "8"
displayName = "$vmName"
guestOS = "$($def.GuestOS)"
memsize = "$($def.RAM)"
numvcpus = "$($def.CPU)"
cpuid.coresPerSocket = "1"

scsi0.present = "TRUE"
scsi0.virtualDev = "$scsiType"
scsi0:0.present = "TRUE"
scsi0:0.fileName = "$vmName.vmdk"
scsi0:0.deviceType = "scsi-hardDisk"

bios.bootOrder = "cdrom,hdd"

ide1:0.present = "TRUE"
ide1:0.fileName = "$isoPath"
ide1:0.deviceType = "cdrom-image"
ide1:0.startConnected = "TRUE"
$cd2Block
ethernet0.present = "TRUE"
ethernet0.connectionType = "nat"
ethernet0.virtualDev = "$nicType"
ethernet0.addressType = "generated"

usb.present = "FALSE"
sound.present = "FALSE"
svga.vramSize = "16777216"
tools.syncTime = "TRUE"
rtc.diffFromUTC = "0"
"@

    [System.IO.File]::WriteAllText($vmxPath, $vmxContent, [System.Text.Encoding]::UTF8)
    Write-OK "VMX written: $vmxPath"
    return $vmxPath
}

# ============================================================
#  FUNCTION — Start VM
# ============================================================
function Start-VMwareVM ($vmxPath, $vmName) {
    if (-not $vmxPath) { Write-WRN "Skipping start — no vmx for $vmName"; return }
    Write-INF "Starting: $vmName"
    & $vmrun start $vmxPath gui 2>&1 | Out-Null
    Start-Sleep -Seconds 5
    Write-OK "$vmName booting from ISO."
}

# ============================================================
#  FUNCTION — Flip boot order to HDD after install
# ============================================================
function Set-BootFromHDD {
    param(
        [ValidateSet(
            "DC01-Primary","DC02-Secondary","FS01-Files","PS01-Print",
            "WS-Student01","WS-Staff01","NW65-Auth","Ubuntu704-Client",
            "pfSense12-FW","all"
        )]
        [string]$VMName = "all"
    )

    $targets = if ($VMName -eq "all") {
        @("DC01-Primary","DC02-Secondary","FS01-Files","PS01-Print",
          "WS-Student01","WS-Staff01","NW65-Auth","Ubuntu704-Client","pfSense12-FW")
    } else { @($VMName) }

    foreach ($name in $targets) {
        $vmxPath = Join-Path $VmBasePath "$name\$name.vmx"
        if (-not (Test-Path $vmxPath)) { Write-WRN "$name not found — skipping."; continue }

        $vmx = Get-Content $vmxPath -Raw
        $vmx = $vmx -replace 'bios\.bootOrder\s*=\s*"[^"]*"',            'bios.bootOrder = "hdd,cdrom"'
        $vmx = $vmx -replace '(ide1:0\.startConnected\s*=\s*)"[^"]*"',   '$1"FALSE"'
        $vmx = $vmx -replace '(ide1:1\.startConnected\s*=\s*)"[^"]*"',   '$1"FALSE"'
        [System.IO.File]::WriteAllText($vmxPath, $vmx, [System.Text.Encoding]::UTF8)
        Write-OK "$name — HDD boot set, CD ejected."
    }
}

# ============================================================
#  FUNCTION — Re-attach ISO and boot from DVD (repair)
# ============================================================
function Repair-VMwareBoot {
    param(
        [ValidateSet(
            "DC01-Primary","DC02-Secondary","FS01-Files","PS01-Print",
            "WS-Student01","WS-Staff01","NW65-Auth","Ubuntu704-Client","pfSense12-FW"
        )]
        [string]$VMName
    )

    $vmxPath = Join-Path $VmBasePath "$VMName\$VMName.vmx"
    if (-not (Test-Path $vmxPath)) { Write-ERR "$VMName vmx not found."; return }

    $def = $VmDefs | Where-Object { $_.Name -eq $VMName } | Select-Object -First 1
    if (-not $def) { Write-ERR "Definition not found for $VMName."; return }

    $iso = $IsoMap[$def.IsoKey]
    Write-HDR "Boot Repair: $VMName"

    $vmx = Get-Content $vmxPath -Raw
    $vmx = $vmx -replace 'bios\.bootOrder\s*=\s*"[^"]*"',            'bios.bootOrder = "cdrom,hdd"'
    $vmx = $vmx -replace '(ide1:0\.fileName\s*=\s*)"[^"]*"',         "`$1`"$iso`""
    $vmx = $vmx -replace '(ide1:0\.deviceType\s*=\s*)"[^"]*"',       '$1"cdrom-image"'
    $vmx = $vmx -replace '(ide1:0\.startConnected\s*=\s*)"[^"]*"',   '$1"TRUE"'
    [System.IO.File]::WriteAllText($vmxPath, $vmx, [System.Text.Encoding]::UTF8)

    Write-OK "ISO re-attached. Starting $VMName..."
    & $vmrun start $vmxPath gui 2>&1 | Out-Null
}

# ============================================================
#  STEP 4 — CREATE AND LAUNCH ALL 9 VMs
# ============================================================
Write-HDR "Step 4: Building and launching all 9 VMs"

$total   = $VmDefs.Count
$current = 0
$results = @()

foreach ($def in $VmDefs) {
    $current++
    $isoPath  = $IsoMap[$def.IsoKey]
    $iso2Path = if ($def.IsoKey2) { $IsoMap[$def.IsoKey2] } else { $null }
    $isoLabel = $ExactIsoNames[$def.IsoKey]
    if ($def.IsoKey2) { $isoLabel += " + $($ExactIsoNames[$def.IsoKey2])" }

    Write-Host ""
    Write-Host ("─" * 64) -ForegroundColor DarkGray
    Write-Host "  VM $current of $total : $($def.Name)" -ForegroundColor White
    Write-Host "  Disk: $($def.Disk) GB  RAM: $($def.RAM) MB  CPU: $($def.CPU)  NAT" -ForegroundColor DarkGray
    Write-Host "  ISO : $isoLabel" -ForegroundColor DarkGray
    Write-Host ("─" * 64) -ForegroundColor DarkGray

    try {
        $vmxPath = New-VMwareVM $def $isoPath $iso2Path
        Start-VMwareVM $vmxPath $def.Name
        $results += [pscustomobject]@{
            "#"    = $current
            VM     = $def.Name
            Disk   = "$($def.Disk) GB"
            RAM    = "$($def.RAM) MB"
            Status = if ($vmxPath) { "Launched" } else { "FAILED" }
        }
    } catch {
        Write-ERR "Error on $($def.Name): $_"
        $results += [pscustomobject]@{
            "#"    = $current
            VM     = $def.Name
            Disk   = "$($def.Disk) GB"
            RAM    = "$($def.RAM) MB"
            Status = "FAILED: $_"
        }
    }

    if ($current -lt $total) { Start-Sleep -Seconds 10 }
}

# ============================================================
#  STEP 5 — SUMMARY
# ============================================================
Write-HDR "Done — K-12 2007 Lab — All 9 VMs"
$results | Format-Table -AutoSize

Write-Host "  VM files : $VmBasePath" -ForegroundColor Cyan
Write-Host ""
Write-Host "  AFTER INSTALL — flip boot order to HDD:" -ForegroundColor Yellow
Write-Host "    Set-BootFromHDD                        # all 9 VMs" -ForegroundColor Cyan
Write-Host "    Set-BootFromHDD -VMName DC01-Primary   # one VM" -ForegroundColor Cyan
Write-Host ""
Write-Host "  DC01-Primary    : Setup wizard -> install -> run dcpromo for first DC" -ForegroundColor Yellow
Write-Host "  DC02-Secondary  : Install -> join domain -> run dcpromo as secondary DC" -ForegroundColor Yellow
Write-Host "  FS01-Files      : Install -> join domain -> add File Services role" -ForegroundColor Yellow
Write-Host "  PS01-Print      : Install -> join domain -> add Print Services + WSUS" -ForegroundColor Yellow
Write-Host "  WS-Student01    : XP setup -> join domain after install" -ForegroundColor Yellow
Write-Host "  WS-Staff01      : XP setup -> join domain after install" -ForegroundColor Yellow
Write-Host "  NW65-Auth       : CD1 boots installer, CD2 pre-wired for NW products" -ForegroundColor Yellow
Write-Host "  Ubuntu704       : Live desktop -> double-click Install icon" -ForegroundColor Yellow
Write-Host "  pfSense12-FW    : Boots live -> console wizard assigns WAN/LAN interfaces" -ForegroundColor Yellow
Write-Host ""
Write-Host "  REPAIR: Repair-VMwareBoot -VMName <name>" -ForegroundColor Magenta
Write-Host ""
