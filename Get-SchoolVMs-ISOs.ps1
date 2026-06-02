#Requires -Version 5.1
<#
.SYNOPSIS
    K-12 School District 2007 Lab — ISO Downloader
    Downloads all ISOs from archive.org to your Downloads folder,
    named exactly as Create-SchoolVMs.ps1 expects.

    Run as Administrator:
        Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
        & "$env:USERPROFILE\Downloads\Get-SchoolVMs-ISOs.ps1"
#>

# ============================================================
#  HELPERS
# ============================================================
function Write-OK  ($m) { Write-Host "  [OK]  $m" -ForegroundColor Green  }
function Write-INF ($m) { Write-Host "  [-->] $m" -ForegroundColor Cyan   }
function Write-ERR ($m) { Write-Host "  [!!]  $m" -ForegroundColor Red    }
function Write-WRN ($m) { Write-Host "  [**]  $m" -ForegroundColor Yellow }
function Write-HDR ($m) {
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Magenta
    Write-Host "  $m" -ForegroundColor Magenta
    Write-Host ("=" * 70) -ForegroundColor Magenta
}
function Write-SEC ($m) {
    Write-Host ""
    Write-Host ("─" * 70) -ForegroundColor Yellow
    Write-Host "  $m" -ForegroundColor Yellow
    Write-Host ("─" * 70) -ForegroundColor Yellow
}

$DownloadsDir = "$env:USERPROFILE\Downloads"

# ============================================================
#  ISO CATALOGUE
#  All URLs are direct archive.org downloads.
#  Filenames match exactly what Create-SchoolVMs.ps1 expects.
# ============================================================
$ISOs = @(

    # ── WINDOWS SERVER 2003 R2 ENTERPRISE x86 ────────────────
    # Two-disc set. CD1 boots the installer. CD2 adds R2 components
    # (DFS, Print Management, WSUS, etc.) — prompted during setup.
    [pscustomobject]@{
        Name     = "Windows Server 2003 R2 Enterprise x86 — CD1"
        Filename = "en_win_srv_2003_r2_enterprise_x86_cd1.iso"
        URL      = "https://archive.org/download/en_win_srv_2003_r2_enterprise_x86/en_win_srv_2003_r2_enterprise_x86_cd1.iso"
        Page     = "https://archive.org/details/en_win_srv_2003_r2_enterprise_x86"
        SizeMB   = 640
        Role     = "Primary DC / AD / DNS / DHCP / File / Print / WSUS"
        Notes    = "Run dcpromo after install to promote to domain controller."
    },
    [pscustomobject]@{
        Name     = "Windows Server 2003 R2 Enterprise x86 — CD2"
        Filename = "en_win_srv_2003_r2_enterprise_x86_cd2.iso"
        URL      = "https://archive.org/download/en_win_srv_2003_r2_enterprise_x86/en_win_srv_2003_r2_enterprise_x86_cd2.iso"
        Page     = "https://archive.org/details/en_win_srv_2003_r2_enterprise_x86"
        SizeMB   = 140
        Role     = "R2 components: DFS, Print Mgmt, WSUS prereqs"
        Notes    = "Pre-wired on ide1:1. Setup will prompt for it automatically."
    },

    # ── WINDOWS XP PROFESSIONAL SP3 x86 ─────────────────────
    # The standard K-12 student/staff desktop OS in 2007.
    # Identifier: WindowsXP-SP3  (verified archive.org)
    [pscustomobject]@{
        Name     = "Windows XP Professional SP3 x86"
        Filename = "WindowsXP-SP3-x86.iso"
        URL      = "https://archive.org/download/WindowsXP-SP3/WindowsXP-SP3-x86.iso"
        Page     = "https://archive.org/details/WindowsXP-SP3"
        SizeMB   = 617
        Role     = "Student and staff workstation OS"
        Notes    = "Used for both WS-Student01 and WS-Staff01."
    },

    # ── NOVELL NETWARE 6.5 SP4 ───────────────────────────────
    # Many K-12 districts still ran NW6.5 in 2007 for NDS auth.
    # Identifier: netware65install  (verified archive.org)
    [pscustomobject]@{
        Name     = "Novell NetWare 6.5 SP4 — CD1 OS Install"
        Filename = "CD1-OSinstall.iso"
        URL      = "https://archive.org/download/netware65install/CD1-OSinstall.ISO"
        Page     = "https://archive.org/details/netware65install"
        SizeMB   = 431
        Role     = "NetWare OS installer — boots and installs NW6.5"
        Notes    = "CD2 pre-wired on ide1:1. BusLogic SCSI + vlance NIC in VMX."
    },
    [pscustomobject]@{
        Name     = "Novell NetWare 6.5 SP4 — CD2 NW Products"
        Filename = "CD2-NWproducts.iso"
        URL      = "https://archive.org/download/netware65install/CD2-NWproducts.ISO"
        Page     = "https://archive.org/details/netware65install"
        SizeMB   = 594
        Role     = "iPrint, iManager, iFolder, NSS"
        Notes    = "Installer prompts for this disc automatically."
    },

    # ── UBUNTU 7.04 FEISTY FAWN Desktop i386 ─────────────────
    # Era-correct Linux desktop / thin client alternative.
    # Identifier: ubuntu-7.04-desktop-i386  (verified archive.org)
    [pscustomobject]@{
        Name     = "Ubuntu 7.04 Feisty Fawn Desktop i386"
        Filename = "ubuntu-7.04-desktop-i386.iso"
        URL      = "https://archive.org/download/ubuntu-7.04-desktop-i386/ubuntu-7.04-desktop-i386.iso"
        Page     = "https://archive.org/details/ubuntu-7.04-desktop-i386"
        SizeMB   = 699
        Role     = "Linux client / thin client alternative"
        Notes    = "Live desktop. Double-click Install icon to install to disk."
    },

    # ── PFSENSE 1.2 ──────────────────────────────────────────
    # FreeBSD-based firewall — common in budget K-12 networks.
    # Identifier: pfSense-1.2-release  (verified archive.org)
    [pscustomobject]@{
        Name     = "pfSense 1.2 Release LiveCD"
        Filename = "pfSense-1.2-release-LiveCD-cdrom.iso"
        URL      = "https://archive.org/download/pfSense-1.2-release/pfSense-1.2-release-LiveCD-cdrom.iso"
        Page     = "https://archive.org/details/pfSense-1.2-release"
        SizeMB   = 55
        Role     = "School firewall / VLAN router / content filter"
        Notes    = "Boots to console wizard. Assign WAN = eth0, LAN = eth1."
    }
)

# ============================================================
#  STEP 1 — REFERENCE TABLE
# ============================================================
Write-HDR "K-12 School District 2007 — ISO Reference"
Write-Host ""
Write-Host "  Generic K-12 district lab — 2007 era technology stack" -ForegroundColor DarkGray
Write-Host "  OS stack: Windows Server 2003 R2 / XP SP3 / NetWare 6.5 / Ubuntu 7.04 / pfSense 1.2" -ForegroundColor DarkGray

Write-SEC "VM ISO LIST"
foreach ($iso in $ISOs) {
    Write-Host ""
    Write-Host "  $($iso.Name)" -ForegroundColor White
    Write-Host "    File  : $($iso.Filename)" -ForegroundColor Cyan
    Write-Host "    Size  : ~$($iso.SizeMB) MB" -ForegroundColor DarkGray
    Write-Host "    Role  : $($iso.Role)" -ForegroundColor DarkGray
    Write-Host "    Notes : $($iso.Notes)" -ForegroundColor Yellow
    Write-Host "    Page  : $($iso.Page)" -ForegroundColor DarkGray
}

# ============================================================
#  STEP 2 — CHECK DOWNLOADS FOLDER
# ============================================================
Write-HDR "Step 2: Checking Downloads folder"

$unique     = $ISOs | Sort-Object Filename -Unique
$toDownload = @()

foreach ($iso in $unique) {
    $path = Join-Path $DownloadsDir $iso.Filename
    if (Test-Path $path) {
        $mb = [math]::Round((Get-Item $path).Length / 1MB, 1)
        Write-OK "Found   : $($iso.Filename)  ($mb MB)"
    } else {
        Write-WRN "Missing : $($iso.Filename)  (~$($iso.SizeMB) MB)"
        $toDownload += $iso
    }
}

if ($toDownload.Count -eq 0) {
    Write-Host ""
    Write-OK "All ISOs present. Run Create-SchoolVMs.ps1 to build the lab."
    exit 0
}

# ============================================================
#  STEP 3 — DOWNLOAD MISSING ISOs
# ============================================================
$totalSize = ($toDownload | Measure-Object -Property SizeMB -Sum).Sum
Write-HDR "Step 3: Downloading $($toDownload.Count) ISO(s)  (~$totalSize MB total)"

Write-Host ""
Write-Host "  Saving to : $DownloadsDir" -ForegroundColor Cyan
Write-Host "  One file at a time with live progress." -ForegroundColor White
Write-Host "  Do not close this window until complete." -ForegroundColor Yellow
Write-Host ""
Write-Host "  Press Enter to start, or Ctrl+C to cancel." -ForegroundColor DarkGray
Read-Host | Out-Null

$current = 0
$failed  = @()

foreach ($iso in ($toDownload | Sort-Object Filename -Unique)) {
    $current++
    $dest = Join-Path $DownloadsDir $iso.Filename

    Write-Host ""
    Write-Host ("─" * 70) -ForegroundColor DarkGray
    Write-Host "  [$current/$($toDownload.Count)]  $($iso.Name)" -ForegroundColor White
    Write-Host "  URL  : $($iso.URL)" -ForegroundColor DarkGray
    Write-Host "  Dest : $dest" -ForegroundColor DarkGray
    Write-Host ("─" * 70) -ForegroundColor DarkGray

    # Remove partial file
    if (Test-Path $dest) {
        $existMB = [math]::Round((Get-Item $dest).Length / 1MB, 1)
        if ($existMB -lt ($iso.SizeMB * 0.95)) {
            Write-WRN "Partial file ($existMB MB) — removing and re-downloading."
            Remove-Item $dest -Force
        } else {
            Write-OK "Already complete ($existMB MB) — skipping."
            continue
        }
    }

    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
        $wc.Headers.Add("Referer", $iso.Page)

        $global:dlDone  = $false
        $global:dlError = $null

        $onProgress = Register-ObjectEvent -InputObject $wc `
            -EventName DownloadProgressChanged -Action {
                $pct  = $Event.SourceEventArgs.ProgressPercentage
                $recv = [math]::Round($Event.SourceEventArgs.BytesReceived       / 1MB, 1)
                $tot  = [math]::Round($Event.SourceEventArgs.TotalBytesToReceive / 1MB, 1)
                Write-Progress -Activity "Downloading $($Event.MessageData)" `
                    -Status "$recv MB of $tot MB  ($pct%)" `
                    -PercentComplete ([Math]::Max(0, [Math]::Min(100, $pct)))
            } -MessageData $iso.Filename

        $onComplete = Register-ObjectEvent -InputObject $wc `
            -EventName DownloadFileCompleted -Action {
                $global:dlError = $Event.SourceEventArgs.Error
                $global:dlDone  = $true
            }

        $wc.DownloadFileAsync([uri]$iso.URL, $dest)

        $timeout = 0
        $maxWait = 7200
        while (-not $global:dlDone -and $timeout -lt $maxWait) {
            Start-Sleep -Milliseconds 500
            $timeout++
        }

        Unregister-Event -SourceIdentifier $onProgress.Name -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier $onComplete.Name -ErrorAction SilentlyContinue
        Remove-Job       -Name            $onProgress.Name -ErrorAction SilentlyContinue
        Remove-Job       -Name            $onComplete.Name -ErrorAction SilentlyContinue
        Write-Progress -Activity "Downloading $($iso.Filename)" -Completed

        if ($timeout -ge $maxWait) { throw "Timed out after 2 hours." }
        if ($global:dlError)       { throw $global:dlError.Message    }

        if (Test-Path $dest) {
            $mb = [math]::Round((Get-Item $dest).Length / 1MB, 1)
            if ($mb -lt ($iso.SizeMB * 0.5)) {
                throw "File too small ($mb MB vs ~$($iso.SizeMB) MB expected) — likely a redirect."
            }
            Write-OK "Complete: $($iso.Filename)  ($mb MB)"
        } else {
            throw "File missing after download — disk full?"
        }

    } catch {
        Write-Progress -Activity "Downloading" -Completed -ErrorAction SilentlyContinue
        Write-ERR "FAILED : $($iso.Filename)"
        Write-ERR "Reason : $_"
        Write-WRN "URL    : $($iso.URL)"
        Write-WRN "Page   : $($iso.Page)"
        if (Test-Path $dest) { Remove-Item $dest -Force -ErrorAction SilentlyContinue }
        $failed += $iso
    }
}

# ============================================================
#  STEP 4 — FINAL SUMMARY
# ============================================================
Write-HDR "Download Complete"

$ok = ($toDownload | Sort-Object Filename -Unique).Count - $failed.Count
Write-Host ""
Write-OK "$ok file(s) downloaded successfully."

if ($failed.Count -gt 0) {
    Write-Host ""
    Write-ERR "$($failed.Count) file(s) failed — try manually:"
    foreach ($f in $failed) {
        Write-Host ""
        Write-Host "  $($f.Name)" -ForegroundColor Yellow
        Write-Host "  Page : $($f.Page)" -ForegroundColor Cyan
        Write-Host "  URL  : $($f.URL)" -ForegroundColor Cyan
    }
}

Write-Host ""
Write-Host ("═" * 70) -ForegroundColor Magenta
Write-Host "  K-12 2007 LAB STACK" -ForegroundColor Magenta
Write-Host ("═" * 70) -ForegroundColor Magenta
Write-Host ""
Write-Host "  DC01-Primary    Windows Server 2003 R2   Primary DC / AD / DNS / DHCP" -ForegroundColor White
Write-Host "  DC02-Secondary  Windows Server 2003 R2   Secondary DC / GPO" -ForegroundColor White
Write-Host "  FS01-Files      Windows Server 2003 R2   File server / student shares (DFS)" -ForegroundColor White
Write-Host "  PS01-Print      Windows Server 2003 R2   Print server / WSUS" -ForegroundColor White
Write-Host "  WS-Student01    Windows XP SP3           Student workstation" -ForegroundColor White
Write-Host "  WS-Staff01      Windows XP SP3           Staff / teacher workstation" -ForegroundColor White
Write-Host "  NW65-Auth       Novell NetWare 6.5        Legacy NDS authentication node" -ForegroundColor White
Write-Host "  Ubuntu704       Ubuntu 7.04 Feisty        Linux client / thin client alt" -ForegroundColor White
Write-Host "  pfSense12-FW    pfSense 1.2               School firewall / router" -ForegroundColor White
Write-Host ""
Write-Host ("─" * 70) -ForegroundColor Yellow
Write-Host "  When all ISOs are downloaded, run:" -ForegroundColor Yellow
Write-Host "    & `"$env:USERPROFILE\Downloads\Create-SchoolVMs.ps1`"" -ForegroundColor Cyan
Write-Host ""
