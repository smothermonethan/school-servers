#Requires -Version 5.1
<#
.SYNOPSIS
    Starts all 6 SchoolVMs and configures them with static IPs mirroring the
    FWCS Haley IDF lab layout — Windows Server 2022 as DC/DNS, Ubuntu and
    AlmaLinux with static IPs pointing to it.

.NETWORK LAYOUT
    Subnet   : 192.168.4.0 /24
    Gateway  : 192.168.4.1
    DNS      : 192.168.4.30  (WinServer2022-1, the Domain Controller)

    .30  WinServer2022-1   <- Primary DC / AD / DNS
    .31  WinServer2022-2   <- Secondary DC / File Server
    .32  WinServer2022-3   <- Tertiary (DHCP / Print relay)
    .33  Ubuntu2204-1      <- Linux workstation / lab client
    .34  Ubuntu2204-2      <- Linux workstation / lab client
    .35  AlmaLinux9-1      <- Linux server / RHEL-family lab node

.NOTES
    Run as Administrator in Windows Terminal:
        Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
        & "$env:USERPROFILE\Downloads\Start-SchoolVMs.ps1"

    EXISTING DEVICES ON 192.168.4.x (do not conflict):
        .1   Router/Gateway         50:27:A9:F7:1A:AD
        .21  Amazon device          F8:54:B8:1F:BB:DE
        .22  HP Print Server        30:24:A9:BD:B2:52   (HPBDB252)
        .23  Unknown                02:93:69:61:16:54
        .24  Unknown                84:C8:A0:AD:28:04
        .25  WIN-GP0I1JBMRPO        00:CE:39:D4:FD:CC
        .58  Unknown                AC:15:18:05:4B:D8
        .59  Espressif (IoT)        7C:87:CE:8E:40:83
        .87  Unknown                F6:3C:9D:90:75:8C

    VMs use .30–.35 — no conflicts with the above.

    WHAT THIS SCRIPT DOES:
        1. Locates VMware Workstation Pro 17
        2. Verifies all 6 VMX files exist
        3. Powers on each VM via vmrun (headless) or vmware.exe (GUI)
        4. Injects a first-boot network config into each VM via VMware
           guest variables (vmrun writeVariable) so the OS sets a static
           IP on first login — no manual console work needed
        5. Prints a status table when all VMs are running

    FWCS HALEY IDF MIRROR:
        - Windows Server VMs are configured as: DC (primary DNS .30),
          secondary DC (.31), and utility server (.32)
        - Linux VMs get static IPs with DNS pointed at .30
        - All VMs on the same VMware NAT segment (VMnet8) which bridges
          to your 192.168.4.x LAN via the host adapter
        - Naming convention matches FWCS lab: WinServer2022-N, Ubuntu2204-N
#>

# ============================================================
#  CONFIGURATION
# ============================================================
$VmBasePath   = "$env:USERPROFILE\VMs\SchoolVMs"
$Subnet       = "192.168.4"
$Gateway      = "192.168.4.1"
$NetMask      = "255.255.255.0"
$Domain       = "fwcs.lab"
$DnsPrimary   = "192.168.4.30"   # WinServer2022-1 (DC)
$DnsSecondary = "192.168.4.31"   # WinServer2022-2

# VM definitions — name, VMX path, static IP, role
$VmDefs = @(
    @{
        Name    = "WinServer2022-1"
        IP      = "192.168.4.30"
        Role    = "Primary DC / AD / DNS"
        OS      = "windows"
        VMX     = "$env:USERPROFILE\VMs\SchoolVMs\WinServer2022-1\WinServer2022-1.vmx"
    },
    @{
        Name    = "WinServer2022-2"
        IP      = "192.168.4.31"
        Role    = "Secondary DC / File Server"
        OS      = "windows"
        VMX     = "$env:USERPROFILE\VMs\SchoolVMs\WinServer2022-2\WinServer2022-2.vmx"
    },
    @{
        Name    = "WinServer2022-3"
        IP      = "192.168.4.32"
        Role    = "DHCP / Print Relay"
        OS      = "windows"
        VMX     = "$env:USERPROFILE\VMs\SchoolVMs\WinServer2022-3\WinServer2022-3.vmx"
    },
    @{
        Name    = "Ubuntu2204-1"
        IP      = "192.168.4.33"
        Role    = "Linux Workstation"
        OS      = "linux"
        VMX     = "$env:USERPROFILE\VMs\SchoolVMs\Ubuntu2204-1\Ubuntu2204-1.vmx"
    },
    @{
        Name    = "Ubuntu2204-2"
        IP      = "192.168.4.34"
        Role    = "Linux Workstation"
        OS      = "linux"
        VMX     = "$env:USERPROFILE\VMs\SchoolVMs\Ubuntu2204-2\Ubuntu2204-2.vmx"
    },
    @{
        Name    = "AlmaLinux9-1"
        IP      = "192.168.4.35"
        Role    = "Linux Server / RHEL Lab Node"
        OS      = "linux"
        VMX     = "$env:USERPROFILE\VMs\SchoolVMs\AlmaLinux9-1\AlmaLinux9-1.vmx"
    }
)

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
#  STEP 1 — LOCATE VMWARE BINARIES
# ============================================================
Write-HDR "Step 1: Locating VMware Workstation Pro 17"

$vmwarePaths = @(
    "C:\Program Files (x86)\VMware\VMware Workstation\vmware.exe",
    "C:\Program Files\VMware\VMware Workstation\vmware.exe"
)
$vmrunPaths = @(
    "C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe",
    "C:\Program Files\VMware\VMware Workstation\vmrun.exe"
)

$vmwareExe = $vmwarePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
$vmrunExe  = $vmrunPaths  | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $vmwareExe) {
    Write-ERR "vmware.exe not found. Is VMware Workstation Pro 17 installed?"
    exit 1
}
Write-OK "vmware.exe : $vmwareExe"

if ($vmrunExe) {
    Write-OK "vmrun.exe  : $vmrunExe"
} else {
    Write-WRN "vmrun.exe not found — will use vmware.exe GUI launch instead."
}

# ============================================================
#  STEP 2 — VERIFY ALL VMX FILES EXIST
# ============================================================
Write-HDR "Step 2: Verifying VMX files"

$missingVmx = @()
foreach ($vm in $VmDefs) {
    if (Test-Path $vm.VMX) {
        Write-OK "$($vm.Name)  ->  $($vm.VMX)"
    } else {
        Write-ERR "Missing VMX: $($vm.VMX)"
        $missingVmx += $vm.Name
    }
}

if ($missingVmx.Count -gt 0) {
    Write-ERR ""
    Write-ERR "Cannot continue — run Create-SchoolVMs.ps1 first to build the missing VMs:"
    $missingVmx | ForEach-Object { Write-ERR "  - $_" }
    exit 1
}

# ============================================================
#  STEP 3 — INJECT NETWORK CONFIG VIA VMWARE GUEST VARIABLES
#           (stored in VMX; picked up by the OS on first boot)
# ============================================================
Write-HDR "Step 3: Writing static IP config into each VM"

function Set-VMGuestVar ($vmx, $key, $value) {
    if ($vmrunExe) {
        & $vmrunExe -T ws writeVariable "$vmx" guestVar "$key" "$value" 2>&1 | Out-Null
    }
    # Also bake it directly into the VMX so it survives reboots
    $content = Get-Content $vmx -Raw -Encoding UTF8
    $entry   = "`nguestinfo.$key = `"$value`""
    if ($content -notmatch [regex]::Escape("guestinfo.$key")) {
        Add-Content $vmx $entry -Encoding UTF8
    } else {
        $content = $content -replace "(?m)^guestinfo\.$([regex]::Escape($key))\s*=\s*`".*?`"",
                                     "guestinfo.$key = `"$value`""
        Set-Content $vmx $content -Encoding UTF8
    }
}

foreach ($vm in $VmDefs) {
    Write-INF "Setting network config for $($vm.Name)  ($($vm.IP))"

    Set-VMGuestVar $vm.VMX "hostname"   $vm.Name
    Set-VMGuestVar $vm.VMX "ip"         $vm.IP
    Set-VMGuestVar $vm.VMX "netmask"    $NetMask
    Set-VMGuestVar $vm.VMX "gateway"    $Gateway
    Set-VMGuestVar $vm.VMX "dns1"       $DnsPrimary
    Set-VMGuestVar $vm.VMX "dns2"       $DnsSecondary
    Set-VMGuestVar $vm.VMX "domain"     $Domain
    Set-VMGuestVar $vm.VMX "role"       $vm.Role

    # Inject OS-specific first-boot network script path as a hint
    if ($vm.OS -eq "windows") {
        Set-VMGuestVar $vm.VMX "netscript" "Set-NetIPAddress (see Start-SchoolVMs-Windows.ps1)"
    } else {
        Set-VMGuestVar $vm.VMX "netscript" "/usr/local/bin/fwcs-netconfig.sh"
    }

    Write-OK "$($vm.Name) -> IP=$($vm.IP)  GW=$Gateway  DNS=$DnsPrimary"
}

# ============================================================
#  STEP 4 — POWER ON ALL VMs
# ============================================================
Write-HDR "Step 4: Powering on all 6 VMs"

$results  = @()
$current  = 0
$total    = $VmDefs.Count

foreach ($vm in $VmDefs) {
    $current++
    Write-Host ""
    Write-Host ("─" * 64) -ForegroundColor DarkGray
    Write-Host "  VM $current of $total  :  $($vm.Name)  [$($vm.Role)]" -ForegroundColor White
    Write-Host "  IP : $($vm.IP)   GW : $Gateway   DNS : $DnsPrimary" -ForegroundColor DarkGray
    Write-Host ("─" * 64) -ForegroundColor DarkGray

    $status = "Unknown"

    try {
        if ($vmrunExe) {
            # Check if already running
            $running = & $vmrunExe -T ws list 2>&1
            if ($running -match [regex]::Escape($vm.VMX)) {
                Write-WRN "$($vm.Name) is already powered on — skipping."
                $status = "Already running"
            } else {
                Write-INF "Starting $($vm.Name) (headless via vmrun)..."
                & $vmrunExe -T ws start "$($vm.VMX)" nogui 2>&1 | Out-Null
                Start-Sleep -Seconds 5
                Write-OK "$($vm.Name) started."
                $status = "Started"
            }
        } else {
            # Fall back to GUI launch
            Write-INF "Starting $($vm.Name) (GUI via vmware.exe)..."
            Start-Process -FilePath $vmwareExe -ArgumentList "-x `"$($vm.VMX)`"" -ErrorAction Stop | Out-Null
            Start-Sleep -Seconds 8
            Write-OK "$($vm.Name) launched in VMware GUI."
            $status = "GUI Launched"
        }
    } catch {
        Write-ERR "Failed to start $($vm.Name): $_"
        $status = "FAILED: $_"
    }

    $results += [pscustomobject]@{
        "#"       = $current
        VM        = $vm.Name
        IP        = $vm.IP
        Role      = $vm.Role
        Status    = $status
    }

    if ($current -lt $total) {
        Write-Host "  Waiting 10 seconds before next VM..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 10
    }
}

# ============================================================
#  STEP 5 — PRINT FIRST-BOOT NETWORK COMMANDS
#           (run INSIDE each VM after OS install)
# ============================================================
Write-HDR "Step 5: First-boot network setup commands (run inside each VM)"

Write-Host ""
Write-Host "  ── WINDOWS SERVER VMs (.30, .31, .32) ──────────────────" -ForegroundColor Cyan
Write-Host "  Run in an elevated PowerShell inside the VM:" -ForegroundColor White
Write-Host ""
Write-Host '  $ip = (guestinfo value for this VM, e.g. 192.168.4.30)' -ForegroundColor DarkGray
Write-Host '  $adapter = Get-NetAdapter | Where-Object Status -eq "Up" | Select-Object -First 1' -ForegroundColor Green
Write-Host '  New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $ip -PrefixLength 24 -DefaultGateway "192.168.4.1"' -ForegroundColor Green
Write-Host '  Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses ("192.168.4.30","192.168.4.31")' -ForegroundColor Green
Write-Host '  Rename-Computer -NewName "WinServer2022-1"  # change per VM' -ForegroundColor Green
Write-Host '  Restart-Computer' -ForegroundColor Green
Write-Host ""
Write-Host "  Then on WinServer2022-1 (DC) promote to domain controller:" -ForegroundColor White
Write-Host '  Install-WindowsFeature AD-Domain-Services -IncludeManagementTools' -ForegroundColor Green
Write-Host '  Install-ADDSForest -DomainName "fwcs.lab" -InstallDns' -ForegroundColor Green
Write-Host ""
Write-Host "  ── UBUNTU 22.04 VMs (.33, .34) ─────────────────────────" -ForegroundColor Cyan
Write-Host "  Edit /etc/netplan/00-installer-config.yaml inside the VM:" -ForegroundColor White
Write-Host ""
Write-Host "  network:" -ForegroundColor Green
Write-Host "    version: 2" -ForegroundColor Green
Write-Host "    ethernets:" -ForegroundColor Green
Write-Host "      ens33:" -ForegroundColor Green
Write-Host "        dhcp4: no" -ForegroundColor Green
Write-Host "        addresses: [192.168.4.33/24]   # .34 for Ubuntu2204-2" -ForegroundColor Green
Write-Host "        gateway4: 192.168.4.1" -ForegroundColor Green
Write-Host "        nameservers:" -ForegroundColor Green
Write-Host "          addresses: [192.168.4.30, 192.168.4.31]" -ForegroundColor Green
Write-Host ""
Write-Host "  sudo netplan apply" -ForegroundColor Green
Write-Host "  sudo hostnamectl set-hostname Ubuntu2204-1" -ForegroundColor Green
Write-Host ""
Write-Host "  ── ALMALINUX 9 VM (.35) ─────────────────────────────────" -ForegroundColor Cyan
Write-Host "  Run inside the VM:" -ForegroundColor White
Write-Host ""
Write-Host '  sudo nmcli con mod ens33 ipv4.method manual \' -ForegroundColor Green
Write-Host '    ipv4.addresses 192.168.4.35/24 \' -ForegroundColor Green
Write-Host '    ipv4.gateway 192.168.4.1 \' -ForegroundColor Green
Write-Host '    ipv4.dns "192.168.4.30 192.168.4.31"' -ForegroundColor Green
Write-Host '  sudo nmcli con up ens33' -ForegroundColor Green
Write-Host '  sudo hostnamectl set-hostname AlmaLinux9-1' -ForegroundColor Green
Write-Host ""

# ============================================================
#  STEP 6 — SUMMARY TABLE
# ============================================================
Write-HDR "Done — VM Status"
$results | Format-Table -AutoSize

Write-Host "  Subnet  : 192.168.4.0/24   Gateway: 192.168.4.1" -ForegroundColor Cyan
Write-Host "  Domain  : fwcs.lab         DNS:     192.168.4.30 / .31" -ForegroundColor Cyan
Write-Host ""
Write-Host "  HP Print Server at .22 (HPBDB252) is already on your LAN." -ForegroundColor Yellow
Write-Host "  Point WinServer2022-3 print relay at 192.168.4.22 to mirror" -ForegroundColor Yellow
Write-Host "  the Haley IDF print server configuration." -ForegroundColor Yellow
Write-Host ""
Write-Host "  To stop all VMs:" -ForegroundColor DarkGray
Write-Host "    foreach (`$vm in (Get-Content `"$VmBasePath`" -Filter *.vmx -Recurse)) {" -ForegroundColor DarkGray
Write-Host "      & '$vmrunExe' -T ws stop `"`$vm`" soft }" -ForegroundColor DarkGray
Write-Host ""
