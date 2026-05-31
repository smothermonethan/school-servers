#!/bin/sh
# ============================================================
#  pfSense 2.1 LiveCD - Personal Firewall Hardening Script
#  Compatible with: pfSense-LiveCD-2.1 (FreeBSD 8.3)
#  Run as root from the pfSense shell (option 8)
#  Usage: sh pfsense21_personal_firewall.sh
# ============================================================

echo "========================================"
echo "  pfSense 2.1 Personal Firewall Setup"
echo "========================================"
echo ""

# ---- CONFIGURATION — edit these to match your network ----
WAN_IF="em0"          # Your WAN interface (check with: ifconfig)
LAN_IF="em1"          # Your LAN interface
LAN_NET="192.168.1.0/24"   # Your local network subnet
LAN_GW="192.168.1.1"       # This firewall's LAN IP (gateway)
ADMIN_IP="192.168.1.100"   # Your personal PC IP for admin access only
# ----------------------------------------------------------

echo "[*] Flushing existing PF rules..."
pfctl -F all 2>/dev/null
pfctl -d 2>/dev/null

# ============================================================
#  BUILD THE PF RULESET
# ============================================================
RULES_FILE="/tmp/pf_personal.conf"

cat > "$RULES_FILE" << 'PFRULES'
# ============================================================
#  PF Ruleset — pfSense 2.1 Personal Firewall
#  FreeBSD PF syntax (NOT OpenBSD extended syntax)
# ============================================================

# ---------- INTERFACES ----------
ext_if = "em0"        # WAN
int_if = "em1"        # LAN

# ---------- NETWORKS ----------
lan_net  = "192.168.1.0/24"
admin_ip = "192.168.1.100"

# ---------- SERVICES YOU RUN LOCALLY ----------
# Uncomment only the ports you actually use on your machines

# Common personal server ports
#  80   = HTTP web server
#  443  = HTTPS web server
#  22   = SSH
#  21   = FTP (legacy)
#  25   = SMTP mail
#  110  = POP3 mail
#  143  = IMAP mail
#  3306 = MySQL/MariaDB
#  5432 = PostgreSQL
#  3389 = Windows RDP
#  445  = Windows SMB file sharing
#  137,138,139 = NetBIOS
#  8080 = HTTP alt / dev servers
#  8443 = HTTPS alt
#  32400 = Plex media server
#  1194 = OpenVPN
#  1723 = PPTP VPN (legacy)
#  6881 = BitTorrent (optional)

# ---------- SCRUB ----------
# Normalize all packets coming in
scrub in all

# ---------- NAT / PAT ----------
# Masquerade LAN traffic out through WAN
nat on $ext_if from $lan_net to any -> ($ext_if)

# ---------- LOOPBACK ----------
set skip on lo0

# ============================================================
#  BLOCK RULES  (processed top-down, first match wins)
# ============================================================

# Block ALL by default on WAN (whitelist below)
block in  log on $ext_if all
block out log on $ext_if all

# Block RFC1918 private addresses coming IN on WAN (anti-spoofing)
block in  log quick on $ext_if from 10.0.0.0/8     to any
block in  log quick on $ext_if from 172.16.0.0/12  to any
block in  log quick on $ext_if from 192.168.0.0/16 to any
block in  log quick on $ext_if from 127.0.0.0/8    to any
block in  log quick on $ext_if from 0.0.0.0/8      to any
block in  log quick on $ext_if from 169.254.0.0/16 to any
block in  log quick on $ext_if from 192.0.2.0/24   to any
block in  log quick on $ext_if from 224.0.0.0/3    to any

# Block common attack vectors on WAN
block in  log quick on $ext_if proto tcp flags FUP/FUP  # XMAS scan
block in  log quick on $ext_if proto tcp flags /SFUP     # NULL scan
block in  log quick on $ext_if proto tcp flags SF/SF     # SYN+FIN

# Block Telnet inbound (never allow plain text remote admin)
block in  log quick on $ext_if proto tcp to any port 23

# Block inbound SMTP from WAN unless you run a mail server
block in  log quick on $ext_if proto tcp to any port 25

# Block NetBIOS/SMB from WAN (never expose Windows shares to internet)
block in  log quick on $ext_if proto { tcp udp } to any port 137
block in  log quick on $ext_if proto { tcp udp } to any port 138
block in  log quick on $ext_if proto tcp         to any port 139
block in  log quick on $ext_if proto tcp         to any port 445

# Block RDP from WAN (use VPN instead)
block in  log quick on $ext_if proto tcp to any port 3389

# Block database ports from WAN
block in  log quick on $ext_if proto tcp to any port 3306
block in  log quick on $ext_if proto tcp to any port 5432
block in  log quick on $ext_if proto tcp to any port 1433
block in  log quick on $ext_if proto tcp to any port 1521

# Block pfSense WebGUI and SSH from WAN
block in  log quick on $ext_if proto tcp to any port 22
block in  log quick on $ext_if proto tcp to any port 443
block in  log quick on $ext_if proto tcp to any port 80

# ============================================================
#  ALLOW RULES — WAN INBOUND
# ============================================================

# Allow established/related connections back in (stateful)
pass in on $ext_if proto tcp from any to any flags S/SA keep state
pass in on $ext_if proto udp from any to any keep state
pass in on $ext_if proto icmp  # Allow ping (comment out to stealth)

# ---- Uncomment services you want reachable from internet ----

# Allow inbound SSH (only if you need remote shell access)
#pass in log on $ext_if proto tcp to ($ext_if) port 22 keep state

# Allow inbound HTTP/HTTPS (only if you host a web server)
#pass in log on $ext_if proto tcp to ($ext_if) port { 80 443 } keep state

# Allow inbound OpenVPN (recommended over raw RDP/SSH)
#pass in log on $ext_if proto udp to ($ext_if) port 1194 keep state

# Allow inbound Plex (if you run Plex media server)
#pass in log on $ext_if proto tcp to ($ext_if) port 32400 keep state

# Allow inbound FTP (legacy — avoid if possible)
#pass in log on $ext_if proto tcp to ($ext_if) port 21 keep state

# ============================================================
#  WAN OUTBOUND — Allow all outbound from firewall itself
# ============================================================
pass out on $ext_if proto { tcp udp icmp } all keep state

# ============================================================
#  LAN RULES
# ============================================================

# Allow all LAN traffic out (LAN clients can reach internet)
pass in  on $int_if from $lan_net to any keep state
pass out on $int_if from any to $lan_net keep state

# Allow DHCP requests from LAN clients
pass in  on $int_if proto udp from any to 255.255.255.255 port 67 keep state

# Allow DNS to firewall from LAN
pass in  on $int_if proto { tcp udp } from $lan_net to $int_if port 53 keep state

# Allow pfSense WebGUI ONLY from admin IP on LAN
pass in  log on $int_if proto tcp from $admin_ip to $int_if port { 80 443 } keep state

# Block WebGUI from all other LAN IPs
block in  log on $int_if proto tcp from $lan_net to $int_if port { 80 443 }

# Allow SSH to firewall ONLY from admin IP
pass in  log on $int_if proto tcp from $admin_ip to $int_if port 22 keep state
block in  log on $int_if proto tcp from $lan_net  to $int_if port 22

# ============================================================
#  ICMP (ping) controls
# ============================================================
# Allow LAN to ping anything
pass in  on $int_if proto icmp from $lan_net to any keep state
# Allow firewall to ping out (useful for diagnostics)
pass out on $ext_if proto icmp all keep state

# ============================================================
#  END OF RULESET
# ============================================================
PFRULES

# Substitute actual interface values into the file
sed -i '' "s/em0/$WAN_IF/g" "$RULES_FILE"
sed -i '' "s/em1/$LAN_IF/g" "$RULES_FILE"
sed -i '' "s/192\.168\.1\.0\/24/$LAN_NET/g" "$RULES_FILE"
sed -i '' "s/192\.168\.1\.100/$ADMIN_IP/g" "$RULES_FILE"

echo "[*] Loading PF rules..."
pfctl -f "$RULES_FILE"
if [ $? -eq 0 ]; then
    echo "[+] Rules loaded successfully."
else
    echo "[!] Error loading rules. Check syntax above."
    exit 1
fi

echo "[*] Enabling PF..."
pfctl -e
echo "[+] PF enabled."

# ============================================================
#  HARDEN SYSCTL (FreeBSD kernel network settings)
# ============================================================
echo "[*] Applying sysctl hardening..."

# Disable IP source routing
sysctl net.inet.ip.sourceroute=0
sysctl net.inet.ip.accept_sourceroute=0

# Enable SYN flood protection (syncookies)
sysctl net.inet.tcp.syncookies=1

# Log packets from dying connections
sysctl net.inet.tcp.log_debug=1

# Disable ICMP redirects
sysctl net.inet.icmp.drop_redirect=1
sysctl net.inet.icmp.log_redirect=1
sysctl net.inet.ip.redirect=0

# Ignore ICMP broadcasts (Smurf attack protection)
sysctl net.inet.icmp.bmcastecho=0

# Randomize IP IDs (makes OS fingerprinting harder)
sysctl net.inet.ip.random_id=1

# Enable RFC 1323 TCP extensions
sysctl net.inet.tcp.rfc1323=1

# Drop RST packets to closed ports silently
sysctl net.inet.tcp.blackhole=2
sysctl net.inet.udp.blackhole=1

echo "[+] sysctl hardening applied."

# ============================================================
#  DISABLE UNNECESSARY SERVICES
# ============================================================
echo "[*] Disabling unneeded services..."

# Disable Telnet (should already be off, but be sure)
/etc/rc.d/inetd stop 2>/dev/null

echo "[+] Services trimmed."

# ============================================================
#  SHOW CURRENT STATUS
# ============================================================
echo ""
echo "========================================"
echo "  CURRENT PF STATUS"
echo "========================================"
pfctl -s info
echo ""
echo "  Active rules:"
pfctl -s rules
echo ""
echo "  NAT rules:"
pfctl -s nat
echo ""
echo "========================================"
echo "  SETUP COMPLETE"
echo "========================================"
echo ""
echo "  WAN interface : $WAN_IF"
echo "  LAN interface : $LAN_IF"
echo "  LAN subnet    : $LAN_NET"
echo "  Admin-only IP : $ADMIN_IP"
echo ""
echo "  NEXT STEPS:"
echo "  1. Edit the top of this script to match YOUR interface names"
echo "     (run 'ifconfig' to list them)"
echo "  2. Uncomment any inbound service ports you actually need"
echo "  3. Save rules permanently via pfSense WebGUI > Diagnostics >"
echo "     Backup & Restore after verifying everything works"
echo "  4. Consider upgrading pfSense — 2.1 is EOL (no security patches)"
echo ""
