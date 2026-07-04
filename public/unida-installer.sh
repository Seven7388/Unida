#!/usr/bin/env bash
set -euo pipefail

echo "==============================================="
echo "   Unida DNSTT Server Installer (clean + stable)"
echo "==============================================="

# Root check
if [ "$(id -u)" -ne 0 ]; then
  echo "[-] Tafadhali run kama root: sudo bash $0"
  exit 1
fi

# Default values
TDOMAIN=""
MTU="${MTU:-1232}"
DNSTT_PORT="5300"
PROXY_PORT="53"

# Parse flags
while getopts "d:m:p:h" opt; do
  case $opt in
    d) TDOMAIN="$OPTARG" ;;
    m) MTU="$OPTARG" ;;
    p) DNSTT_PORT="$OPTARG" ;;
    h)
      echo "Usage: $0 -d <domain> [-m <mtu>] [-p <internal_port>]"
      echo "  -d  DNS tunnel domain (e.g., ns.example.com)"
      echo "  -m  MTU size (default: 1800)"
      echo "  -p  Internal DNSTT port (default: 5300)"
      exit 0
      ;;
    *)
      echo "Invalid option. Use -h for help."
      exit 1
      ;;
  esac
done

shift $((OPTIND-1))

# Grab IP early for DNS creation or instructions
IPV4=$(curl -s4 icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}')

# If domain wasn't provided via flag, prompt
if [ -z "$TDOMAIN" ]; then
  echo ""
  echo "==============================================="
  echo "       DNS Tunnel Domain Configuration         "
  echo "==============================================="
  echo "To use DNSTT, you need to configure DNS records."
  echo "1. Automatic Setup (Cloudflare API Integration)"
  echo "2. Manual Setup (I will create records in my registrar)"
  echo "==============================================="
  read -rp "Select option [1-2]: " dns_choice
  
  if [ "$dns_choice" == "1" ]; then
      read -rp "Enter Cloudflare API Token (Requires Edit Zone DNS permission): " CF_TOKEN
      read -rp "Enter your Base Domain (e.g. yours.com): " BASE_DOMAIN
      
      # Disable pipefail temporarily because `head -c 4` and `grep | head` can trigger SIGPIPE and kill the script under `set -e`
      set +euo pipefail
      
      NS_PREFIX=$(tr -dc a-m </dev/urandom | head -c 1 2>/dev/null || echo "n")
      TUN_PREFIX=$(tr -dc n-z </dev/urandom | head -c 1 2>/dev/null || echo "t")
      
      echo "[*] Automatically generated Name Server prefix: ${NS_PREFIX}"
      echo "[*] Automatically generated Tunnel prefix: ${TUN_PREFIX}"
      
      NS_DOMAIN="${NS_PREFIX}.${BASE_DOMAIN}"
      TDOMAIN="${TUN_PREFIX}.${BASE_DOMAIN}"
      
      echo "[*] Fetching Zone ID for ${BASE_DOMAIN}..."
      ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${BASE_DOMAIN}" \
        -H "Authorization: Bearer ${CF_TOKEN}" \
        -H "Content-Type: application/json" | grep -o '"id":"[^"]*"' | head -n 1 | cut -d'"' -f4)
        
      set -euo pipefail
        
      if [ -z "$ZONE_ID" ]; then
          echo "[-] Failed to get Zone ID. Please check your API Token and Domain."
          exit 1
      fi
      
      echo "[*] Creating A record for ${NS_DOMAIN} -> ${IPV4}..."
      curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
        -H "Authorization: Bearer ${CF_TOKEN}" \
        -H "Content-Type: application/json" \
        --data '{"type":"A","name":"'"${NS_DOMAIN}"'","content":"'"${IPV4}"'","ttl":120,"proxied":false}' >/dev/null
        
      echo "[*] Creating NS record for ${TDOMAIN} -> ${NS_DOMAIN}..."
      curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
        -H "Authorization: Bearer ${CF_TOKEN}" \
        -H "Content-Type: application/json" \
        --data '{"type":"NS","name":"'"${TDOMAIN}"'","content":"'"${NS_DOMAIN}"'","ttl":120}' >/dev/null
        
      echo "[+] Cloudflare records created successfully!"
  else
      echo ""
      echo "=== MANUAL DNS CONFIGURATION INSTRUCTIONS ==="
      echo "Please go to your domain registrar (e.g., Cloudflare, Namecheap) and create these two records:"
      echo "1. Create an 'A' record:"
      echo "   Name: ns-unida (or any name you want)"
      echo "   Content/IP: ${IPV4:-YOUR_VPS_IP}"
      echo "   Proxy status: DNS only (Off)"
      echo ""
      echo "2. Create an 'NS' record:"
      echo "   Name: tunnel (or any name you want to use for the tunnel)"
      echo "   Target: ns-unida.yourdomain.com (the A record you just created)"
      echo "   Proxy status: DNS only (Off)"
      echo "============================================="
      echo ""
      read -rp "Enter the DNS tunnel domain (the NS record target, e.g., tunnel.yourdomain.com): " TDOMAIN
  fi
fi

if [ -z "$TDOMAIN" ]; then
  echo "[-] Domain cannot be empty."
  exit 1
fi

echo "==> Domain: ${TDOMAIN}"
echo "==> MTU   : ${MTU}"
sleep 1

echo "==> Kuzima old dnstt/slowdns services kama zipo..."
for svc in dnstt-smart dnstt dnstt-server dnstt-b dnstt-proxy dnsttloc slowdns dnstt-unida dnstt-unida-proxy badvpn-udpgw bind9 dnsmasq; do
  systemctl disable --now "${svc}.service" >/dev/null 2>&1 || true
done

echo "==> Clearing required ports (Killing any blocking processes)..."
if command -v fuser >/dev/null 2>&1; then
  fuser -k 53/udp >/dev/null 2>&1 || true
  fuser -k 53/tcp >/dev/null 2>&1 || true
  fuser -k 5300/udp >/dev/null 2>&1 || true
  fuser -k 7300/tcp >/dev/null 2>&1 || true
fi
if command -v lsof >/dev/null 2>&1; then
  kill -9 $(lsof -t -i:53 -sUDP:LISTEN) 2>/dev/null || true
  kill -9 $(lsof -t -i:5300 -sUDP:LISTEN) 2>/dev/null || true
  kill -9 $(lsof -t -i:7300 -sTCP:LISTEN) 2>/dev/null || true
fi

# Free port 53 from systemd-resolved
if [ -f /etc/systemd/resolved.conf ]; then
  echo "==> Kusetup systemd-resolved (DNSStubListener=no)..."
  sed -i 's/^#DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
  sed -i 's/^DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf

  if grep -q '^#DNS=' /etc/systemd/resolved.conf || grep -q '^DNS=' /etc/systemd/resolved.conf; then
    sed -i 's/^#DNS=.*/DNS=9.9.9.9 1.1.1.1/' /etc/systemd/resolved.conf
    sed -i 's/^DNS=.*/DNS=9.9.9.9 1.1.1.1/' /etc/systemd/resolved.conf
  else
    echo "DNS=9.9.9.9 1.1.1.1" >> /etc/systemd/resolved.conf
  fi

  systemctl restart systemd-resolved >/dev/null 2>&1 || true
  chattr -i /etc/resolv.conf 2>/dev/null || true
  rm -f /etc/resolv.conf
  ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf 2>/dev/null || {
    chattr -i /etc/resolv.conf 2>/dev/null || true
    echo "nameserver 9.9.9.9" > /etc/resolv.conf
    echo "nameserver 1.1.1.1" >> /etc/resolv.conf
  }
fi

echo "==> Installing packages..."
apt-get update -y >/dev/null 2>&1
DEBIAN_FRONTEND=noninteractive apt-get install -y curl python3 wget git cmake make gcc g++ build-essential >/dev/null 2>&1 || true

echo "==> Kupakua and Compiling BadVPN UDPGW (UDP via TCP)..."
if [ ! -f /usr/local/bin/badvpn-udpgw ]; then
  cd /tmp
  git clone https://github.com/ambrop72/badvpn.git >/dev/null 2>&1 || true
  if [ -d /tmp/badvpn ]; then
    cd badvpn
    cmake -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 >/dev/null 2>&1
    make >/dev/null 2>&1
    cp udpgw/badvpn-udpgw /usr/local/bin/
    cd /tmp
    rm -rf badvpn
  else
    echo "[-] BadVPN download failed, continuing without it..."
  fi
fi

if [ -f /usr/local/bin/badvpn-udpgw ]; then
  echo "==> Kuunda service /etc/systemd/system/badvpn-udpgw.service..."
  cat >/etc/systemd/system/badvpn-udpgw.service <<EOF
[Unit]
Description=BadVPN UDPGW Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 1000 --max-connections-for-client 10
Restart=always

[Install]
WantedBy=multi-user.target
EOF
fi

echo "==> Kupakua dnstt-server binary (Linux x64)..."
mkdir -p /usr/local/bin
curl -fsSL "https://dnstt.network/dnstt-server-linux-amd64" -o /usr/local/bin/dnstt-server
chmod +x /usr/local/bin/dnstt-server

echo "==> Ku-generate server keys (ikiwa bado hazipo)..."
mkdir -p /etc/dnstt
if [ ! -f /etc/dnstt/server.key ] || [ ! -f /etc/dnstt/server.pub ]; then
  /usr/local/bin/dnstt-server -gen-key \
    -privkey-file /etc/dnstt/server.key \
    -pubkey-file  /etc/dnstt/server.pub
fi
chmod 600 /etc/dnstt/server.key
chmod 644 /etc/dnstt/server.pub

echo "==> Kuunda service /etc/systemd/system/dnstt-unida.service..."
cat >/etc/systemd/system/dnstt-unida.service <<EOF
[Unit]
Description=Unida DNSTT DNS Tunnel (stable)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/dnstt-server -udp 127.0.0.1:${DNSTT_PORT} -mtu ${MTU} -privkey-file /etc/dnstt/server.key ${TDOMAIN} 127.0.0.1:22
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

echo "==> Kuunda EDNS proxy (512 <-> 1232)..."
cat >/usr/local/bin/dnstt-edns-proxy.py <<EOF_PY
#!/usr/bin/env python3
import socket, struct, concurrent.futures, sys

LISTEN_HOST="0.0.0.0"
LISTEN_PORT=${PROXY_PORT}
UPSTREAM_HOST="127.0.0.1"
UPSTREAM_PORT=${DNSTT_PORT}
EXTERNAL_EDNS_SIZE=1232
INTERNAL_EDNS_SIZE=${MTU}

def extract_and_patch_edns(data: bytes, new_size: int):
    """Returns (patched_data, original_edns_size_from_client)."""
    if len(data) < 12: return data, None
    try:
        qdcount, ancount, nscount, arcount = struct.unpack("!HHHH", data[4:12])
    except struct.error:
        return data, None

    offset = 12

    def skip_name(buf, off):
        while True:
            if off >= len(buf): return len(buf)
            l = buf[off]; off += 1
            if l == 0: break
            if l & 0xC0 == 0xC0:
                if off >= len(buf): return len(buf)
                off += 1
                break
            off += l
        return off

    for _ in range(qdcount):
        offset = skip_name(data, offset)
        if offset + 4 > len(data): return data, None
        offset += 4

    def skip_rrs(count, buf, off):
        for _ in range(count):
            off = skip_name(buf, off)
            if off + 10 > len(buf): return len(buf)
            rtype, rclass, ttl, rdlen = struct.unpack("!HHIH", buf[off:off+10])
            off += 10
            if off + rdlen > len(buf): return len(buf)
            off += rdlen
        return off

    offset = skip_rrs(ancount, data, offset)
    offset = skip_rrs(nscount, data, offset)

    new_data = bytearray(data)
    for _ in range(arcount):
        offset = skip_name(data, offset)
        if offset + 10 > len(data): return data, None
        rtype = struct.unpack("!H", data[offset:offset+2])[0]
        if rtype == 41:
            orig_size = struct.unpack("!H", data[offset+2:offset+4])[0]
            new_data[offset+2:offset+4] = struct.pack("!H", new_size)
            return bytes(new_data), orig_size
        rdlen = struct.unpack("!H", data[offset+8:offset+10])[0]
        offset += 10 + rdlen
    return data, None

def handle_request(server_sock, data, client_addr):
    upstream_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    upstream_sock.settimeout(10.0)
    try:
        upstream_data, orig_size = extract_and_patch_edns(data, INTERNAL_EDNS_SIZE)
        upstream_sock.sendto(upstream_data, (UPSTREAM_HOST, UPSTREAM_PORT))
        resp, _ = upstream_sock.recvfrom(4096)
        
        # Optimize by providing the maximum supported EDNS size (at least 1800).
        final_size = max(orig_size if orig_size else 0, EXTERNAL_EDNS_SIZE)
        
        resp_patched, _ = extract_and_patch_edns(resp, final_size)
        server_sock.sendto(resp_patched, client_addr)
    except Exception as e:
        sys.stderr.write(f"Proxy handler error: {e}\\n")
        sys.stderr.flush()
    finally:
        upstream_sock.close()

def main():
    server_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    except: pass
    try:
        server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    except: pass
    try:
        server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8388608)
        server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 8388608)
    except: pass
    
    server_sock.bind((LISTEN_HOST, LISTEN_PORT))
    print(f"[Unida EDNS proxy] Listening on {LISTEN_HOST}:{LISTEN_PORT}, upstream {UPSTREAM_HOST}:{UPSTREAM_PORT}")
    
    with concurrent.futures.ThreadPoolExecutor(max_workers=2048) as executor:
        while True:
            try:
                data, client_addr = server_sock.recvfrom(4096)
                executor.submit(handle_request, server_sock, data, client_addr)
            except Exception as e:
                sys.stderr.write(f"Proxy receive error: {e}\\n")
                sys.stderr.flush()

if __name__ == "__main__":
    main()
EOF_PY
chmod +x /usr/local/bin/dnstt-edns-proxy.py

cat >/etc/systemd/system/dnstt-unida-proxy.service <<EOF
[Unit]
Description=Unida DNSTT EDNS Proxy (512<->1232)
After=network-online.target dnstt-unida.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/dnstt-edns-proxy.py
Restart=always
RestartSec=1
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

echo "==> Configuring Management CLI (unida)..."
cat >/usr/local/bin/unida <<'EOF_MANAGER'
#!/usr/bin/env bash
set -euo pipefail

clear_screen() {
    clear
}

header() {
    clear_screen
    echo "==============================================="
    echo "       Unida DNSTT Manager CLI"
    echo "==============================================="
}

pause() {
    echo ""
    read -rp "Press [Enter] to return to menu..."
}

create_user() {
    header
    echo "--- Create SSH Tunnel User ---"
    read -rp "Enter username: " USER
    if [ -z "$USER" ]; then
        echo "[-] Username cannot be empty."
        pause; return
    fi
    if id "$USER" &>/dev/null; then
        echo "[-] User $USER already exists!"
        pause; return
    fi
    useradd -m -s /bin/false "$USER"
    read -rp "Enter password (or leave empty to set later): " PASS
    if [ -n "$PASS" ]; then
        echo "$USER:$PASS" | chpasswd
        echo "[+] Created user: $USER with provided password."
    else
        echo "[+] Created user: $USER. Setting password manually:"
        passwd "$USER"
    fi
    pause
}

delete_user() {
    header
    echo "--- Delete SSH Tunnel User ---"
    read -rp "Enter username to delete: " USER
    if [ -z "$USER" ]; then return; fi
    if ! id "$USER" &>/dev/null; then
        echo "[-] User $USER doesn't exist!"
        pause; return
    fi
    userdel -r "$USER"
    echo "[+] Deleted user: $USER"
    pause
}

list_users() {
    header
    echo "--- List of SSH Tunnel Users ---"
    awk -F':' '/\/bin\/false/{print "- " $1}' /etc/passwd
    pause
}

show_status() {
    header
    echo "--- Tunnel Status ---"
    systemctl status dnstt-unida.service --no-pager || true
    echo ""
    echo "--- Proxy Status ---"
    systemctl status dnstt-unida-proxy.service --no-pager || true
    echo ""
    echo "--- BadVPN UDPGW Status ---"
    systemctl status badvpn-udpgw.service --no-pager 2>/dev/null || true
    pause
}

view_logs() {
    header
    echo "--- View Live Logs ---"
    echo "1) Main Tunnel Logs"
    echo "2) EDNS Proxy Logs"
    echo "3) BadVPN UDPGW Logs"
    echo "0) Back"
    read -rp "Select option: " log_choice
    case $log_choice in
        1) journalctl -u dnstt-unida.service -f ;;
        2) journalctl -u dnstt-unida-proxy.service -f ;;
        3) journalctl -u badvpn-udpgw.service -f ;;
        0) return ;;
        *) echo "Invalid option." ;;
    esac
}

restart_services() {
    header
    echo "[+] Restarting services..."
    systemctl restart dnstt-unida.service dnstt-unida-proxy.service badvpn-udpgw.service 2>/dev/null || true
    echo "[+] Services restarted successfully."
    pause
}

show_key() {
    header
    echo "--- Server Public Key ---"
    cat /etc/dnstt/server.pub 2>/dev/null || echo "Key not found!"
    pause
}

change_mtu() {
    header
    echo "--- Change MTU Size ---"
    current_mtu=$(grep -o '\-mtu [0-9]*' /etc/systemd/system/dnstt-unida.service | awk '{print $2}')
    echo "Current MTU: ${current_mtu:-Unknown}"
    read -rp "Enter new MTU size (e.g., 1800, 1200): " NEW_MTU
    if [ -z "$NEW_MTU" ] || ! [[ "$NEW_MTU" =~ ^[0-9]+$ ]]; then
        echo "[-] Invalid MTU size."
        pause; return
    fi
    echo "[+] Updating MTU in dnstt-unida.service..."
    sed -i "s/-mtu [0-9]\+/-mtu $NEW_MTU/g" /etc/systemd/system/dnstt-unida.service
    if [ -f /usr/local/bin/dnstt-edns-proxy.py ]; then
        echo "[+] Updating internal EDNS size in proxy..."
        sed -i "s/INTERNAL_EDNS_SIZE=[0-9]\+/INTERNAL_EDNS_SIZE=$NEW_MTU/g" /usr/local/bin/dnstt-edns-proxy.py
    fi
    systemctl daemon-reload
    systemctl restart dnstt-unida.service dnstt-unida-proxy.service 2>/dev/null || true
    echo "[+] MTU changed to $NEW_MTU and services restarted."
    pause
}

uninstall_unida() {
    header
    echo "--- Uninstall Unida Server ---"
    echo "WARNING: This will completely remove Unida DNSTT, proxy, BadVPN, and all configurations."
    read -rp "Are you sure? (y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        echo "[+] Stopping services..."
        systemctl disable --now dnstt-unida.service dnstt-unida-proxy.service badvpn-udpgw.service 2>/dev/null || true
        echo "[+] Removing files..."
        rm -f /usr/local/bin/dnstt-server
        rm -f /usr/local/bin/dnstt-edns-proxy.py
        rm -f /usr/local/bin/badvpn-udpgw
        rm -f /usr/local/bin/unida
        rm -rf /etc/dnstt
        rm -f /etc/systemd/system/dnstt-unida.service
        rm -f /etc/systemd/system/dnstt-unida-proxy.service
        rm -f /etc/systemd/system/badvpn-udpgw.service
        systemctl daemon-reload
        echo "[+] Removing users..."
        for user in $(awk -F':' '/\/bin\/false/{print $1}' /etc/passwd); do
            userdel -r "$user" 2>/dev/null || true
        done
        echo "[+] Uninstallation complete."
        exit 0
    else
        echo "Uninstallation cancelled."
        pause
    fi
}

main_menu() {
    while true; do
        header
        echo "  1) Create new SSH User"
        echo "  2) Delete SSH User"
        echo "  3) List all SSH Users"
        echo "  4) Show DNSTT Tunnel Status"
        echo "  5) View Live Logs"
        echo "  6) Restart DNSTT Services"
        echo "  7) Show Server Public Key"
        echo "  8) Change MTU Size"
        echo "  9) Uninstall Unida Server"
        echo "  0) Exit"
        echo "==============================================="
        read -rp "Select an option [0-9]: " choice
        case $choice in
            1) create_user ;;
            2) delete_user ;;
            3) list_users ;;
            4) show_status ;;
            5) view_logs ;;
            6) restart_services ;;
            7) show_key ;;
            8) change_mtu ;;
            9) uninstall_unida ;;
            0) exit 0 ;;
            *) echo "Invalid option"; sleep 1 ;;
        esac
    done
}

if [ "$#" -gt 0 ]; then
    # Keep old command-line behavior just in case
    case "$1" in
        useradd) shift; [ -n "${1:-}" ] && { useradd -m -s /bin/false "$1"; [ -n "${2:-}" ] && echo "$1:$2" | chpasswd || passwd "$1"; } ;;
        *) main_menu ;;
    esac
else
    main_menu
fi
EOF_MANAGER
chmod +x /usr/local/bin/unida

echo "==> Configuring Network Forwarding and IPTables for Internet Access..."
# Enable IPv4 forwarding
sed -i '/net.ipv4.ip_forward/s/^#//g' /etc/sysctl.conf
if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
  echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi
sysctl -p >/dev/null 2>&1

# Setup IPTables Masquerade for internet access through the VPN/SSH Tunnel
ETH=$(ip route get 8.8.8.8 | awk -- '{printf $5}')
if [ -n "$ETH" ]; then
  iptables -t nat -A POSTROUTING -o "$ETH" -j MASQUERADE
  if [ "${PROXY_PORT}" != "53" ]; then
    iptables -t nat -A PREROUTING -i "$ETH" -p udp --dport 53 -j REDIRECT --to-ports "${PROXY_PORT}"
  fi

  # Block outgoing QUIC (UDP 443) to force Instagram/YouTube to use TCP
  # This makes DNSTT much faster by avoiding UDP fragmentation.
  iptables -A OUTPUT -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable 2>/dev/null || true
  iptables -I FORWARD -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable 2>/dev/null || true

  iptables-save > /etc/iptables.up.rules

  # Ensure it restores on boot
  mkdir -p /etc/network/if-pre-up.d
  cat >/etc/network/if-pre-up.d/iptables <<EOF
#!/bin/sh
iptables-restore < /etc/iptables.up.rules
EOF
  chmod +x /etc/network/if-pre-up.d/iptables
fi

# Enable required SSH forwarding features
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak 2>/dev/null || true

# 1. Clean up lingering dnsgb and sshtun-user blocks from sshd_config that cause lockouts and connection drops
sed -i '/### SSHTUN-USER START ###/,/### SSHTUN-USER END ###/d' /etc/ssh/sshd_config
sed -i '/### SSHTUN-USER/d' /etc/ssh/sshd_config
sed -i '/sshtun/d' /etc/ssh/sshd_config
sed -i '/dnsgb/d' /etc/ssh/sshd_config

# 2. Register /bin/false and /usr/sbin/nologin as valid shells to prevent pam_shells.so rejections
if [ -f /etc/shells ]; then
  for sh in /bin/false /usr/sbin/nologin /sbin/nologin; do
    if ! grep -q "^$sh" /etc/shells; then
      echo "$sh" >> /etc/shells
    fi
  done
fi

# 3. Apply standard robust SSH configurations
sed -i 's/^#ListenAddress.*/ListenAddress 0.0.0.0/g' /etc/ssh/sshd_config
if ! grep -q "^ListenAddress" /etc/ssh/sshd_config; then echo "ListenAddress 0.0.0.0" >> /etc/ssh/sshd_config; fi

sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config
sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config
if ! grep -q "^PasswordAuthentication yes" /etc/ssh/sshd_config; then echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config; fi

sed -i 's/^#AllowTcpForwarding.*/AllowTcpForwarding yes/g' /etc/ssh/sshd_config
sed -i 's/^#GatewayPorts.*/GatewayPorts yes/g' /etc/ssh/sshd_config
if ! grep -q "^AllowTcpForwarding yes" /etc/ssh/sshd_config; then echo "AllowTcpForwarding yes" >> /etc/ssh/sshd_config; fi
if ! grep -q "^GatewayPorts yes" /etc/ssh/sshd_config; then echo "GatewayPorts yes" >> /etc/ssh/sshd_config; fi
if ! grep -q "^TCPKeepAlive yes" /etc/ssh/sshd_config; then echo "TCPKeepAlive yes" >> /etc/ssh/sshd_config; fi

# 4. Enforce overrides in sshd_config.d drop-ins to prevent Cloud-Init/OS locking out passwords and forwarding
if [ -d /etc/ssh/sshd_config.d ]; then
  find /etc/ssh/sshd_config.d/ -type f -name "*.conf" -exec sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/g' {} + 2>/dev/null || true
  find /etc/ssh/sshd_config.d/ -type f -name "*.conf" -exec sed -i 's/^KbdInteractiveAuthentication.*/KbdInteractiveAuthentication yes/g' {} + 2>/dev/null || true
  cat > /etc/ssh/sshd_config.d/99-unida.conf << 'EOF'
PasswordAuthentication yes
PubkeyAuthentication yes
AllowTcpForwarding yes
GatewayPorts yes
TCPKeepAlive yes
ClientAliveInterval 300
ClientAliveCountMax 5
UseDNS no
MaxSessions 10000
MaxStartups 1000:30:10000
KexAlgorithms +diffie-hellman-group1-sha1,diffie-hellman-group14-sha1,diffie-hellman-group-exchange-sha1,diffie-hellman-group-exchange-sha256
Ciphers +aes128-cbc,aes192-cbc,aes256-cbc,3des-cbc
HostKeyAlgorithms +ssh-rsa,ssh-dss
PubkeyAcceptedKeyTypes +ssh-rsa,ssh-dss
EOF
  chmod 644 /etc/ssh/sshd_config.d/99-unida.conf 2>/dev/null || true
fi

systemctl restart sshd || systemctl restart ssh || true

echo "==> Starting services..."
systemctl daemon-reload
systemctl enable --now dnstt-unida.service
systemctl enable --now dnstt-unida-proxy.service
if [ -f /etc/systemd/system/badvpn-udpgw.service ]; then
  systemctl enable --now badvpn-udpgw.service
fi

if command -v ufw >/dev/null 2>&1; then
  ufw allow 22/tcp >/dev/null 2>&1 || true
  ufw allow 53/udp >/dev/null 2>&1 || true
  ufw allow ${PROXY_PORT}/udp >/dev/null 2>&1 || true
  ufw allow 7300/tcp >/dev/null 2>&1 || true
  ufw reload >/dev/null 2>&1 || true
fi

# General IPTables rules for Oracle Cloud / strict firewalls
iptables -I INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null || true
iptables -I INPUT -p tcp --dport 53 -j ACCEPT 2>/dev/null || true
iptables -I INPUT -p udp --dport ${PROXY_PORT} -j ACCEPT 2>/dev/null || true
iptables -I INPUT -p tcp --dport 7300 -j ACCEPT 2>/dev/null || true
iptables-save > /etc/iptables.up.rules 2>/dev/null || true

# Firewalld support (CentOS/AlmaLinux/Oracle)
if command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --add-port=53/udp --permanent 2>/dev/null || true
  firewall-cmd --add-port=53/tcp --permanent 2>/dev/null || true
  firewall-cmd --add-port=${PROXY_PORT}/udp --permanent 2>/dev/null || true
  firewall-cmd --add-port=7300/tcp --permanent 2>/dev/null || true
  firewall-cmd --reload 2>/dev/null || true
fi

IPV4=$(curl -s4 icanhazip.com || hostname -I | awk '{print $1}')

echo ""
echo "==============================================="
echo "        UNIDA DNSTT SERVER READY"
echo "==============================================="
echo "Server IP        : ${IPV4}"
echo "Tunnel Domain    : ${TDOMAIN}"
echo "MTU              : ${MTU}"
echo "dnstt-server     : 127.0.0.1:${DNSTT_PORT}"
echo "proxy public     : UDP :${PROXY_PORT}"
echo "badvpn-udpgw     : 127.0.0.1:7300"
echo ""
echo "Public key:"
cat /etc/dnstt/server.pub || true
echo ""
echo "🔥 NEW: Use the 'unida' command to manage your server!"
echo "    Add SSH user    : unida useradd username password"
echo "    Check status    : unida status"
echo "    See all commands: unida help"
echo "==============================================="
