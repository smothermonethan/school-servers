#!/usr/bin/env bash
# =============================================================================
#  ART ROOM INFRASTRUCTURE — AlmaLinux 9 Setup Script (FIXED & WORKING)
#  Covers: VM-FILTER01 — Native CIPA-Compliant Content Filter
#          Student traffic on Black VLAN 10
#  Run as root:  sudo bash setup-almalinux.sh
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

# ── GLOBAL CONFIG ────────────────────────────────────────────────────────────
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
HTTPS_PORT=3129                  # Port for SSL inspection

# Modern, fully supported CIPA-compliant educational database source
UT1_BLACKLIST_URL="https://dsi.ut-capitole.fr/blacklists/download/blacklists.tar.gz"

# Terminal Colors
RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[0;33m'
BLU='\033[0;34m'
RST='\033[0m'

# Helper UI functions
step() { echo -e "\n${BLU}[STEP]${RST} $1..."; }
ok() { echo -e "${GRN}[OK]${RST} $1"; }
error() { echo -e "${RED}[ERROR]${RST} $1"; exit 1; }
banner() {
    echo -e "${GRN}=====================================================================${RST}"
    echo -e "  $1"
    echo -e "${GRN}=====================================================================${RST}"
}

# Ensure running as root
if [ "$EUID" -ne 0 ]; then
   error "This script must be run as root (sudo)."
fi

# ════════════════════════════════════════════════════════════════════════════
# STEP 1: REPOSITORY SETUP & DEPENDENCY INSTALLATION
# ════════════════════════════════════════════════════════════════════════════
step "Configuring Hostname and Repositories"
hostnamectl set-hostname "$HOSTNAME"

# Install core plugins required to toggle CRB
dnf install -y -q dnf-plugins-core epel-release

# Enable CodeReady Builder (CRB) for AlmaLinux 9 dependencies
dnf config-manager --set-enabled crb || true

step "Installing System Packages (Fixed AppStream dependencies)"
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

ok "All software packages resolved and successfully installed."

# ════════════════════════════════════════════════════════════════════════════
# STEP 2: NETWORK & TRANSPARENT FIREWALL RULES
# ════════════════════════════════════════════════════════════════════════════
step "Configuring Network Interfaces and Firewalld"
systemctl enable --now firewalld

# Assign zones
nmcli device modify "$STUDENT_NIC" connection.zone internal || true
nmcli device modify "$UPSTREAM_NIC" connection.zone external || true

# Enable Transparent Proxy Interception via Port Redirection
firewall-cmd --permanent --zone=internal --add-forward-port=port=80:proto=tcp:toport=$SQUID_PORT
firewall-cmd --permanent --zone=internal --add-forward-port=port=443:proto=tcp:toport=$HTTPS_PORT
firewall-cmd --permanent --zone=internal --add-port=$SQUID_PORT/tcp
firewall-cmd --permanent --zone=internal --add-port=$HTTPS_PORT/tcp
firewall-cmd --permanent --zone=internal --add-port=80/tcp # For block page access
firewall-cmd --reload
ok "Firewall transparent routing configured."

# ════════════════════════════════════════════════════════════════════════════
# STEP 3: SSL INSPECTION CERTIFICATE COMPILATION
# ════════════════════════════════════════════════════════════════════════════
step "Generating Self-Signed CA for SSL Inspection"
CERT_DIR="/etc/squid/certs"
mkdir -p "$CERT_DIR"
chmod 700 "$CERT_DIR"

if [ ! -f "$CERT_DIR/filter-ca.crt" ]; then
    openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
        -subj "/C=US/ST=State/L=City/O=ArtRoomSchool/CN=ArtRoom Filtering Root CA" \
        -keyout "$CERT_DIR/filter-ca.key" -out "$CERT_DIR/filter-ca.crt"
    chmod 400 "$CERT_DIR/filter-ca.key"
fi

# Setup Squid Certificate Database
step "Initializing Squid SSL DB"
mkdir -p /var/lib/squid
rm -rf /var/lib/squid/ssl_db

CERT_GEN_PATH="/usr/lib64/squid/security_file_certgen"
if [ ! -x "$CERT_GEN_PATH" ]; then
    CERT_GEN_PATH="/usr/lib/squid/security_file_certgen"
fi

$CERT_GEN_PATH -c -s /var/lib/squid/ssl_db -M 4MB
chown -R squid:squid /var/lib/squid
ok "SSL Inspection components prepared."

# ════════════════════════════════════════════════════════════════════════════
# STEP 4: GENERATE NATIVE SQUID CONFIGURATION
# ════════════════════════════════════════════════════════════════════════════
step "Writing Native Squid Configuration (/etc/squid/squid.conf)"
mkdir -p /etc/squid/whitelist
mkdir -p /var/lib/squid/db
touch /etc/squid/whitelist/domains.txt

cat << 'EOF' > /etc/squid/squid.conf
# ── NATIVE TRANSPARENT PORTS WITH SSL BUMP ────────────────────────────────────
http_port 10.10.10.5:3128 intercept
https_port 10.10.10.5:3129 intercept ssl-bump cert=/etc/squid/certs/filter-ca.crt key=/etc/squid/certs/filter-ca.key generate-host-certificates=on dynamic_cert_mem_cache_size=4MB

# SSL Bump Engine Rules
sslcrtd_program /usr/lib64/squid/security_file_certgen -s /var/lib/squid/ssl_db -M 4MB
acl step1 at_step SslBump1
ssl_bump peek step1
ssl_bump bump all

# ── ACCESS RULES ──────────────────────────────────────────────────────────────
acl localnet src 10.10.10.0/24
acl SSL_ports port 443
acl Safe_ports port 80
acl Safe_ports port 443
acl CONNECT method CONNECT

# ── SCHOOL WHITELISTS ─────────────────────────────────────────────────────────
acl school_whitelist dstdomain "/etc/squid/whitelist/domains.txt"
http_access allow school_whitelist

# ── CIPA COMPLIANT NATIVE DATABASES ───────────────────────────────────────────
acl cipa_adult dstdomain "/var/lib/squid/db/adult"
acl cipa_porn dstdomain "/var/lib/squid/db/porn"
acl cipa_violence dstdomain "/var/lib/squid/db/violence"
acl cipa_weapons dstdomain "/var/lib/squid/db/weapons"
acl cipa_hacking dstdomain "/var/lib/squid/db/hacking"
acl cipa_drugs dstdomain "/var/lib/squid/db/drogue"
acl cipa_gambling dstdomain "/var/lib/squid/db/gambling"
acl cipa_socialnet dstdomain "/var/lib/squid/db/social_networks"
acl cipa_malware dstdomain "/var/lib/squid/db/malware"
acl cipa_phishing dstdomain "/var/lib/squid/db/phishing"

# ── DENIALS & REDIRECTS (Native Block Page) ──────────────────────────────────
deny_info http://10.10.10.5/blocked.html?category=Adult_Content cipa_adult
http_access deny cipa_adult

deny_info http://10.10.10.5/blocked.html?category=Pornography cipa_porn
http_access deny cipa_porn

deny_info http://10.10.10.5/blocked.html?category=Violence cipa_violence
http_access deny cipa_violence

deny_info http://10.10.10.5/blocked.html?category=Weapons cipa_weapons
http_access deny cipa_weapons

deny_info http://10.10.10.5/blocked.html?category=Hacking cipa_hacking
http_access deny cipa_hacking

deny_info http://10.10.10.5/blocked.html?category=Narcotics cipa_drugs
http_access deny cipa_drugs

deny_info http://10.10.10.5/blocked.html?category=Gambling cipa_gambling
http_access deny cipa_gambling

deny_info http://10.10.10.5/blocked.html?category=Social_Media cipa_socialnet
http_access deny cipa_socialnet

deny_info http://10.10.10.5/blocked.html?category=Malicious_Sites cipa_malware
http_access deny cipa_malware

deny_info http://10.10.10.5/blocked.html?category=Phishing_Scams cipa_phishing
http_access deny cipa_phishing

# Standard Global Security Policies
http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
http_access allow localnet
http_access allow localhost
http_access deny all

# System Optimizations
coredump_dir /var/spool/squid
refresh_pattern ^ftp:           1440    20%     10080
refresh_pattern ^gopher:        1440    0%      1440
refresh_pattern -i (/cgi-bin/|\?) 0     0%      0
refresh_pattern .               0       20%     4320
EOF
ok "Native Squid config layout established without broken redirectors."

# ════════════════════════════════════════════════════════════════════════════
# STEP 5: AUTOMATED COMPLIANT BLOCKLIST UPDATER SCRIPT
# ════════════════════════════════════════════════════════════════════════════
step "Compiling native updater engine (/usr/local/bin/update-blocklists)"
cat << 'EOF' > /usr/local/bin/update-blocklists
#!/usr/bin/env bash
set -euo pipefail

DL_DIR="/tmp/ut1-dl"
DB_DIR="/var/lib/squid/db"
URL="https://dsi.ut-capitole.fr/blacklists/download/blacklists.tar.gz"

echo "Downloading official Toulouse university blocklists..."
rm -rf "$DL_DIR" && mkdir -p "$DL_DIR"
wget -qO "$DL_DIR/blacklists.tar.gz" "$URL"

echo "Unpacking databases..."
tar -zxf "$DL_DIR/blacklists.tar.gz" -C "$DL_DIR"

mkdir -p "$DB_DIR"
CATEGORIES=("adult" "porn" "violence" "weapons" "hacking" "drogue" "gambling" "social_networks" "malware" "phishing")

for cat in "${CATEGORIES[@]}"; do
    if [ -f "$DL_DIR/blacklists/$cat/domains" ]; then
        # Add a dot prefix to all entries to recursively block subdomains natively inside Squid
        sed 's/^/\./' "$DL_DIR/blacklists/$cat/domains" > "$DB_DIR/$cat"
        echo "Successfully indexed native category: [$cat]"
    fi
done

rm -rf "$DL_DIR"
echo "Fixing permissions..."
chown -R squid:squid "$DB_DIR"
chmod -R 644 "$DB_DIR"

echo "Reloading native Squid filter rules..."
squid -k reconfigure
echo "Blocklist processing successfully refreshed."
EOF

chmod +x /usr/local/bin/update-blocklists
ok "Native update routine registered."

# ── HOOK UP COMPLIANCE REPORT GENERATOR ──────────────────────────────────────
step "Compiling compliance tool (/usr/local/bin/cipa-report)"
cat << 'EOF' > /usr/local/bin/cipa-report
#!/usr/bin/env bash
echo "=================================================="
echo "          CIPA COMPLIANCE AUDIT AUDIT REPORT      "
echo "=================================================="
echo "Generated on: $(date)"
echo "Filter Engine Status:"
systemctl is-active squid || echo "INACTIVE"
echo -e "\nIndexed Rules Metrics:"
for f in /var/lib/squid/db/*; do
    printf "  Category [%-18s]: %s entries listed\n" "$(basename "$f")" "$(wc -l < "$f")"
done
echo "=================================================="
EOF
chmod +x /usr/local/bin/cipa-report

# ── LIGHTWEIGHT NATIVE WEB REJECTION HOST PAGE ──────────────────────────────
step "Generating block landing page infrastructure"
dnf install -y -q httpd
cat << 'EOF' > /var/www/html/blocked.html
<!DOCTYPE html>
<html>
<head>
    <title>Access Policy Violation</title>
    <style>
        body { font-family: Arial, sans-serif; text-align: center; margin-top: 10%; background-color: #f8f9fa; color: #333; }
        .container { max-width: 600px; margin: auto; padding: 30px; background: white; border-radius: 8px; box-shadow: 0 4px 8px rgba(0,0,0,0.1); }
        h1 { color: #dc3545; }
        p { font-size: 16px; }
        .footer { font-size: 12px; color: #777; margin-top: 20px; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Website Blocked</h1>
        <p>Your institutional device traffic attempted connection to an unapproved resource.</p>
        <p>This network is filtered in compliance with federal <strong>CIPA</strong> guidelines.</p>
        <div class="footer">Art Room Security Operations Center &bull; VM-FILTER01</div>
    </div>
</body>
</html>
EOF
systemctl enable --now httpd

# ════════════════════════════════════════════════════════════════════════════
# SUMMARY & SERVICE ACTIVATION
# ════════════════════════════════════════════════════════════════════════════
step "Performing initial download loop execution"
/usr/local/bin/update-blocklists

systemctl enable --now squid
banner "VM-FILTER01 Setup Successfully Finished"

echo -e "
  ${GRN}CIPA Filter Running:${RST}  http://$FILTER_IP (Transparent gateway proxy)
  ${GRN}Squid Inbound Port:${RST}   $SQUID_PORT (HTTP)  $HTTPS_PORT (HTTPS interception)
  ${GRN}Block Page Interface:${RST} http://$FILTER_IP/blocked.html
  ${GRN}Target Scope Network:${RST} Student VLAN 10 ($STUDENT_NETWORK)

  ${YLW}POST-DEPLOYMENT REQUIREMENTS:${RST
  1. Distribute /etc/squid/certs/filter-ca.crt to Student Devices via Active Directory GPO.
  2. Map the Student Core Switch Router Gateway to forward 80/443 traffic to $FILTER_IP.
  3. Validate logs via the native reporting app: /usr/local/bin/cipa-report
"
