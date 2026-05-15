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
MTU="1800"
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
      
      RANDOM_STR=$(tr -dc a-z0-9 </dev/urandom | head -c 4)
      NS_PREFIX="ns-${RANDOM_STR}"
      TUN_PREFIX="tun-${RANDOM_STR}"
      
      echo "[*] Automatically generated Name Server prefix: ${NS_PREFIX}"
      echo "[*] Automatically generated Tunnel prefix: ${TUN_PREFIX}"
      
      NS_DOMAIN="${NS_PREFIX}.${BASE_DOMAIN}"
      TDOMAIN="${TUN_PREFIX}.${BASE_DOMAIN}"
      
      echo "[*] Fetching Zone ID for ${BASE_DOMAIN}..."
      ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${BASE_DOMAIN}" \
        -H "Authorization: Bearer ${CF_TOKEN}" \
        -H "Content-Type: application/json" | grep -o '"id":"[^"]*"' | head -n 1 | cut -d'"' -f4)
        
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
for svc in dnstt-smart dnstt dnstt-server dnstt-b dnstt-proxy dnsttloc slowdns dnstt-unida dnstt-unida-proxy; do
  systemctl disable --now "${svc}.service" >/dev/null 2>&1 || true
done

# Free port 53 from systemd-resolved
if [ -f /etc/systemd/resolved.conf ]; then
  echo "==> Kusetup systemd-resolved (DNSStubListener=no)..."
  sed -i 's/^#DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
  sed -i 's/^DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf

  if grep -q '^#DNS=' /etc/systemd/resolved.conf || grep -q '^DNS=' /etc/systemd/resolved.conf; then
    sed -i 's/^#DNS=.*/DNS=8.8.8.8 1.1.1.1/' /etc/systemd/resolved.conf
    sed -i 's/^DNS=.*/DNS=8.8.8.8 1.1.1.1/' /etc/systemd/resolved.conf
  else
    echo "DNS=8.8.8.8 1.1.1.1" >> /etc/systemd/resolved.conf
  fi

  systemctl restart systemd-resolved >/dev/null 2>&1 || true
  rm -f /etc/resolv.conf
  ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf 2>/dev/null || echo "nameserver 8.8.8.8" > /etc/resolv.conf
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

echo "==> Kuunda EDNS proxy (512 <-> 1800)..."
cat >/usr/local/bin/dnstt-edns-proxy.py <<'PY'
#!/usr/bin/env python3
import socket, threading, struct

LISTEN_HOST="0.0.0.0"
LISTEN_PORT=53
UPSTREAM_HOST="127.0.0.1"
UPSTREAM_PORT=5300
EXTERNAL_EDNS_SIZE=512
INTERNAL_EDNS_SIZE=1800

def patch_edns_udp_size(data: bytes, new_size: int) -> bytes:
    if len(data) < 12: return data
    try:
        qdcount, ancount, nscount, arcount = struct.unpack("!HHHH", data[4:12])
    except struct.error:
        return data

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
        if offset + 4 > len(data): return data
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
        if offset + 10 > len(data): return data
        rtype = struct.unpack("!H", data[offset:offset+2])[0]
        if rtype == 41:
            new_data[offset+2:offset+4] = struct.pack("!H", new_size)
            return bytes(new_data)
        rdlen = struct.unpack("!H", data[offset+8:offset+10])[0]
        offset += 10 + rdlen
    return data

def handle_request(server_sock, data, client_addr):
    upstream_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    upstream_sock.settimeout(5.0)
    try:
        upstream_data = patch_edns_udp_size(data, INTERNAL_EDNS_SIZE)
        upstream_sock.sendto(upstream_data, (UPSTREAM_HOST, UPSTREAM_PORT))
        resp, _ = upstream_sock.recvfrom(4096)
        resp_patched = patch_edns_udp_size(resp, EXTERNAL_EDNS_SIZE)
        server_sock.sendto(resp_patched, client_addr)
    except Exception:
        pass
    finally:
        upstream_sock.close()

def main():
    server_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    server_sock.bind((LISTEN_HOST, LISTEN_PORT))
    print(f"[Unida EDNS proxy] Listening on {LISTEN_HOST}:{LISTEN_PORT}, upstream {UPSTREAM_HOST}:{UPSTREAM_PORT}")
    while True:
        data, client_addr = server_sock.recvfrom(4096)
        threading.Thread(target=handle_request, args=(server_sock, data, client_addr), daemon=True).start()

if __name__ == "__main__":
    main()
PY
chmod +x /usr/local/bin/dnstt-edns-proxy.py

cat >/etc/systemd/system/dnstt-unida-proxy.service <<EOF
[Unit]
Description=Unida DNSTT EDNS Proxy (512<->1800)
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
    current_mtu=$(grep -o '-mtu [0-9]*' /etc/systemd/system/dnstt-unida.service | awk '{print $2}')
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
sed -i 's/^#AllowTcpForwarding.*/AllowTcpForwarding yes/g' /etc/ssh/sshd_config
sed -i 's/^#GatewayPorts.*/GatewayPorts yes/g' /etc/ssh/sshd_config
if ! grep -q "^AllowTcpForwarding yes" /etc/ssh/sshd_config; then echo "AllowTcpForwarding yes" >> /etc/ssh/sshd_config; fi
if ! grep -q "^GatewayPorts yes" /etc/ssh/sshd_config; then echo "GatewayPorts yes" >> /etc/ssh/sshd_config; fi
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
  ufw allow 7300/tcp >/dev/null 2>&1 || true
  ufw reload >/dev/null 2>&1 || true
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
