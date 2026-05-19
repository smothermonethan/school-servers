#!/usr/bin/env bash
# =============================================================================
#  HOME WI-FI PROTECTION INFRASTRUCTURE — AlmaLinux 9 Setup Script (FIXED)
#  Covers: HOME-FILTER01 — Native Content Filter Engine
#  Network Environment: TEAMSMOWIFI (Home Network Implementation)
#  Run as root: sudo bash setup-almalinux.sh
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

# ── GLOBAL CONFIG — EDIT BEFORE RUNNING ──────────────────────────────────────
HOSTNAME="HOME-FILTER01"
FILTER_IP="192.168.1.5"           # Static IP assigned to this filter machine
GATEWAY="192.168.1.1"             # Your home Wi-Fi Router Gateway IP
DNS_IP="192.168.1.1"              # Your home Wi-Fi Router or Upstream DNS
DOMAIN="teamsmowifi.local"        # Custom local home domain

# Network interface context for home Wi-Fi/LAN client forwarding
HOME_NETWORK="192.168.1.0/24"
HOME_NIC="ens18"                  # Network interface card facing home clients
UPSTREAM_NIC="ens19"              # Network interface card facing external link

SQUID_PORT=3128
HTTPS_PORT=3129                  # Interception port for SSL inspection

# Premium modern open-source blocklist source (Replaces dead ShallaList)
UT1_BLACKLIST_URL="https://dsi.ut-capitole.fr/blacklists/download/blacklists.tar.gz"

# Certificate info for Home SSL bump
CERT_COUNTRY="US"
CERT_STATE="Indiana"
CERT_CITY="Fort Wayne"
CERT_ORG="TEAMSMOWIFI Home Security"
CERT_CN="TEAMSMOWIFI-Filter-CA"

LOG_DIR="/var/log/teamsmowifi-filter"
CACHE_DIR="/var/spool/squid"
ADMIN_EMAIL="admin@teamsmowifi.local"
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
CYN='\033[0;36m'; WHT='\033[1;37m'; RST='\033[0m'

banner() { echo -e "\n${CYN}$(printf '=%.0s' {1..70})${RST}\n  ${WHT}$1${RST}\n${CYN}$(printf '=%.0s' {1..70})${RST}"; }
step()   { echo -e "  ${YLW}[*]${RST} $1"; }
ok()     { echo -e "  ${GRN}[+]${RST} $1"; }
warn()   { echo -e "  ${RED}[!]${RST} $1"; }

[[ $EUID -eq 0 ]] || { warn "Run as root: sudo bash $0"; exit 1; }

banner "HOME-FILTER01 — Content Filter Setup — TEAMSMOWIFI"

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
$GATEWAY    HOME-ROUTER router.${DOMAIN} ${DOMAIN}
EOF
ok "/etc/hosts updated"

step "Updating system packages..."
dnf update -y -q
ok "System updated"

step "Installing EPEL and PowerTools/CRB repository plugins..."
dnf install -y -q epel-release
dnf config-manager --set-enabled crb 2>/dev/null || \
    dnf config-manager --set-enabled powertools 2>/dev/null || true
ok "EPEL + CRB enabled"

step "Installing packages (Fixed AppStream dependencies for AlmaLinux 9)..."
dnf install -y -q \
    squid \
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
    s-nail \
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
ok "All system software modules resolved and installed."

# ════════════════════════════════════════════════════════════════════════════
# STEP 2 — NETWORK CONFIGURATION
# ════════════════════════════════════════════════════════════════════════════
banner "Step 2 — Network Configuration"

step "Configuring home network interface connection rules..."
nmcli con mod "$HOME_NIC" \
    ipv4.method manual \
    ipv4.addresses "${FILTER_IP}/24" \
    ipv4.gateway "$GATEWAY" \
    ipv4.dns "$DNS_IP" \
    ipv4.dns-search "$DOMAIN" \
    connection.autoconnect yes 2>/dev/null || \
nmcli con add type ethernet con-name "$HOME_NIC" ifname "$HOME_NIC" \
    ipv4.method manual \
    ipv4.addresses "${FILTER_IP}/24" \
    ipv4.gateway "$GATEWAY" \
    ipv4.dns "$DNS_IP" \
    ipv4.dns-search "$DOMAIN"

nmcli con up "$HOME_NIC" 2>/dev/null || true
ok "Home LAN Interface active: $HOME_NIC → $FILTER_IP"

step "Enabling system core IP packet forwarding..."
cat > /etc/sysctl.d/99-filter.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.log_martians = 1
EOF
sysctl -p /etc/sysctl.d/99-filter.conf -q
ok "Kernel IP routing stack hardened."

# ════════════════════════════════════════════════════════════════════════════
# STEP 3 — SSL CERTIFICATE FOR SSL BUMP
# ════════════════════════════════════════════════════════════════════════════
banner "Step 3 — SSL Inspection Certificate Engine"

step "Generating custom home network CA encryption keys..."
mkdir -p /etc/squid/certs
cd /etc/squid/certs

openssl genrsa -out filter-ca.key 4096 2>/dev/null
openssl req -new -x509 -days 3650 -key filter-ca.key -out filter-ca.crt \
    -subj "/C=${CERT_COUNTRY}/ST=${CERT_STATE}/L=${CERT_CITY}/O=${CERT_ORG}/CN=${CERT_CN}" \
    2>/dev/null

openssl x509 -in filter-ca.crt -outform DER -out filter-ca.der

# Setup native Squid SSL caching engine database
step "Initializing secure database folder mappings..."
mkdir -p /var/lib/squid
rm -rf /var/lib/squid/ssl_db

CERT_GEN_PATH="/usr/lib64/squid/security_file_certgen"
if [ ! -x "$CERT_GEN_PATH" ]; then
    CERT_GEN_PATH="/usr/lib/squid/security_file_certgen"
fi

$CERT_GEN_PATH -c -s /var/lib/squid/ssl_db -M 4MB 2>/dev/null
chown -R squid:squid /var/lib/squid /etc/squid/certs
chmod 700 /etc/squid/certs
ok "CA Engine deployment initialized successfully."
cd /

# ════════════════════════════════════════════════════════════════════════════
# STEP 4 — SQUID NATIVE CONFIGURATION
# ════════════════════════════════════════════════════════════════════════════
banner "Step 4 — Native Squid Filter Configuration"

step "Structuring /etc/squid/squid.conf..."
mkdir -p /var/lib/squid/db
mkdir -p /etc/squid/whitelist
touch /etc/squid/whitelist/domains.txt

cat > /etc/squid/squid.conf <<EOF
# ── TRANSPARENT PORT ROUTING + SSL INSPECTION ────────────────────────────────
http_port ${FILTER_IP}:${SQUID_PORT} intercept
https_port ${FILTER_IP}:${HTTPS_PORT} intercept ssl-bump cert=/etc/squid/certs/filter-ca.crt key=/etc/squid/certs/filter-ca.key generate-host-certificates=on dynamic_cert_mem_cache_size=4MB

# Dynamic Certificate Handler Link
sslcrtd_program ${CERT_GEN_PATH} -s /var/lib/squid/ssl_db -M 4MB
acl step1 at_step SslBump1
ssl_bump peek step1
ssl_bump bump all

# ── NETWORK ACCESS CONFIGURATION ─────────────────────────────────────────────
acl localnet src ${HOME_NETWORK}
acl SSL_ports port 443
acl Safe_ports port 80
acl Safe_ports port 443
acl CONNECT method CONNECT

# ── HOMELAN ALLOWED RULES ────────────────────────────────────────────────────
acl home_whitelist dstdomain "/etc/squid/whitelist/domains.txt"
http_access allow home_whitelist

# ── NATIVE POLICY ENFORCEMENT DATABASES ──────────────────────────────────────
acl block_adult dstdomain "/var/lib/squid/db/adult"
acl block_porn dstdomain "/var/lib/squid/db/porn"
acl block_violence dstdomain "/var/lib/squid/db/violence"
acl block_weapons dstdomain "/var/lib/squid/db/weapons"
acl block_hacking dstdomain "/var/lib/squid/db/hacking"
acl block_drugs dstdomain "/var/lib/squid/db/drogue"
acl block_gambling dstdomain "/var/lib/squid/db/gambling"
acl block_socialnet dstdomain "/var/lib/squid/db/social_networks"
acl block_malware dstdomain "/var/lib/squid/db/malware"
acl block_phishing dstdomain "/var/lib/squid/db/phishing"

# ── DENIAL ACTIONS & REDIRECT TARGETS ────────────────────────────────────────
deny_info http://${FILTER_IP}/blocked.html?category=Adult_Content block_adult
http_access deny block_adult

deny_info http://${FILTER_IP}/blocked.html?category=Pornography block_porn
http_access deny block_porn

deny_info http://${FILTER_IP}/blocked.html?category=Violence block_violence
http_access deny block_violence

deny_info http://${FILTER_IP}/blocked.html?category=Weapons block_weapons
http_access deny block_weapons

deny_info http://${FILTER_IP}/blocked.html?category=Hacking block_hacking
http_access deny block_hacking

deny_info http://${FILTER_IP}/blocked.html?category=Narcotics block_drugs
http_access deny block_drugs

deny_info http://${FILTER_IP}/blocked.html?category=Gambling block_gambling
http_access deny block_gambling

deny_info http://${FILTER_IP}/blocked.html?category=Social_Media block_socialnet
http_access deny block_socialnet

deny_info http://${FILTER_IP}/blocked.html?category=Malicious_Software block_malware
http_access deny block_malware

deny_info http://${FILTER_IP}/blocked.html?category=Phishing_Scams block_phishing
http_access deny block_phishing

# General Access Controls
http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
http_access allow localnet
http_access allow localhost
http_access deny all

# System Optimization parameters
coredump_dir ${CACHE_DIR}
refresh_pattern ^ftp:           1440    20%     10080
refresh_pattern ^gopher:        1440    0%      1440
refresh_pattern -i (/cgi-bin/|\?) 0     0%      0
refresh_pattern .               0       20%     4320
EOF
ok "/etc/squid/squid.conf written cleanly."

# ════════════════════════════════════════════════════════════════════════════
# STEP 5 — STABLE NATIVE COMPLIANCE REFRESH SCRIPT
# ════════════════════════════════════════════════════════════════════════════
banner "Step 5 — Setting up Blocklist Database Core"

cat << 'EOF' > /usr/local/bin/update-blocklists
#!/usr/bin/env bash
set -euo pipefail

DL_DIR="/tmp/ut1-dl"
DB_DIR="/var/lib/squid/db"
URL="https://dsi.ut-capitole.fr/blacklists/download/blacklists.tar.gz"

echo "Downloading official university blocklists..."
rm -rf "$DL_DIR" && mkdir -p "$DL_DIR"
wget -qO "$DL_DIR/blacklists.tar.gz" "$URL"

echo "Parsing databases..."
tar -zxf "$DL_DIR/blacklists.tar.gz" -C "$DL_DIR"

mkdir -p "$DB_DIR"
CATEGORIES=("adult" "porn" "violence" "weapons" "hacking" "drogue" "gambling" "social_networks" "malware" "phishing")

for cat in "${CATEGORIES[@]}"; do
    if [ -f "$DL_DIR/blacklists/$cat/domains" ]; then
        # Add a dot prefix so squid automatically blocks all nested subdomains natively
        sed 's/^/\./' "$DL_DIR/blacklists/$cat/domains" > "$DB_DIR/$cat"
        echo "Synchronized category: [$cat]"
    fi
done

rm -rf "$DL_DIR"
chown -R squid:squid "$DB_DIR"
chmod -R 644 "$DB_DIR"

echo "Reloading Native Squid Filters..."
squid -k reconfigure &>/dev/null || true
echo "Blocklist processing successfully refreshed."
EOF

chmod +x /usr/local/bin/update-blocklists
ok "Native updater engine registered at /usr/local/bin/update-blocklists"

# ════════════════════════════════════════════════════════════════════════════
# STEP 6 — FIREWALLD NETWORKING TRANSPARENCY
# ════════════════════════════════════════════════════════════════════════════
banner "Step 6 — Transparent Firewalld Redirection"

systemctl enable --now firewalld &>/dev/null

# Bind interfaces into the correct security processing boundaries
nmcli device modify "$HOME_NIC" connection.zone internal || true
nmcli device modify "$UPSTREAM_NIC" connection.zone external || true

# Forward target device web ports directly into your Squid processing engines
firewall-cmd --permanent --zone=internal --add-forward-port=port=80:proto=tcp:toport=$SQUID_PORT
firewall-cmd --permanent --zone=internal --add-forward-port=port=443:proto=tcp:toport=$HTTPS_PORT
firewall-cmd --permanent --zone=internal --add-port=$SQUID_PORT/tcp
firewall-cmd --permanent --zone=internal --add-port=$HTTPS_PORT/tcp
firewall-cmd --permanent --zone=internal --add-port=80/tcp  # For the rejection blockpage
firewall-cmd --reload &>/dev/null
ok "Firewall traffic interception pipelines active."

# ════════════════════════════════════════════════════════════════════════════
# STEP 7 — LIGHTWEIGHT NATIVE REJECTION BLOCKPAGE
# ════════════════════════════════════════════════════════════════════════════
banner "Step 7 — Lightweight Blockpage Host Server"

dnf install -y -q httpd
cat << 'EOF' > /var/www/html/blocked.html
<!DOCTYPE html>
<html>
<head>
    <title>Access Policy Denied</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; text-align: center; margin-top: 10%; background-color: #f3f4f6; color: #1f2937; }
        .box { max-width: 550px; margin: auto; padding: 40px; background: white; border-radius: 12px; box-shadow: 0 10px 15px -3px rgba(0,0,0,0.1); }
        h1 { color: #ef4444; font-size: 28px; margin-bottom: 10px; }
        p { font-size: 16px; line-height: 1.6; color: #4b5563; }
        .badge { display: inline-block; padding: 6px 12px; background: #fee2e2; color: #991b1b; font-weight: bold; border-radius: 6px; font-size: 14px; margin-top: 15px; }
        .footer { font-size: 11px; color: #9ca3af; margin-top: 30px; border-top: 1px solid #e5e7eb; padding-top: 15px; }
    </style>
</head>
<body>
    <div class="box">
        <h1>Website Access Blocked</h1>
        <p>Your connection attempt was flagged and restricted by local network protection protocols.</p>
        <div class="badge">Content Filter Policy Restricted</div>
        <div class="footer">TEAMSMOWIFI Home Security Operations &bull; HOME-FILTER01</div>
    </div>
</body>
</html>
EOF
systemctl enable --now httpd &>/dev/null
ok "Local landing alert webpage initialized."

# ════════════════════════════════════════════════════════════════════════════
# STEP 8 — MONITORING & REPORT IMPLEMENTATION
# ════════════════════════════════════════════════════════════════════════════
banner "Step 8 — Reporting Utility Implementation"

cat << 'EOF' > /usr/local/bin/cipa-report
#!/usr/bin/env bash
echo "=================================================================="
echo "               TEAMSMOWIFI HOME PROTECTION AUDIT REPORT           "
echo "=================================================================="
echo "Generated: $(date)"
echo "Filter Daemon Run State: $(systemctl is-active squid)"
echo -e "\nActive Enforcement Metrics:"
for rule in /var/lib/squid/db/*; do
    [ -f "$rule" ] && printf "  Rule Category [%-16s] -> Loaded %s protected domains\n" "$(basename "$rule")" "$(wc -l < "$rule")"
done
echo "=================================================================="
EOF
chmod +x /usr/local/bin/cipa-report
ok "Reporting binary linked to command environment."

# ════════════════════════════════════════════════════════════════════════════
# STEP 9 — ACTIVATION & SUMMARY
# ════════════════════════════════════════════════════════════════════════════
banner "Step 9 — Activating Protective Framework"

step "Executing initial blocklist sync loop in background..."
/usr/local/bin/update-blocklists &
ok "Blocklist synchronization task offloaded to background (PID $!)"

step "Starting core processing daemon..."
systemctl enable --now squid &>/dev/null
ok "Squid content scanning service engine initialized."

banner "HOME-FILTER01 Deployment Execution Complete"
echo -e "
  ${GRN}Home Network Protection Active:${RST} http://$FILTER_IP
  ${GRN}Squid Inbound Mirror Ports:${RST}     $SQUID_PORT (HTTP) / $HTTPS_PORT (Interception Mode)
  ${GRN}Enforcement Target Scope:${RST}       TEAMSMOWIFI Home Network Scope ($HOME_NETWORK)

  ${YLW}CRITICAL LOCAL CONFIGURATION STEPS REQUIRED:${RST}
  1. Install your certificate file located at:
     ${CYN}/etc/squid/certs/filter-ca.crt${RST} onto your household personal computers/devices 
     as a 'Trusted Root Certification Authority' to allow HTTPS scanning.
  2. Map your home network switch or router to forward client web ports (80/443) 
     directly towards this system IP ($FILTER_IP).
  3. You can review your active system block counts at any time by running:
     ${CYN}/usr/local/bin/cipa-report${RST}
"
