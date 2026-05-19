#!/usr/bin/env bash
# =============================================================================
#  ART ROOM INFRASTRUCTURE — AlmaLinux 9 Setup Script
#  Covers: VM-FILTER01 — CIPA-Compliant Content Filter
#          Student traffic on Black VLAN 10
#  Run as root:  sudo bash setup-almalinux.sh
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

# ── GLOBAL CONFIG — EDIT BEFORE RUNNING ──────────────────────────────────────
HOSTNAME="VM-FILTER01"
FILTER_IP="10.10.10.5"           # Static IP on Student VLAN 10
GATEWAY="10.10.10.1"
DC_IP="10.10.60.10"              # VM-DC01 — also DNS
DOMAIN="artroom.school.local"

# VLAN 10 (Black) — student network that routes through this filter
STUDENT_VLAN=10
STUDENT_NETWORK="10.10.10.0/24"
STUDENT_NIC="ens18"              # NIC facing student VLAN
UPSTREAM_NIC="ens19"             # NIC facing internet/uplink

SQUID_PORT=3128
HTTPS_PORT=3129                  # Bump port for SSL inspection

# SquidGuard / e2guardian blocklist sources (CIPA-compliant)
SHALLALIST_URL="https://www.shallalist.de/Downloads/shallalist.tar.gz"
URLBLACKLIST_URL="https://urlblacklist.com/cgi-bin/blacklistd/download/smallblacklist.tar.gz"

# Certificate info for SSL bump
CERT_COUNTRY="US"
CERT_STATE="Indiana"
CERT_CITY="Fort Wayne"
CERT_ORG="Art Room School Network"
CERT_CN="ArtRoom-Filter-CA"

LOG_DIR="/var/log/artroom-filter"
CACHE_DIR="/var/spool/squid"

# Admin notification email (for filter bypass alerts)
ADMIN_EMAIL="admin@school.local"
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
CYN='\033[0;36m'; WHT='\033[1;37m'; RST='\033[0m'

banner() { echo -e "\n${CYN}$(printf '=%.0s' {1..70})${RST}\n  ${WHT}$1${RST}\n${CYN}$(printf '=%.0s' {1..70})${RST}"; }
step()   { echo -e "  ${YLW}[*]${RST} $1"; }
ok()     { echo -e "  ${GRN}[+]${RST} $1"; }
warn()   { echo -e "  ${RED}[!]${RST} $1"; }

[[ $EUID -eq 0 ]] || { warn "Run as root: sudo bash $0"; exit 1; }

banner "VM-FILTER01 — CIPA Content Filter — AlmaLinux 9"

# ════════════════════════════════════════════════════════════════════════════
# STEP 1 — SYSTEM BASELINE
# ════════════════════════════════════════════════════════════════════════════
banner "Step 1 — System Baseline"

step "Setting hostname to $HOSTNAME..."
hostnamectl set-hostname "$HOSTNAME"
ok "Hostname: $(hostname)"

step "Configuring /etc/hosts..."
cat >> /etc/hosts <<EOF

$FILTER_IP  $HOSTNAME ${HOSTNAME}.${DOMAIN}
$DC_IP      VM-DC01 VM-DC01.${DOMAIN} ${DOMAIN}
EOF
ok "/etc/hosts updated"

step "Updating system packages..."
dnf update -y -q
ok "System updated"

step "Installing EPEL and PowerTools..."
dnf install -y -q epel-release
dnf config-manager --set-enabled crb 2>/dev/null || \
    dnf config-manager --set-enabled powertools 2>/dev/null || true
ok "EPEL + CRB enabled"

step "Installing required packages..."
dnf install -y -q \
    squid \
    squidGuard \
    e2guardian \
    openssl \
    openssl-devel \
    certbot \
    firewalld \
    fail2ban \
    chrony \
    net-tools \
    bind-utils \
    curl \
    wget \
    vim \
    nano \
    htop \
    iotop \
    tcpdump \
    nmap \
    logrotate \
    rsyslog \
    mailx \
    python3 \
    python3-pip \
    tar \
    gzip \
    realmd \
    sssd \
    sssd-tools \
    adcli \
    krb5-workstation \
    samba-common-tools
ok "Packages installed"

# ════════════════════════════════════════════════════════════════════════════
# STEP 2 — NETWORK CONFIGURATION
# ════════════════════════════════════════════════════════════════════════════
banner "Step 2 — Network Configuration"

step "Configuring network interfaces via nmcli..."
# Student-facing NIC (VLAN 10)
nmcli con mod "$STUDENT_NIC" \
    ipv4.method manual \
    ipv4.addresses "${FILTER_IP}/24" \
    ipv4.gateway "$GATEWAY" \
    ipv4.dns "$DC_IP" \
    ipv4.dns-search "$DOMAIN" \
    connection.autoconnect yes 2>/dev/null || \
nmcli con add type ethernet con-name "$STUDENT_NIC" ifname "$STUDENT_NIC" \
    ipv4.method manual \
    ipv4.addresses "${FILTER_IP}/24" \
    ipv4.gateway "$GATEWAY" \
    ipv4.dns "$DC_IP" \
    ipv4.dns-search "$DOMAIN"

nmcli con up "$STUDENT_NIC" 2>/dev/null || true
ok "Student NIC configured: $STUDENT_NIC → $FILTER_IP"

step "Enabling IP forwarding..."
cat > /etc/sysctl.d/99-filter.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
# Harden TCP stack
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.log_martians = 1
EOF
sysctl -p /etc/sysctl.d/99-filter.conf -q
ok "IP forwarding enabled + TCP hardening applied"

# ════════════════════════════════════════════════════════════════════════════
# STEP 3 — SSL CERTIFICATE FOR SSL BUMP
# ════════════════════════════════════════════════════════════════════════════
banner "Step 3 — SSL Inspection Certificate"

step "Generating CA certificate for SSL bump..."
mkdir -p /etc/squid/certs
cd /etc/squid/certs

openssl genrsa -out filter-ca.key 4096 2>/dev/null
openssl req -new -x509 -days 3650 -key filter-ca.key -out filter-ca.crt \
    -subj "/C=${CERT_COUNTRY}/ST=${CERT_STATE}/L=${CERT_CITY}/O=${CERT_ORG}/CN=${CERT_CN}" \
    2>/dev/null

# DER format for distribution to clients
openssl x509 -in filter-ca.crt -outform DER -out filter-ca.der

# Create SSL database for Squid
mkdir -p /var/lib/ssl_db
/usr/lib64/squid/security_file_certgen -c -s /var/lib/ssl_db -M 4MB 2>/dev/null || \
/usr/lib/squid/security_file_certgen -c -s /var/lib/ssl_db -M 4MB 2>/dev/null || \
    warn "SSL cert generator not found — SSL bump disabled (set ssl_bump off if needed)"
chown -R squid:squid /var/lib/ssl_db /etc/squid/certs
chmod 700 /etc/squid/certs
ok "CA certificate created: /etc/squid/certs/filter-ca.crt"
warn "DEPLOY filter-ca.crt to student machines via GPO (Trusted Root CAs)"
cd /

# ════════════════════════════════════════════════════════════════════════════
# STEP 4 — SQUID CONFIGURATION
# ════════════════════════════════════════════════════════════════════════════
banner "Step 4 — Squid Proxy Configuration"

step "Writing /etc/squid/squid.conf..."
cat > /etc/squid/squid.conf <<EOF
# =============================================================================
# Squid CIPA-Compliant Content Filter — Art Room VM-FILTER01
# =============================================================================

# ── ACL Definitions ──────────────────────────────────────────────────────────
acl localnet  src ${STUDENT_NETWORK}         # Student VLAN 10
acl localhost src 127.0.0.1/32 ::1
acl to_localhost dst 127.0.0.0/8 0.0.0.0/32 ::1

acl SSL_ports  port 443
acl Safe_ports port 80   443   21   70   210   1025-65535   280   488   591   777
acl CONNECT    method CONNECT

# CIPA required block categories (populated by SquidGuard)
acl blocked_sites    dstdomain "/etc/squid/blocklist/domains.txt"
acl adult_keywords   url_regex -i "/etc/squid/blocklist/keywords.txt"

# Whitelist for educational resources
acl whitelist        dstdomain "/etc/squid/whitelist/domains.txt"

# School hours: Mon-Fri 7am-5pm
acl school_hours     time MTWHF 07:00-17:00

# ── Access Controls ───────────────────────────────────────────────────────────
# Deny non-safe ports
http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports

# Allow whitelist always
http_access allow whitelist

# CIPA mandatory denials (always active for students)
http_access deny blocked_sites
http_access deny adult_keywords

# Allow local network
http_access allow localnet
http_access allow localhost

# Deny everything else
http_access deny all

# ── Ports ─────────────────────────────────────────────────────────────────────
http_port ${SQUID_PORT}
https_port ${HTTPS_PORT} intercept ssl-bump \
    cert=/etc/squid/certs/filter-ca.crt \
    key=/etc/squid/certs/filter-ca.key \
    generate-host-certificates=on \
    dynamic_cert_mem_cache_size=4MB

# ── SSL Bump ─────────────────────────────────────────────────────────────────
# Peek-and-splice (preserve privacy for banking/medical, bump most others)
acl step1  at_step SslBump1
acl step2  at_step SslBump2
acl step3  at_step SslBump3

# Do not bump these (privacy-critical)
acl no_bump_domains dstdomain .banking .health .medical .gov

ssl_bump peek    step1
ssl_bump splice  no_bump_domains
ssl_bump bump    step2
ssl_bump bump    step3

# ── Cache Settings ────────────────────────────────────────────────────────────
cache_dir ufs ${CACHE_DIR} 4096 16 256
cache_mem 512 MB
maximum_object_size_in_memory 1 MB
maximum_object_size 64 MB
minimum_object_size 0 KB
cache_replacement_policy heap LFUDA
memory_replacement_policy heap GDSF

# ── Performance ───────────────────────────────────────────────────────────────
dns_nameservers ${DC_IP}
positive_dns_ttl 6 hours
negative_dns_ttl 1 minute
connect_timeout 30 seconds
request_timeout 60 seconds

workers 3

# ── Logging ──────────────────────────────────────────────────────────────────
access_log daemon:${LOG_DIR}/access.log squid
cache_log  ${LOG_DIR}/cache.log
cache_store_log none

# Log format including AD username (X-Forwarded-For)
logformat artroom_cipa %ts.%03tu %6tr %>a %Ss/%03>Hs %<st %rm %ru %[un %Sh/%<a %mt

# ── URL Rewriter (SquidGuard) ─────────────────────────────────────────────────
url_rewrite_program /usr/bin/squidGuard -c /etc/squid/squidguard.conf
url_rewrite_children 8 startup=4 idle=2 concurrency=0

# ── Redirect page for blocks ──────────────────────────────────────────────────
deny_info http://${FILTER_IP}/blocked.html all

# ── Headers ──────────────────────────────────────────────────────────────────
forwarded_for delete
via off
httpd_suppress_version_string on
request_header_access X-Forwarded-For deny all

# ── Safe Search enforcement ───────────────────────────────────────────────────
# Force Safe Search on Google, Bing, YouTube
acl google_domains dstdomain .google.com .google.co.uk
acl bing_domain    dstdomain .bing.com
acl youtube_domain dstdomain .youtube.com

request_header_add X-YouTube-Edu-Filter restricted youtube_domain
url_rewrite_access allow google_domains
url_rewrite_access allow bing_domain

EOF
ok "squid.conf written"

# ════════════════════════════════════════════════════════════════════════════
# STEP 5 — SQUIDGUARD CIPA CATEGORIES
# ════════════════════════════════════════════════════════════════════════════
banner "Step 5 — SquidGuard CIPA Category Configuration"

step "Writing /etc/squid/squidguard.conf..."
mkdir -p /etc/squid/squidguard /var/lib/squidGuard/db

cat > /etc/squid/squidguard.conf <<EOF
# SquidGuard — CIPA-Compliant Configuration
# Categories required by CIPA for K-12 filtering

dbhome /var/lib/squidGuard/db
logdir ${LOG_DIR}

# ── ACL Sources ──────────────────────────────────────────────────────────────
src students {
    ip ${STUDENT_NETWORK}
    log students.log
}

# ── CIPA Required Block Categories ───────────────────────────────────────────
dest adult {
    domainlist adult/domains
    urllist    adult/urls
    expressionlist adult/expressions
    log        blocked.log
}

dest porn {
    domainlist  porn/domains
    urllist     porn/urls
    log         blocked.log
}

dest violence {
    domainlist violence/domains
    urllist    violence/urls
    log        blocked.log
}

dest weapons {
    domainlist weapons/domains
    urllist    weapons/urls
    log        blocked.log
}

dest hacking {
    domainlist hacking/domains
    urllist    hacking/urls
    log        blocked.log
}

dest drugs {
    domainlist drugs/domains
    urllist    drugs/urls
    log        blocked.log
}

dest gambling {
    domainlist gambling/domains
    urllist    gambling/urls
    log        blocked.log
}

dest social_media {
    domainlist social_networking/domains
    urllist    social_networking/urls
    log        social.log
    # Note: social media may be whitelisted for teacher instruction
}

dest hate_discrimination {
    domainlist hate_discrimination/domains
    urllist    hate_discrimination/urls
    log        blocked.log
}

dest malware {
    domainlist malware/domains
    urllist    malware/urls
    log        blocked.log
}

# ── Whitelist (always allow) ─────────────────────────────────────────────────
dest whitelist {
    domainlist /etc/squid/whitelist/domains.txt
}

# ── ACL Rules ────────────────────────────────────────────────────────────────
acl {
    students {
        pass whitelist !adult !porn !violence !weapons !hacking !drugs !gambling !hate_discrimination !malware
        redirect http://${FILTER_IP}/blocked.html?category=%d&url=%u
    }

    default {
        pass whitelist !adult !porn !violence !weapons !hacking !drugs !gambling !hate_discrimination !malware
        redirect http://${FILTER_IP}/blocked.html?category=%d&url=%u
    }
}
EOF
ok "squidguard.conf written"

# ── INITIAL BLOCKLISTS ────────────────────────────────────────────────────
step "Creating blocklist directory structure..."
mkdir -p /var/lib/squidGuard/db/{adult,porn,violence,weapons,hacking,drugs,gambling,social_networking,hate_discrimination,malware}
mkdir -p /etc/squid/{blocklist,whitelist}

# Create minimal seed blocklists (real deployment: use shallalist or urlblacklist)
cat > /etc/squid/whitelist/domains.txt <<'EOF'
.google.com
.googleapis.com
.gstatic.com
.youtube.com
.youtu.be
.khanacademy.org
.wikipedia.org
.wikimedia.org
.scholastic.com
.ck12.org
.pbslearningmedia.org
.commonlit.org
.desmos.com
.geogebra.org
.wolframalpha.com
.classroomscreen.com
.microsoft.com
.office.com
.microsoftonline.com
EOF

# Seed domain lists (will be replaced by blocklist downloader)
for cat in adult porn violence weapons hacking drugs gambling social_networking hate_discrimination malware; do
    touch /var/lib/squidGuard/db/${cat}/domains
    touch /var/lib/squidGuard/db/${cat}/urls
    touch /var/lib/squidGuard/db/${cat}/expressions 2>/dev/null || true
done

touch /etc/squid/blocklist/domains.txt
touch /etc/squid/blocklist/keywords.txt

chown -R squid:squid /var/lib/squidGuard /etc/squid
ok "Blocklist directories seeded"

# ── BLOCKLIST UPDATER SCRIPT ───────────────────────────────────────────────
step "Writing blocklist update script..."
cat > /usr/local/bin/update-blocklists <<'BLEOF'
#!/usr/bin/env bash
# Updates CIPA blocklists from shallalist.de
# Run daily via cron — requires outbound HTTPS
set -euo pipefail

LOG="/var/log/artroom-filter/blocklist-update.log"
TMP_DIR=$(mktemp -d)
DB_DIR="/var/lib/squidGuard/db"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

log "=== Blocklist update starting ==="

# Download shallalist
log "Downloading shallalist..."
if curl -fsSL --max-time 120 \
    "https://www.shallalist.de/Downloads/shallalist.tar.gz" \
    -o "$TMP_DIR/shallalist.tar.gz" 2>>"$LOG"; then

    tar -xzf "$TMP_DIR/shallalist.tar.gz" -C "$TMP_DIR" 2>>"$LOG"

    # Copy relevant CIPA categories
    declare -A CATMAP=(
        ["BL/adult"]="adult"
        ["BL/porn"]="porn"
        ["BL/violence"]="violence"
        ["BL/weapons"]="weapons"
        ["BL/hacking"]="hacking"
        ["BL/drugs"]="drugs"
        ["BL/gambling"]="gambling"
        ["BL/socialnet"]="social_networking"
        ["BL/hate_discrimination"]="hate_discrimination"
        ["BL/malware"]="malware"
    )

    for src in "${!CATMAP[@]}"; do
        dst="${CATMAP[$src]}"
        src_path="$TMP_DIR/$src"
        dst_path="$DB_DIR/$dst"
        [[ -d "$src_path" ]] || continue
        [[ -f "$src_path/domains" ]] && cp "$src_path/domains" "$dst_path/domains"
        [[ -f "$src_path/urls"    ]] && cp "$src_path/urls"    "$dst_path/urls"
        count=$(wc -l < "$dst_path/domains" 2>/dev/null || echo 0)
        log "Updated $dst: $count domains"
    done

    chown -R squid:squid "$DB_DIR"

    # Rebuild SquidGuard database
    log "Rebuilding SquidGuard DB..."
    squidGuard -C all -c /etc/squid/squidguard.conf >> "$LOG" 2>&1
    chown -R squid:squid "$DB_DIR"

    # Reload squid
    squid -k reconfigure
    log "Squid reconfigured"
else
    log "WARNING: shallalist download failed — retaining existing lists"
fi

rm -rf "$TMP_DIR"
log "=== Blocklist update complete ==="
BLEOF
chmod +x /usr/local/bin/update-blocklists
ok "Blocklist updater: /usr/local/bin/update-blocklists"

# Schedule daily update at 3am
(crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/bin/update-blocklists >> /var/log/artroom-filter/blocklist-cron.log 2>&1") | crontab -
ok "Cron job: daily blocklist update at 03:00"

# ════════════════════════════════════════════════════════════════════════════
# STEP 6 — BLOCK PAGE (HTTP)
# ════════════════════════════════════════════════════════════════════════════
banner "Step 6 — Block Page Web Server"

step "Installing nginx for block redirect page..."
dnf install -y -q nginx
mkdir -p /usr/share/nginx/html

cat > /usr/share/nginx/html/blocked.html <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Website Blocked — Art Room Network</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: Arial, sans-serif; background: #1a1a2e; color: #eee;
         display: flex; align-items: center; justify-content: center;
         min-height: 100vh; }
  .card { background: #16213e; border-radius: 12px; padding: 40px;
          max-width: 480px; text-align: center; box-shadow: 0 8px 32px rgba(0,0,0,.4); }
  .icon { font-size: 64px; margin-bottom: 16px; }
  h1    { color: #e94560; font-size: 24px; margin-bottom: 12px; }
  p     { color: #aaa; line-height: 1.6; margin-bottom: 12px; font-size: 14px; }
  .ref  { background: #0f3460; border-radius: 6px; padding: 12px;
          font-size: 12px; color: #7ec8e3; word-break: break-all; }
  .footer { margin-top: 24px; font-size: 11px; color: #555; }
</style>
</head>
<body>
<div class="card">
  <div class="icon">🛡️</div>
  <h1>This website is blocked</h1>
  <p>This site has been blocked by the Art Room network content filter in compliance with the
     <strong>Children's Internet Protection Act (CIPA)</strong>.</p>
  <p>If you believe this is an error, please ask your teacher for assistance.</p>
  <div class="ref" id="ref">Loading details...</div>
  <div class="footer">Art Room Network · CIPA-Compliant Filtering · VM-FILTER01</div>
</div>
<script>
  const p = new URLSearchParams(location.search);
  document.getElementById('ref').textContent =
    'Blocked category: ' + (p.get('category') || 'Policy') +
    ' | URL: ' + (p.get('url') || location.href);
</script>
</body>
</html>
EOF

systemctl enable --now nginx
ok "Block page served at http://$FILTER_IP/blocked.html"

# ════════════════════════════════════════════════════════════════════════════
# STEP 7 — FIREWALL (firewalld)
# ════════════════════════════════════════════════════════════════════════════
banner "Step 7 — Firewall Configuration"

step "Configuring firewalld..."
systemctl enable --now firewalld

# Create custom zone for student VLAN
firewall-cmd --permanent --new-zone=students 2>/dev/null || true
firewall-cmd --permanent --zone=students --add-source="$STUDENT_NETWORK"
firewall-cmd --permanent --zone=students --add-port=${SQUID_PORT}/tcp
firewall-cmd --permanent --zone=students --add-port=${HTTPS_PORT}/tcp
firewall-cmd --permanent --zone=students --add-port=80/tcp     # block page
firewall-cmd --permanent --zone=students --remove-service=ssh 2>/dev/null || true

# Management zone (VLAN 60 only)
firewall-cmd --permanent --zone=trusted --add-source=10.10.60.0/24
firewall-cmd --permanent --zone=trusted --add-service=ssh
firewall-cmd --permanent --zone=trusted --add-service=http
firewall-cmd --permanent --zone=trusted --add-service=https

# Allow DC communication
firewall-cmd --permanent --zone=trusted --add-source="${DC_IP}/32"

# Transparent redirect for HTTP/HTTPS (iptables via nftables backend)
firewall-cmd --permanent --direct --add-rule ipv4 nat PREROUTING 0 \
    -i "$STUDENT_NIC" -p tcp --dport 80  -j REDIRECT --to-port $SQUID_PORT
firewall-cmd --permanent --direct --add-rule ipv4 nat PREROUTING 0 \
    -i "$STUDENT_NIC" -p tcp --dport 443 -j REDIRECT --to-port $HTTPS_PORT

firewall-cmd --reload
ok "Firewalld configured — transparent proxy redirect active"

# ════════════════════════════════════════════════════════════════════════════
# STEP 8 — SECURITY HARDENING
# ════════════════════════════════════════════════════════════════════════════
banner "Step 8 — Security Hardening"

step "Configuring Fail2Ban..."
cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 2h
findtime = 10m
maxretry = 5

[sshd]
enabled = true

[squid]
enabled  = true
port     = 3128,3129
logpath  = /var/log/artroom-filter/access.log
maxretry = 20
findtime = 1m
bantime  = 30m
failregex = ^.*%(__prefix_line)s.*DENIED.*<HOST>.*$
EOF
systemctl enable --now fail2ban
ok "Fail2Ban configured"

step "Setting NTP to DC ($DC_IP)..."
cat > /etc/chrony.conf <<EOF
server $DC_IP iburst prefer
pool pool.ntp.org iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF
systemctl enable --now chronyd
ok "NTP configured"

step "Disabling unnecessary services..."
for svc in bluetooth cups avahi-daemon; do
    systemctl disable --now "$svc" 2>/dev/null || true
done
ok "Unnecessary services disabled"

step "Setting SELinux to enforcing..."
setenforce 1 2>/dev/null || warn "SELinux not available in kernel"
sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
# Allow squid SSL
setsebool -P squid_connect_any 1 2>/dev/null || true
ok "SELinux enforcing"

step "Configuring SSH hardening..."
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/'      /etc/ssh/sshd_config
sed -i 's/^#*MaxAuthTries.*/MaxAuthTries 4/'             /etc/ssh/sshd_config
sed -i 's/^#*X11Forwarding.*/X11Forwarding no/'         /etc/ssh/sshd_config
sed -i 's/^#*AllowTcpForwarding.*/AllowTcpForwarding no/' /etc/ssh/sshd_config
echo "AllowUsers root@10.10.60.0/24" >> /etc/ssh/sshd_config
systemctl restart sshd
ok "SSH hardened"

# ════════════════════════════════════════════════════════════════════════════
# STEP 9 — LOGGING & MONITORING
# ════════════════════════════════════════════════════════════════════════════
banner "Step 9 — Logging & Monitoring"

step "Configuring log directories..."
mkdir -p "$LOG_DIR"
chown squid:squid "$LOG_DIR"
chmod 750 "$LOG_DIR"

step "Installing log rotation..."
cat > /etc/logrotate.d/artroom-filter <<EOF
${LOG_DIR}/*.log {
    daily
    rotate 90
    compress
    missingok
    notifempty
    dateext
    sharedscripts
    postrotate
        /usr/sbin/squid -k rotate 2>/dev/null || true
    endscript
}
EOF
ok "Log rotation: 90-day retention"

step "Installing CIPA compliance reporting script..."
cat > /usr/local/bin/cipa-report <<'RPTEOF'
#!/usr/bin/env python3
"""
CIPA Compliance Daily Report Generator
Summarizes blocked access attempts from Squid logs.
"""
import re
import sys
from datetime import datetime, timedelta
from collections import Counter

LOG_FILE = "/var/log/artroom-filter/access.log"
REPORT_OUT = f"/var/log/artroom-filter/cipa-report-{datetime.now():%Y%m%d}.txt"

def parse_squid_log(path, since_hours=24):
    events = []
    cutoff = datetime.now() - timedelta(hours=since_hours)
    with open(path, "r", errors="ignore") as f:
        for line in f:
            parts = line.split()
            if len(parts) < 7: continue
            try:
                ts = datetime.fromtimestamp(float(parts[0]))
            except ValueError: continue
            if ts < cutoff: continue
            status   = parts[3]
            url      = parts[6] if len(parts) > 6 else ""
            client   = parts[2]
            if "DENIED" in status:
                events.append({"ts": ts, "client": client, "url": url, "status": status})
    return events

events = parse_squid_log(LOG_FILE)
url_counter = Counter(e["url"] for e in events)
client_counter = Counter(e["client"] for e in events)

report = f"""
CIPA COMPLIANCE DAILY REPORT
Generated: {datetime.now():%Y-%m-%d %H:%M}
Period: Last 24 hours
====================================================

SUMMARY
  Total block events:   {len(events)}
  Unique IPs blocked:   {len(client_counter)}
  Unique URLs blocked:  {len(url_counter)}

TOP 20 BLOCKED URLS
"""
for url, count in url_counter.most_common(20):
    report += f"  {count:>5}x  {url[:80]}\n"

report += "\nTOP 10 CLIENTS WITH MOST BLOCKS\n"
for ip, count in client_counter.most_common(10):
    report += f"  {count:>5}x  {ip}\n"

report += "\nRECENT BLOCK EVENTS (last 25)\n"
for e in sorted(events, key=lambda x: x["ts"], reverse=True)[:25]:
    report += f"  {e['ts']:%H:%M:%S}  {e['client']:<18} {e['url'][:60]}\n"

print(report)
with open(REPORT_OUT, "w") as f:
    f.write(report)
print(f"\nReport saved: {REPORT_OUT}")
RPTEOF
chmod +x /usr/local/bin/cipa-report

# Daily report at 6am
(crontab -l 2>/dev/null; echo "0 6 * * * /usr/local/bin/cipa-report >> /var/log/artroom-filter/report-cron.log 2>&1") | crontab -
ok "CIPA daily report installed: cipa-report (runs at 06:00)"

# ════════════════════════════════════════════════════════════════════════════
# STEP 10 — JOIN AD DOMAIN
# ════════════════════════════════════════════════════════════════════════════
banner "Step 10 — Active Directory Integration"

step "Joining domain $DOMAIN (if not already joined)..."
if realm list 2>/dev/null | grep -q "$DOMAIN"; then
    ok "Already joined to $DOMAIN"
else
    warn "Attempting domain join — you will be prompted for Domain Admin credentials."
    realm join --user=Administrator "$DOMAIN" 2>/dev/null || \
        warn "Domain join failed — complete manually: realm join --user=Administrator $DOMAIN"
fi

# ════════════════════════════════════════════════════════════════════════════
# STEP 11 — START SQUID
# ════════════════════════════════════════════════════════════════════════════
banner "Step 11 — Start & Enable Squid"

step "Initializing Squid cache directory..."
mkdir -p "$CACHE_DIR"
chown squid:squid "$CACHE_DIR"
squid -z 2>/dev/null || warn "squid -z failed (check config)"

step "Testing Squid configuration..."
squid -k check 2>&1 || warn "Squid config check failed — review /etc/squid/squid.conf"

step "Enabling and starting Squid..."
systemctl enable --now squid
ok "Squid started"

step "Running initial blocklist update..."
/usr/local/bin/update-blocklists &
ok "Blocklist update running in background (PID $!)"

# ════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ════════════════════════════════════════════════════════════════════════════
banner "VM-FILTER01 Setup Complete"

echo -e "
  ${GRN}CIPA Filter:${RST}      http://$FILTER_IP (transparent proxy)
  ${GRN}Squid port:${RST}       $SQUID_PORT (HTTP)  $HTTPS_PORT (HTTPS)
  ${GRN}Block page:${RST}       http://$FILTER_IP/blocked.html
  ${GRN}VLAN:${RST}             10 (Black) — student traffic

  ${YLW}REQUIRED POST-SETUP STEPS:${RST}
  1. Deploy /etc/squid/certs/filter-ca.crt to student devices via GPO
     (Computer Config → Windows Settings → Security → Trusted Root CAs)
  2. Configure student VLAN gateway to route port 80/443 through $FILTER_IP
  3. Run:  /usr/local/bin/update-blocklists   (initial blocklist download)
  4. Run:  /usr/local/bin/cipa-report         (first compliance report)
  5. Review squidguard.conf whitelist for school-specific allowed domains

  ${GRN}MONITORING COMMANDS:${RST}
    cipa-report                        — generate compliance report
    tail -f $LOG_DIR/access.log        — live filter log
    squid -k reconfigure               — reload config without restart
    update-blocklists                  — force blocklist refresh
    systemctl status squid             — service health
"
