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
MTU="512"
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
      echo "  -m  MTU size (default: 512)"
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
      
      # Disable pipefail temporarily because `head -c 1` and `grep | head` can trigger SIGPIPE and kill the script under `set -e`
      set +euo pipefail
      
      RANDOM_STR=$(tr -dc a-z0-9 </dev/urandom | head -c 1)
      NS_PREFIX="n${RANDOM_STR}"
      TUN_PREFIX="t${RANDOM_STR}"
      
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

# Set IPv4 precedence for stable connection on VPS
echo "==> Configuring VPS to prefer IPv4 over IPv6..."
cat >> /etc/gai.conf << 'EOF'
precedence ::ffff:0:0/96  100
EOF

# Ensure IPv6 is enabled for apps that require it
echo "==> Re-enabling IPv6..."
sed -i '/disable_ipv6/d' /etc/sysctl.conf
sysctl -p >/dev/null 2>&1


  fuser -k 53/udp >/dev/null 2>&1 || true
  fuser -k 53/tcp >/dev/null 2>&1 || true
  fuser -k 5300/udp >/dev/null 2>&1 || true
  fuser -k 7300/tcp >/dev/null 2>&1 || true
fi
if command -v lsof >/dev/null 2>&1; then
  kill -9 $(lsof -t -i:53 -sUDP:LISTEN 2>/dev/null) 2>/dev/null || true
  kill -9 $(lsof -t -i:5300 -sUDP:LISTEN 2>/dev/null) 2>/dev/null || true
  kill -9 $(lsof -t -i:7300 -sTCP:LISTEN 2>/dev/null) 2>/dev/null || true
fi

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
echo "    (Please wait, this may take a moment...)"
apt-get update -y >/dev/null 2>&1
DEBIAN_FRONTEND=noninteractive apt-get install -y curl python3 wget git cmake make gcc g++ build-essential dante-server >/dev/null 2>&1 || true

echo "==> Configuring Lightweight SOCKS5 Server (Dante)..."
ETH=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
if [ -z "$ETH" ]; then
    ETH=$(ip route get 8.8.8.8 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
fi
if [ -z "$ETH" ]; then
    ETH="eth0"
fi
cat >/etc/danted.conf <<EOF
logoutput: syslog
user.privileged: root
user.unprivileged: nobody
internal: 127.0.0.1 port = 1080
external: $ETH
socksmethod: none
clientmethod: none

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error
}

socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error
}
EOF
systemctl restart danted >/dev/null 2>&1 || true
systemctl enable danted >/dev/null 2>&1 || true

echo "==> Compiling High-Performance BadVPN UDPGW from source..."
rm -f /usr/local/bin/badvpn-udpgw
if [ ! -f /usr/local/bin/badvpn-udpgw ]; then
  cd /tmp
  rm -rf badvpn
  git clone https://github.com/ambrop72/badvpn.git >/dev/null 2>&1 || true
  if [ -d /tmp/badvpn ]; then
    cd badvpn
    cmake -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 -DCMAKE_BUILD_TYPE=Release >/dev/null 2>&1
    make >/dev/null 2>&1
    cp udpgw/badvpn-udpgw /usr/local/bin/
    cd /tmp
    rm -rf badvpn
  else
    echo "[-] BadVPN download failed, falling back to precompiled..."
    wget -q -O /usr/local/bin/badvpn-udpgw https://raw.githubusercontent.com/daybreakersx/premscript/master/badvpn-udpgw64
  fi
  chmod +x /usr/local/bin/badvpn-udpgw
fi

if [ -f /usr/local/bin/badvpn-udpgw ]; then
  echo "==> Kuunda service /etc/systemd/system/badvpn-udpgw.service (IPv4)..."
  cat >/etc/systemd/system/badvpn-udpgw.service <<EOF
[Unit]
Description=BadVPN UDPGW Service (Dual Stack)
After=network.target

[Service]
Type=simple
LimitNOFILE=1048576
LimitNPROC=1048576
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 10000 --max-connections-for-client 30
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  echo "==> Kuunda service /etc/systemd/system/badvpn-udpgw-ipv6.service (IPv6)..."
  cat >/etc/systemd/system/badvpn-udpgw-ipv6.service <<EOF
[Unit]
Description=BadVPN UDPGW Service IPv6
After=network.target

[Service]
Type=simple
LimitNOFILE=1048576
LimitNPROC=1048576
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr [::1]:7300 --max-clients 10000 --max-connections-for-client 30
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

echo "==> Kusakinisha Xray-core (VLESS na VMESS TCP)..."
curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o /tmp/install-xray.sh
bash /tmp/install-xray.sh install
if [ -f /usr/local/bin/xray ]; then
  XRAY_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "1a2b3c4d-5e6f-7g8h-9i0j-1k2l3m4n5o6p")
  cat >/usr/local/etc/xray/config.json <<EOF
{
  "inbounds": [
    {
      "port": 10080,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$XRAY_UUID",
            "level": 0
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp"
      }
    },
    {
      "port": 10081,
      "listen": "127.0.0.1",
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "$XRAY_UUID",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "tcp"
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIP"
      }
    }
  ]
}
EOF
  systemctl enable --now xray >/dev/null 2>&1 || true
  systemctl restart xray >/dev/null 2>&1 || true
  echo "${XRAY_UUID}" > /etc/dnstt/xray_uuid.txt
fi

echo "==> Kuunda service /etc/systemd/system/dnstt-unida.service..."
cat >/etc/systemd/system/dnstt-unida.service <<EOF
[Unit]
Description=Unida DNSTT DNS Tunnel (stable)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
LimitNOFILE=1048576
LimitNPROC=1048576
EnvironmentFile=-/etc/default/dnstt-unida
ExecStart=/usr/local/bin/dnstt-server -udp 127.0.0.1:${DNSTT_PORT} -mtu ${MTU} -privkey-file /etc/dnstt/server.key ${TDOMAIN} 127.0.0.1:\${BACKEND_PORT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

if [ ! -f /etc/default/dnstt-unida ]; then
cat >/etc/default/dnstt-unida <<EOF
# Backend port: 22 (SSH), 1080 (SOCKS5), or custom proxy (VLESS/Xray/Shadowsocks)
BACKEND_PORT=22
EOF
fi


echo "==> Kuunda EDNS proxy (512 <-> 1800)..."
cat >/usr/local/bin/dnstt-edns-proxy.py <<EOF_PY
#!/usr/bin/env python3
import socket, struct, concurrent.futures

LISTEN_HOST="0.0.0.0"
LISTEN_PORT=${PROXY_PORT}
UPSTREAM_HOST="127.0.0.1"
UPSTREAM_PORT=${DNSTT_PORT}
EXTERNAL_EDNS_SIZE=1800
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
    upstream_sock.settimeout(2.0)
    try:
        upstream_data, orig_size = extract_and_patch_edns(data, INTERNAL_EDNS_SIZE)
        upstream_sock.sendto(upstream_data, (UPSTREAM_HOST, UPSTREAM_PORT))
        resp, _ = upstream_sock.recvfrom(4096)
        
        # Optimize by providing the maximum supported EDNS size (at least 1800).
        final_size = max(orig_size if orig_size else 0, EXTERNAL_EDNS_SIZE)
        
        resp_patched, _ = extract_and_patch_edns(resp, final_size)
        server_sock.sendto(resp_patched, client_addr)
    except Exception:
        pass
    finally:
        upstream_sock.close()

def main():
    server_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
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
            except Exception:
                pass

if __name__ == "__main__":
    main()
EOF_PY
chmod +x /usr/local/bin/dnstt-edns-proxy.py

cat >/etc/systemd/system/dnstt-unida-proxy.service <<EOF
[Unit]
Description=Unida DNSTT EDNS Proxy (512<->1800)
After=network-online.target dnstt-unida.service
Wants=network-online.target

[Service]
Type=simple
LimitNOFILE=1048576
LimitNPROC=1048576
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

if [ "$(id -u)" -ne 0 ]; then
    echo "[-] Unida Manager needs root privileges!"
    echo "    Please run: sudo unida"
    exit 1
fi

clear_screen() {
    clear
}

header() {
    clear_screen
    echo "==============================================="
    echo "       Unida DNSTT Manager CLI v1.4"
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
    systemctl status badvpn-udpgw-ipv6.service --no-pager 2>/dev/null || true
    echo ""
    echo "--- Xray Core Status ---"
    systemctl status xray.service --no-pager 2>/dev/null || true
    pause
}

view_logs() {
    header
    echo "--- View Live Logs ---"
    echo "1) Main Tunnel Logs"
    echo "2) EDNS Proxy Logs"
    echo "3) BadVPN UDPGW Logs"
    echo "4) Xray Core Logs"
    echo "0) Back"
    read -rp "Select option: " log_choice
    case $log_choice in
        1) journalctl -u dnstt-unida.service -f ;;
        2) journalctl -u dnstt-unida-proxy.service -f ;;
        3) journalctl -u badvpn-udpgw.service -f ;;
        4) journalctl -u xray.service -f ;;
        0) return ;;
        *) echo "Invalid option." ;;
    esac
}

restart_services() {
    header
    echo "[+] Enabling and restarting services..."
    systemctl enable --now dnstt-unida.service dnstt-unida-proxy.service badvpn-udpgw.service badvpn-udpgw-ipv6.service xray.service 2>/dev/null || true
    systemctl restart dnstt-unida.service dnstt-unida-proxy.service badvpn-udpgw.service badvpn-udpgw-ipv6.service xray.service 2>/dev/null || true
    
    # Dissolve: ensure SSH does not die when we are restarting services
    echo "[+] Verifying SSH / SSHD services stay active..."
    systemctl enable ssh >/dev/null 2>&1 || true
    systemctl enable sshd >/dev/null 2>&1 || true
    systemctl is-active --quiet sshd || systemctl start sshd >/dev/null 2>&1 || true
    systemctl is-active --quiet ssh || systemctl start ssh >/dev/null 2>&1 || true

    echo "[+] Services enabled and restarted successfully."
    pause
}

show_key() {
    header
    echo "--- Server Public Key ---"
    cat /etc/dnstt/server.pub 2>/dev/null || echo "Key not found!"
    pause
}

change_backend() {
    header
    echo "--- Change Tunnel Backend Protocol ---"
    CURRENT_PORT=$(grep '^BACKEND_PORT=' /etc/default/dnstt-unida | cut -d= -f2)
    
    echo "Current Backend Port: ${CURRENT_PORT}"
    if [ "$CURRENT_PORT" == "22" ]; then
        echo "Active Mode: SSH Forwarding Mode (Default)"
    elif [ "$CURRENT_PORT" == "1080" ]; then
        echo "Active Mode: Pure SOCKS5 Mode (Reduced Overhead)"
    else
        echo "Active Mode: Custom TCP Proxy Mode (VLESS/Shadowsocks/etc)"
    fi
    echo "==============================================="
    echo "1) SSH Mode (Port 22) - Full VPN capabilities"
    echo "2) SOCKS5 Mode (Port 1080) - Lightweight, reduced overhead"
    echo "3) Custom Port (e.g., Xray/VLESS port)"
    read -rp "Select backend mode [1-3]: " b_choice
    
    NEW_PORT=""
    if [ "$b_choice" == "1" ]; then
        NEW_PORT="22"
    elif [ "$b_choice" == "2" ]; then
        NEW_PORT="1080"
        echo "[!] SOCKS5 Mode activated. Ensure your client app uses SOCKS proxy settings."
    elif [ "$b_choice" == "3" ]; then
        read -rp "Enter your preferred custom TCP port: " NEW_PORT
        if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]]; then echo "[-] Invalid port"; pause; return; fi
    else
        echo "[-] Invalid choice."
        pause; return
    fi
    
    sed -i "s/^BACKEND_PORT=.*/BACKEND_PORT=${NEW_PORT}/" /etc/default/dnstt-unida
    systemctl restart dnstt-unida
    echo "[+] Backend updated to port ${NEW_PORT} successfully!"
    pause
}

change_mtu() {
    header
    echo "--- Change MTU Size ---"
    current_mtu=$(grep "mtu" /etc/systemd/system/dnstt-unida.service | sed -n 's/.*-mtu \([0-9]*\).*/\1/p')
    echo "Current MTU: ${current_mtu:-Unknown}"
    read -rp "Enter new MTU size (e.g., 512, 1200): " NEW_MTU
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
        systemctl disable --now dnstt-unida.service dnstt-unida-proxy.service badvpn-udpgw.service badvpn-udpgw-ipv6.service 2>/dev/null || true
        echo "[+] Removing files..."
        rm -f /usr/local/bin/dnstt-server
        rm -f /usr/local/bin/dnstt-edns-proxy.py
        rm -f /usr/local/bin/badvpn-udpgw
        rm -f /usr/local/bin/unida
        rm -rf /etc/dnstt
        rm -f /etc/systemd/system/dnstt-unida.service
        rm -f /etc/systemd/system/dnstt-unida-proxy.service
        rm -f /etc/systemd/system/badvpn-udpgw.service
        rm -f /etc/systemd/system/badvpn-udpgw-ipv6.service
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

show_v2ray_details() {
    header
    echo "--- V2Ray / SlowDNS DNSTT App Details ---"
    
    # Get NS Domain
    NS_DOMAIN=$(grep "ExecStart=" /etc/systemd/system/dnstt-unida.service | sed -n 's/.*server\.key \([^ ]*\) .*/\1/p' || echo "Unknown")
    
    # Get Server PubKey
    PUBKEY=$(cat /etc/dnstt/server.pub 2>/dev/null || echo "Unknown")
    
    # Get Xray UUID
    XRAY_UUID=$(cat /etc/dnstt/xray_uuid.txt 2>/dev/null || echo "Not Installed/Not Found")

    echo "==============================================="
    echo "            DNSTT & V2RAY DETAILS              "
    echo "==============================================="
    echo "  DNS Nameserver (Your Domain): ${NS_DOMAIN}"
    echo "  Public Key: ${PUBKEY}"
    echo "  VLESS/VMESS UUID: ${XRAY_UUID}"
    echo "  V2Ray Target Port: 443 (Usually Ignored via DNSTT)"
    echo "  Network / Transport: TCP"
    echo "  Security: None (Plain)"
    echo "==============================================="
    echo "       HOW TO CONNECT in Npv Tunnel (Android)   "
    echo "==============================================="
    echo "1. Connection Method: Set to 'DNSTT + V2Ray'"
    echo "2. DNSTT Settings:"
    echo "   - DNS Nameserver: ${NS_DOMAIN}"
    echo "   - Public Key: ${PUBKEY}"
    echo "   - DNS Resolver: 1.1.1.1 (or 8.8.8.8)"
    echo "3. V2Ray Configuration:"
    echo "   - V2Ray Server Host: 127.0.0.1"
    echo "   - V2Ray Server Port: 1080 (or your app's local DNSTT proxy port)"
    echo "   - UUID: ${XRAY_UUID}"
    echo "   - Protocol: vless"
    echo "   - Network: tcp"
    echo "   - Security: none"
    echo "   Then press Start!"
    echo "==============================================="
    echo "       VLESS & VMESS JSON CONFIGURATIONS       "
    echo "   Copy and paste these JSON blocks directly!  "
    echo "==============================================="
    echo "Note: The port '1080' below is the default DNSTT local proxy port."
    echo "If your VPN app's DNSTT listens on a different port, change it in the JSON."
    echo ""
    echo "---> VLESS CLIENT JSON <---"
    cat <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [ { "port": 10808, "listen": "127.0.0.1", "protocol": "socks", "settings": { "auth": "noauth", "udp": true } } ],
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "127.0.0.1",
            "port": 1080,
            "users": [
              { "id": "${XRAY_UUID}", "encryption": "none", "level": 0 }
            ]
          }
        ]
      },
      "streamSettings": { "network": "tcp" }
    }
  ]
}
EOF
    echo "Note: The port '1080' above is the default DNSTT local proxy port."
    echo "If your VPN app's DNSTT listens on a different port, change it in the JSON (e.g. some apps choose random ports)."
    echo ""
    echo "---> VMESS CLIENT JSON <---"
    cat <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [ { "port": 10808, "listen": "127.0.0.1", "protocol": "socks", "settings": { "auth": "noauth", "udp": true } } ],
  "outbounds": [
    {
      "protocol": "vmess",
      "settings": {
        "vnext": [
          {
            "address": "127.0.0.1",
            "port": 1080,
            "users": [
              { "id": "${XRAY_UUID}", "alterId": 0, "security": "auto" }
            ]
          }
        ]
      },
      "streamSettings": { "network": "tcp" }
    }
  ]
}
EOF
    echo ""
    echo "==============================================="
    echo "IMPORTANT REMINDER:"
    echo "If you use VLESS, set Unida Backend (Option 8) to port: 10080"
    echo "If you use VMESS, set Unida Backend (Option 8) to port: 10081"
    echo "DNSTT MUST be running in your VPN app for the above '127.0.0.1:1080' to work!"
    echo "==============================================="
    echo ""
    
    CURRENT_PORT=$(grep '^BACKEND_PORT=' /etc/default/dnstt-unida | cut -d= -f2)
    if [ "$CURRENT_PORT" != "10080" ] && [ "$CURRENT_PORT" != "10081" ]; then
        read -rp "Would you like to automatically switch your DNSTT Backend to VLESS (Port 10080)? [y/N]: " enable_v2ray
        if [[ "$enable_v2ray" =~ ^[Yy]$ ]]; then
            echo "[+] Modifying backend port to 10080 (VLESS TCP)..."
            sed -i 's/^BACKEND_PORT=.*/BACKEND_PORT=10080/g' /etc/default/dnstt-unida
            cat > /etc/default/dnstt-unida-proxy <<EOF_PROXY
PROXY_PORT=10080
EOF_PROXY
            echo "[+] Restarting services..."
            systemctl daemon-reload
            systemctl restart dnstt-unida.service dnstt-unida-proxy.service 2>/dev/null || true
            echo "[+] V2Ray / VLESS Backend is now ACTIVE."
        fi
    else
        echo "[+] DNSTT is currently forwarding to V2Ray on Port ${CURRENT_PORT} (VLESS/VMESS ACTIVE)."
    fi
    pause
}

update_unida() {
    header
    echo "--- Update Unida System ---"
    echo "This will download the latest script."
    INSTALL_URL="https://raw.githubusercontent.com/Seven7388/Unida/main/public/unida-installer.sh"
    
    # Extract current parameters
    NS_DOMAIN=$(grep "ExecStart=" /etc/systemd/system/dnstt-unida.service | sed -n 's/.*server\.key \([^ ]*\) .*/\1/p' || echo "")
    MTU_VAL=$(grep "ExecStart=" /etc/systemd/system/dnstt-unida.service | sed -n 's/.*-mtu \([0-9]*\).*/\1/p' || echo "512")
    
    if [ -z "$NS_DOMAIN" ]; then
        echo "[-] Could not parse current NS domain. Please reinstall manually."
        pause; return
    fi
    
    LOCAL_INSTALLER="/etc/dnstt/unida-installer.sh"
    REMOTE_INSTALLER="/tmp/unida-installer-new.sh"
    
    echo "[+] Checking for updates from GitHub..."
    if ! curl -sL "$INSTALL_URL?t=$(date +%s)" -o "$REMOTE_INSTALLER"; then
        echo "[-] Failed to fetch update from GitHub. Please check your internet."
        pause; return
    fi
    
    if [ -f "$LOCAL_INSTALLER" ]; then
        if cmp -s "$LOCAL_INSTALLER" "$REMOTE_INSTALLER"; then
            echo "[+] No updates found. You are already running the latest version!"
            rm -f "$REMOTE_INSTALLER"
            pause; return
        else
            echo "[+] New version found! Applying update..."
        fi
    else
        echo "[+] No local cache found. Proceeding with update to establish baseline."
    fi
    
    echo "--------------------------------------------------------"
    
    # Run the script with current domain and MTU synchronously
    if bash "$REMOTE_INSTALLER" -d "$NS_DOMAIN" -m "$MTU_VAL"; then
        echo "--------------------------------------------------------"
        echo "[+] Update completed successfully!"
        mv -f "$REMOTE_INSTALLER" "$LOCAL_INSTALLER"
    else
        echo "--------------------------------------------------------"
        echo "[-] Update failed. Please check your internet connection."
        rm -f "$REMOTE_INSTALLER"
    fi
    
    pause
}

install_adg_dnsproxy() {
    if ! command -v dnsproxy >/dev/null 2>&1; then
        echo "==> Downloading and installing Adguard dnsproxy..."
        curl -sL https://github.com/AdguardTeam/dnsproxy/releases/download/v0.73.5/dnsproxy-linux-amd64-v0.73.5.tar.gz -o dnsproxy.tar.gz
        tar -xzf dnsproxy.tar.gz
        cp linux-amd64/dnsproxy /usr/local/bin/
        chmod +x /usr/local/bin/dnsproxy
        rm -rf linux-amd64 dnsproxy.tar.gz
    fi
}

add_tunnel() {
    header
    echo "--- Add Tunnel ---"
    echo "  1) Stunnel (SSL/TLS wrapping for SSH)"
    echo "  2) WebSocket (Fake WS / HTTP Proxy on Port 80)"
    echo "  3) SOCKS5 Proxy (Port 1080)"
    echo "  4) DoT (DNS over TLS) Guide"
    echo "  5) DoH (DNS over HTTPS) Guide"
    echo "  6) Slipstream / QUIC Guide"
    echo "  7) Install ALL Tunnels (Multi-Protocol)"
    echo "  8) Install V2Ray/Xray (VLESS/VMESS)"
    echo "  0) Back to main menu"
    read -rp "Select tunnel type [0-8]: " tun_type
    
    IPV4=$(curl -s4 icanhazip.com || hostname -I | awk '{print $1}')
    NS_DOMAIN=$(grep "ExecStart=" /etc/systemd/system/dnstt-unida.service 2>/dev/null | sed -n 's/.*server\.key \([^ ]*\) .*/\1/p' || echo "yourdomain.com")

    case $tun_type in
        1)
            echo "==> Installing and configuring Stunnel on port 443 -> 22..."
            apt-get update >/dev/null 2>&1
            apt-get install -y stunnel4 >/dev/null 2>&1
            openssl genrsa -out /etc/stunnel/stunnel.key 2048 >/dev/null 2>&1
            openssl req -new -key /etc/stunnel/stunnel.key -out /etc/stunnel/stunnel.csr -subj "/C=US/ST=State/L=City/O=Unida/OU=IT/CN=unida.net" >/dev/null 2>&1
            openssl x509 -req -days 365 -in /etc/stunnel/stunnel.csr -signkey /etc/stunnel/stunnel.key -out /etc/stunnel/stunnel.crt >/dev/null 2>&1
            cat /etc/stunnel/stunnel.key /etc/stunnel/stunnel.crt > /etc/stunnel/stunnel.pem
            cat > /etc/stunnel/stunnel.conf <<EOF
pid = /var/run/stunnel4.pid
cert = /etc/stunnel/stunnel.pem
client = no
socket = a:SO_REUSEADDR=1
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1

[ssh]
accept = 443
connect = 127.0.0.1:22
EOF
            sed -i 's/ENABLED=0/ENABLED=1/' /etc/default/stunnel4
            systemctl enable stunnel4 >/dev/null 2>&1
            systemctl restart stunnel4 >/dev/null 2>&1
            echo ""
            echo "============================================="
            echo "[+] Stunnel configured successfully on port 443"
            echo "============================================="
            echo "VPN Setup Info (HTTP Custom / Injector):"
            echo " Server IP : $IPV4"
            echo " Port      : 443"
            echo " Option    : Check 'SSL' or 'TLS'"
            echo " Payload   : Not needed (uncheck Use Payload)"
            echo " SNI/Host  : sni.your-bug.com (optional)"
            echo "============================================="
            ;;
        2)
            echo "==> Installing WebSocket (Fake WS) Proxy on port 80..."
            apt-get install -y python3 >/dev/null 2>&1
            cat > /usr/local/bin/ws-proxy.py <<'EOF'
import socket, threading, sys
def handle_client(c):
    t = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        t.connect(('127.0.0.1', 22))
        req = c.recv(4096)
        if b"HTTP" in req:
            c.send(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
        else:
            t.send(req)
        def fwd(src, dst):
            try:
                while True:
                    data = src.recv(4096)
                    if not data: break
                    dst.send(data)
            except: pass
        threading.Thread(target=fwd, args=(c,t)).start()
        threading.Thread(target=fwd, args=(t,c)).start()
    except: c.close()

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('0.0.0.0', 80))
s.listen(100)
while True:
    client, addr = s.accept()
    threading.Thread(target=handle_client, args=(client,)).start()
EOF
            cat > /etc/systemd/system/ws-proxy.service <<EOF
[Unit]
Description=Fake WebSocket Proxy
After=network.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/ws-proxy.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable --now ws-proxy >/dev/null 2>&1
            echo ""
            echo "============================================="
            echo "[+] WebSocket Proxy configured successfully on port 80"
            echo "============================================="
            echo "VPN Setup Info (HTTP Custom / Injector):"
            echo " Server IP : $IPV4"
            echo " Port      : 80"
            echo " Option    : Enable 'Payload' or 'HTTP Proxy'"
            echo " Payload   : GET / HTTP/1.1[crlf]Host: domain.com[crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]"
            echo "============================================="
            ;;
        3)
            echo "==> Installing SOCKS5 Proxy (Dante) on port 1080..."
            apt-get update >/dev/null 2>&1
            apt-get install -y dante-server >/dev/null 2>&1
            ETH=$(ip route get 8.8.8.8 | awk -- '{print $5}' | head -n1)
            cat > /etc/danted.conf <<EOF
logoutput: syslog
user.privileged: root
user.unprivileged: nobody
internal: 0.0.0.0 port = 1080
external: ${ETH:-eth0}
socksmethod: username none
clientmethod: none
client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect error
}
socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect error
}
EOF
            systemctl enable danted >/dev/null 2>&1
            systemctl restart danted >/dev/null 2>&1
            echo ""
            echo "============================================="
            echo "[+] SOCKS5 configured successfully on port 1080"
            echo "============================================="
            echo "VPN Setup Info:"
            echo " Proxy Type: SOCKS5"
            echo " Server IP : $IPV4"
            echo " Port      : 1080"
            echo " Auth      : None"
            echo "============================================="
            ;;
        4)
            echo "==> Installing DoT (DNS over TLS) Proxy on port 853 TCP..."
            install_adg_dnsproxy
            cat > /etc/systemd/system/dnsproxy-dot.service <<EOF
[Unit]
Description=DNS over TLS (DoT) Proxy
After=network.target

[Service]
ExecStart=/usr/local/bin/dnsproxy -p 0 --tls-port=853 --tls-crt=/etc/stunnel/stunnel.crt --tls-key=/etc/stunnel/stunnel.key -u 127.0.0.1:53
Restart=always

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable --now dnsproxy-dot >/dev/null 2>&1
            if command -v ufw >/dev/null 2>&1; then ufw allow 853/tcp >/dev/null 2>&1 || true; fi
            iptables -I INPUT -p tcp --dport 853 -j ACCEPT
            iptables-save > /etc/iptables.up.rules
            echo ""
            echo "============================================="
            echo "[+] DoT configured successfully on port 853"
            echo "============================================="
            echo "VPN Setup Info:"
            echo " Server IP : $IPV4"
            echo " Port      : 853 (TCP)"
            echo " Setting   : Enable DoT or SSL/TLS in client."
            echo " Domain    : $NS_DOMAIN"
            echo "============================================="
            ;;
        5)
            echo "==> Installing DoH (DNS over HTTPS) Proxy..."
            install_adg_dnsproxy
            if ss -tlpn | grep -q ":443 "; then
                echo "[-] Port 443 in use (possibly Stunnel). Using 8443 for DoH."
                DOH_P=8443
            else
                DOH_P=443
            fi
            cat > /etc/systemd/system/dnsproxy-doh.service <<EOF
[Unit]
Description=DNS over HTTPS (DoH) Proxy
After=network.target

[Service]
ExecStart=/usr/local/bin/dnsproxy -p 0 --https-port=$DOH_P --tls-crt=/etc/stunnel/stunnel.crt --tls-key=/etc/stunnel/stunnel.key -u 127.0.0.1:53
Restart=always

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable --now dnsproxy-doh >/dev/null 2>&1
            if command -v ufw >/dev/null 2>&1; then ufw allow $DOH_P/tcp >/dev/null 2>&1 || true; fi
            iptables -I INPUT -p tcp --dport $DOH_P -j ACCEPT
            iptables-save > /etc/iptables.up.rules
            echo ""
            echo "============================================="
            echo "[+] DoH configured successfully on port $DOH_P"
            echo "============================================="
            echo "VPN Setup Info:"
            echo " Server IP : $IPV4"
            echo " Port      : $DOH_P (TCP)"
            echo " Path      : /dns-query"
            echo " Domain    : $NS_DOMAIN"
            echo " Setting   : Select 'HTTPS' or 'DoH' proxy."
            echo "============================================="
            ;;
        6)
            echo "==> Installing Slipstream (DNS over QUIC) on port 853 UDP..."
            install_adg_dnsproxy
            cat > /etc/systemd/system/dnsproxy-doq.service <<EOF
[Unit]
Description=DNS over QUIC (DoQ) Proxy
After=network.target

[Service]
ExecStart=/usr/local/bin/dnsproxy -p 0 --quic-port=853 --tls-crt=/etc/stunnel/stunnel.crt --tls-key=/etc/stunnel/stunnel.key -u 127.0.0.1:53
Restart=always

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable --now dnsproxy-doq >/dev/null 2>&1
            if command -v ufw >/dev/null 2>&1; then ufw allow 853/udp >/dev/null 2>&1 || true; fi
            iptables -I INPUT -p udp --dport 853 -j ACCEPT
            iptables-save > /etc/iptables.up.rules
            echo ""
            echo "============================================="
            echo "[+] DoQ configured successfully on port 853 (UDP)"
            echo "============================================="
            echo "VPN Setup Info:"
            echo " Server IP : $IPV4"
            echo " Port      : 853 (UDP)"
            echo " Domain    : $NS_DOMAIN"
            echo " Setting   : Select 'Slipstream / QUIC'."
            echo "============================================="
            ;;
        7)
            echo "==> Installing ALL Tunnel Protocols simultaneously..."
            
            # Stunnel
            apt-get update >/dev/null 2>&1; apt-get install -y stunnel4 >/dev/null 2>&1
            openssl genrsa -out /etc/stunnel/stunnel.key 2048 >/dev/null 2>&1
            openssl req -new -key /etc/stunnel/stunnel.key -out /etc/stunnel/stunnel.csr -subj "/C=US/ST=State/L=City/O=Unida/OU=IT/CN=unida.net" >/dev/null 2>&1
            openssl x509 -req -days 365 -in /etc/stunnel/stunnel.csr -signkey /etc/stunnel/stunnel.key -out /etc/stunnel/stunnel.crt >/dev/null 2>&1
            cat /etc/stunnel/stunnel.key /etc/stunnel/stunnel.crt > /etc/stunnel/stunnel.pem
            cat > /etc/stunnel/stunnel.conf <<EOF
pid = /var/run/stunnel4.pid
cert = /etc/stunnel/stunnel.pem
client = no
socket = a:SO_REUSEADDR=1
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1
[ssh]
accept = 443
connect = 127.0.0.1:22
EOF
            sed -i 's/ENABLED=0/ENABLED=1/' /etc/default/stunnel4; systemctl enable stunnel4 >/dev/null 2>&1; systemctl restart stunnel4 >/dev/null 2>&1

            # WebSocket
            apt-get install -y python3 >/dev/null 2>&1
            cat > /usr/local/bin/ws-proxy.py <<'EOF'
import socket, threading, sys
def handle_client(c):
    t = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        t.connect(('127.0.0.1', 22))
        req = c.recv(4096)
        if b"HTTP" in req:
            c.send(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
        else:
            t.send(req)
        def fwd(src, dst):
            try:
                while True:
                    data = src.recv(4096)
                    if not data: break
                    dst.send(data)
            except: pass
        threading.Thread(target=fwd, args=(c,t)).start()
        threading.Thread(target=fwd, args=(t,c)).start()
    except: c.close()

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('0.0.0.0', 80))
s.listen(100)
while True:
    client, addr = s.accept()
    threading.Thread(target=handle_client, args=(client,)).start()
EOF
            cat > /etc/systemd/system/ws-proxy.service <<EOF
[Unit]
Description=Fake WebSocket Proxy
After=network.target
[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/ws-proxy.py
Restart=always
[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload; systemctl enable --now ws-proxy >/dev/null 2>&1

            # SOCKS5
            apt-get install -y dante-server >/dev/null 2>&1
            ETH=$(ip route get 8.8.8.8 | awk -- '{print $5}' | head -n1)
            cat > /etc/danted.conf <<EOF
logoutput: syslog
user.privileged: root
user.unprivileged: nobody
internal: 0.0.0.0 port = 1080
external: ${ETH:-eth0}
socksmethod: username none
clientmethod: none
client pass { from: 0.0.0.0/0 to: 0.0.0.0/0 log: connect error }
socks pass { from: 0.0.0.0/0 to: 0.0.0.0/0 log: connect error }
EOF
            systemctl enable danted >/dev/null 2>&1; systemctl restart danted >/dev/null 2>&1

            # DoT, DoH, DoQ
            install_adg_dnsproxy
            cat > /etc/systemd/system/dnsproxy-dot.service <<EOF
[Unit]
Description=DNS over TLS (DoT) Proxy
After=network.target
[Service]
ExecStart=/usr/local/bin/dnsproxy -p 0 --tls-port=853 --tls-crt=/etc/stunnel/stunnel.crt --tls-key=/etc/stunnel/stunnel.key -u 127.0.0.1:53
Restart=always
[Install]
WantedBy=multi-user.target
EOF

            DOH_P=8443
            cat > /etc/systemd/system/dnsproxy-doh.service <<EOF
[Unit]
Description=DNS over HTTPS (DoH) Proxy
After=network.target
[Service]
ExecStart=/usr/local/bin/dnsproxy -p 0 --https-port=$DOH_P --tls-crt=/etc/stunnel/stunnel.crt --tls-key=/etc/stunnel/stunnel.key -u 127.0.0.1:53
Restart=always
[Install]
WantedBy=multi-user.target
EOF

            cat > /etc/systemd/system/dnsproxy-doq.service <<EOF
[Unit]
Description=DNS over QUIC (DoQ) Proxy
After=network.target
[Service]
ExecStart=/usr/local/bin/dnsproxy -p 0 --quic-port=853 --tls-crt=/etc/stunnel/stunnel.crt --tls-key=/etc/stunnel/stunnel.key -u 127.0.0.1:53
Restart=always
[Install]
WantedBy=multi-user.target
EOF

            systemctl daemon-reload
            systemctl enable --now dnsproxy-dot >/dev/null 2>&1
            systemctl enable --now dnsproxy-doh >/dev/null 2>&1
            systemctl enable --now dnsproxy-doq >/dev/null 2>&1

            if command -v ufw >/dev/null 2>&1; then
                ufw allow 443/tcp >/dev/null 2>&1 || true
                ufw allow 80/tcp >/dev/null 2>&1 || true
                ufw allow 1080/tcp >/dev/null 2>&1 || true
                ufw allow 853/tcp >/dev/null 2>&1 || true
                ufw allow 8443/tcp >/dev/null 2>&1 || true
                ufw allow 853/udp >/dev/null 2>&1 || true
            fi
            iptables -I INPUT -p tcp --dport 443 -j ACCEPT
            iptables -I INPUT -p tcp --dport 80 -j ACCEPT
            iptables -I INPUT -p tcp --dport 1080 -j ACCEPT
            iptables -I INPUT -p tcp --dport 853 -j ACCEPT
            iptables -I INPUT -p tcp --dport 8443 -j ACCEPT
            iptables -I INPUT -p udp --dport 853 -j ACCEPT
            iptables-save > /etc/iptables.up.rules

            echo ""
            echo "============================================="
            echo "[+] ALL TUNNELS INSTALLED SUCCESSFULLY"
            echo "============================================="
            echo " => SSH / Stunnel : Port 443"
            echo " => WebSocket     : Port 80"
            echo " => SOCKS5 Proxy  : Port 1080"
            echo " => DNS over TLS  : Port 853 (TCP)"
            echo " => DNS over HTTP : Port 8443 (TCP)"
            echo " => DNS over QUIC : Port 853 (UDP)"
            echo "============================================="
            ;;
        8)
            echo "==> Configuring V2Ray/Xray (VLESS/VMESS) DNSTT Tunnel..."
            show_v2ray_details
            ;;
        0) return ;;
        *) echo "Invalid option" ;;
    esac
    pause
}

remove_tunnel() {
    header
    echo "--- Remove Tunnel ---"
    echo "  1) Stunnel"
    echo "  2) WebSocket Proxy"
    echo "  3) SOCKS5 Server (Dante)"
    echo "  4) DoT Proxy"
    echo "  5) DoH Proxy"
    echo "  6) DoQ Proxy"
    echo "  7) ALL Proxies/Tunnels"
    echo "  0) Back to main menu"
    read -rp "Select tunnel to remove: " tun_type
    case $tun_type in
        1)
            echo "==> Removing Stunnel..."
            systemctl stop stunnel4 >/dev/null 2>&1
            systemctl disable stunnel4 >/dev/null 2>&1
            apt-get purge -y stunnel4 >/dev/null 2>&1
            rm -rf /etc/stunnel
            echo "[+] Stunnel removed successfully"
            ;;
        2)
            echo "==> Removing WebSocket Proxy..."
            systemctl stop ws-proxy >/dev/null 2>&1
            systemctl disable ws-proxy >/dev/null 2>&1
            rm -f /usr/local/bin/ws-proxy.py
            rm -f /etc/systemd/system/ws-proxy.service
            systemctl daemon-reload
            echo "[+] WebSocket Proxy removed"
            ;;
        3)
            echo "==> Removing SOCKS5 Proxy (Dante)..."
            systemctl stop danted >/dev/null 2>&1
            systemctl disable danted >/dev/null 2>&1
            apt-get purge -y dante-server >/dev/null 2>&1
            rm -f /etc/danted.conf
            echo "[+] Dante SOCKS5 removed"
            ;;
        4)
            echo "==> Removing DoT Proxy..."
            systemctl stop dnsproxy-dot >/dev/null 2>&1
            systemctl disable dnsproxy-dot >/dev/null 2>&1
            rm -f /etc/systemd/system/dnsproxy-dot.service
            systemctl daemon-reload
            echo "[+] DoT Proxy removed"
            ;;
        5)
            echo "==> Removing DoH Proxy..."
            systemctl stop dnsproxy-doh >/dev/null 2>&1
            systemctl disable dnsproxy-doh >/dev/null 2>&1
            rm -f /etc/systemd/system/dnsproxy-doh.service
            systemctl daemon-reload
            echo "[+] DoH Proxy removed"
            ;;
        6)
            echo "==> Removing DoQ Proxy..."
            systemctl stop dnsproxy-doq >/dev/null 2>&1
            systemctl disable dnsproxy-doq >/dev/null 2>&1
            rm -f /etc/systemd/system/dnsproxy-doq.service
            systemctl daemon-reload
            echo "[+] DoQ Proxy removed"
            ;;
        7)
            echo "==> Removing all configured tunnels..."
            systemctl stop stunnel4 ws-proxy danted dnsproxy-dot dnsproxy-doh dnsproxy-doq >/dev/null 2>&1
            systemctl disable stunnel4 ws-proxy danted dnsproxy-dot dnsproxy-doh dnsproxy-doq >/dev/null 2>&1
            apt-get purge -y stunnel4 dante-server >/dev/null 2>&1
            rm -rf /etc/stunnel /usr/local/bin/ws-proxy.py /etc/danted.conf
            rm -f /etc/systemd/system/ws-proxy.service /etc/systemd/system/dnsproxy-*.service
            systemctl daemon-reload
            echo "[+] All Tunnels removed successfully"
            ;;
        0) return ;;
        *) echo "Invalid option" ;;
    esac
    pause
}

check_update() {
    INSTALL_URL="https://raw.githubusercontent.com/Seven7388/Unida/main/public/unida-installer.sh"
    LOCAL_INSTALLER="/etc/dnstt/unida-installer.sh"
    REMOTE_INSTALLER="/tmp/unida-installer-new.sh"
    
    if curl -sL "$INSTALL_URL?t=$(date +%s)" -o "$REMOTE_INSTALLER" 2>/dev/null; then
        if [ -f "$LOCAL_INSTALLER" ]; then
            if ! cmp -s "$LOCAL_INSTALLER" "$REMOTE_INSTALLER" 2>/dev/null; then
                echo -e "\033[1;33m[*] A new version of Unida Installer is available!\033[0m"
                echo -e "\033[1;33m[*] You can update by selecting option 11.\033[0m"
                echo ""
                sleep 2
            fi
        fi
        rm -f "$REMOTE_INSTALLER"
    fi
}

run_diagnostics() {
    header
    echo "--- Run Diagnostics ---"
    echo "[*] Checking common ports for blockers..."
    
    PORTS=(53 5300 7300 22 80 443 1080 853 8443)
    for p in "${PORTS[@]}"; do
        if ss -tulpen | grep -q ":$p "; then
            B_PROC=$(ss -tulpen | grep ":$p " | awk '{print $9}' | head -n1 | cut -d'"' -f2 || echo "Unknown")
            echo -e "  [+] Port $p is heavily USED by: \033[1;31m$B_PROC\033[0m"
        else
            echo "  [-] Port $p is FREE"
        fi
    done
    
    echo ""
    echo "[*] Checking TCP BBR Congestion Control..."
    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo -e "  [+] BBR is \033[1;32mACTIVE\033[0m"
    else
        echo -e "  [-] BBR is \033[1;31mNOT ACTIVE\033[0m"
    fi
    
    echo ""
    echo "[*] Checking SSH/SSHD Status..."
    if systemctl is-active --quiet sshd; then
        echo -e "  [+] sshd is \033[1;32mRUNNING\033[0m"
    else
        echo -e "  [-] sshd is \033[1;31mSTOPPED/FAILED\033[0m"
    fi
    if systemctl is-active --quiet ssh; then
        echo -e "  [+] ssh is \033[1;32mRUNNING\033[0m"
    fi

    pause
}

main_menu() {
    check_update
    while true; do
        header
        echo "  1) Create new SSH User"
        echo "  2) Delete SSH User"
        echo "  3) List all SSH Users"
        echo "  4) Show DNSTT Tunnel Status"
        echo "  5) View Live Logs"
        echo "  6) Restart DNSTT Services"
        echo "  7) Show Server Public Key"
        echo "  8) Change Backend Target (SOCKS5/SSH/VLESS)"
        echo "  9) Change MTU Size"
        echo " 10) V2Ray DNSTT Configs & Setup"
        echo " 11) Update Unida System (From URL)"
        echo " 12) Uninstall Unida Server"
        echo " 13) Add Tunnel"
        echo " 14) Remove Tunnel"
        echo " 15) Run Diagnostics (Port Check & BBR)"
        echo " 16) Refresh & Optimize Tunnels"
        echo "  0) Exit"
        echo "==============================================="
        read -rp "Select an option [0-16]: " choice
        case $choice in
            1) create_user ;;
            2) delete_user ;;
            3) list_users ;;
            4) show_status ;;
            5) view_logs ;;
            6) restart_services ;;
            7) show_key ;;
            8) change_backend ;;
            9) change_mtu ;;
            10) show_v2ray_details ;;
            11) update_unida ;;
            12) uninstall_unida ;;
            13) add_tunnel ;;
            14) remove_tunnel ;;
            15) run_diagnostics ;;
            16)
                header
                echo "[+] Running Auto-Clean and Speed Optimizer..."
                if [ -x /usr/local/bin/speed-optimizer ]; then
                    /usr/local/bin/speed-optimizer
                else
                    echo "[-] speed-optimizer not found. Installing..."
                fi
                pause
                ;;
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

echo "==> Configuring Network Forwarding, BBR Congestion Control, and IPTables for Internet Access..."
# Enable BBR kernel module (or fall back if unavailable)
cat > /etc/modules-load.d/bbr.conf <<EOF
tcp_bbr
EOF
modprobe tcp_bbr >/dev/null 2>&1 || true

# Limit Configurations
cat > /etc/security/limits.d/unida.conf <<EOF
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 1048576
* hard nproc 1048576
root soft nofile 1048576
root hard nofile 1048576
root soft nproc 1048576
root hard nproc 1048576
EOF
echo "session required pam_limits.so" >> /etc/pam.d/common-session
echo "fs.file-max = 1048576" >> /etc/sysctl.conf
echo "fs.inotify.max_user_instances = 8192" >> /etc/sysctl.conf

# Enable IPv4 forwarding
sed -i '/net.ipv4.ip_forward/s/^#//g' /etc/sysctl.conf
if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
  echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi
if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
  echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
fi
if ! grep -q "net.ipv4.tcp_congestion_control=" /etc/sysctl.conf; then
  # Prefer BBR, fallback to cubic or reno depending on kernel support
  echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
else
  sed -i 's/^net.ipv4.tcp_congestion_control=.*/net.ipv4.tcp_congestion_control=bbr/' /etc/sysctl.conf
fi
if ! grep -q "net.ipv4.tcp_window_scaling=1" /etc/sysctl.conf; then
  cat >> /etc/sysctl.conf <<EOF_SYSCTL
net.ipv4.tcp_window_scaling=1
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 16384 67108864
net.ipv4.udp_mem=65536 131072 262144
net.ipv4.udp_rmem_min=16384
net.ipv4.udp_wmem_min=16384
net.core.optmem_max=65536
net.core.netdev_max_backlog=65536
net.core.somaxconn=65535
net.ipv4.tcp_max_syn_backlog=65536
net.ipv4.tcp_max_tw_buckets=1440000
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_probes=5
net.ipv4.tcp_keepalive_intvl=15
net.ipv4.tcp_syncookies=1
net.netfilter.nf_conntrack_max=2000000
net.netfilter.nf_conntrack_tcp_timeout_established=7200
net.netfilter.nf_conntrack_udp_timeout=30
net.netfilter.nf_conntrack_udp_timeout_stream=60
net.ipv4.ip_local_port_range=1024 65535
EOF_SYSCTL
fi
sed -i 's/16777216/67108864/g' /etc/sysctl.conf
sysctl -p >/dev/null 2>&1

cat > /etc/cron.d/unida-autoclean << 'EOF_CRON'
# UNIDA Auto Cleaner & Speed Optimizer - Runs Option 16 automatically every 2 hours
0 */2 * * * root /usr/local/bin/speed-optimizer >/dev/null 2>&1
EOF_CRON
chmod 644 /etc/cron.d/unida-autoclean
systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null || true



# Setup IPTables Masquerade for internet access through the VPN/SSH Tunnel
ETH=$(ip route get 8.8.8.8 | awk -- '{printf $5}')
if [ -n "$ETH" ]; then
  iptables -t nat -A POSTROUTING -o "$ETH" -j MASQUERADE
  iptables -P FORWARD ACCEPT
  iptables -I FORWARD -o "$ETH" -j ACCEPT
  iptables -I FORWARD -i "$ETH" -m state --state RELATED,ESTABLISHED -j ACCEPT
  if [ "${PROXY_PORT}" != "53" ]; then
    iptables -t nat -A PREROUTING -i "$ETH" -p udp --dport 53 -j REDIRECT --to-ports "${PROXY_PORT}"
  fi
  
  # Ensure critical ports are open before saving
  iptables -I INPUT -p tcp --dport 22 -j ACCEPT
  iptables -I INPUT -p udp --dport 53 -j ACCEPT
  iptables -I INPUT -p udp --dport "${PROXY_PORT}" -j ACCEPT
  iptables -I INPUT -p tcp --dport 80 -j ACCEPT
  iptables -I INPUT -p tcp --dport 443 -j ACCEPT
  iptables -I INPUT -p tcp --dport 1080 -j ACCEPT
  iptables -I INPUT -p tcp --dport 7300 -j ACCEPT
  
  # Block outgoing QUIC (UDP 443) to force Instagram/YouTube to use TCP
  # This makes DNSTT much faster by avoiding UDP fragmentation.
  iptables -A OUTPUT -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable
  iptables -I FORWARD -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable

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
sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config
sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config
if ! grep -q "^PasswordAuthentication yes" /etc/ssh/sshd_config; then echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config; fi
sed -i 's/^#AllowTcpForwarding.*/AllowTcpForwarding yes/g' /etc/ssh/sshd_config
sed -i 's/^#GatewayPorts.*/GatewayPorts yes/g' /etc/ssh/sshd_config
if ! grep -q "^AllowTcpForwarding yes" /etc/ssh/sshd_config; then echo "AllowTcpForwarding yes" >> /etc/ssh/sshd_config; fi
if ! grep -q "^GatewayPorts yes" /etc/ssh/sshd_config; then echo "GatewayPorts yes" >> /etc/ssh/sshd_config; fi
if ! grep -q "^TCPKeepAlive yes" /etc/ssh/sshd_config; then echo "TCPKeepAlive yes" >> /etc/ssh/sshd_config; fi
sed -i 's/^#ClientAliveInterval.*/ClientAliveInterval 300/g' /etc/ssh/sshd_config
if ! grep -q "^ClientAliveInterval" /etc/ssh/sshd_config; then echo "ClientAliveInterval 300" >> /etc/ssh/sshd_config; else sed -i 's/^ClientAliveInterval.*/ClientAliveInterval 300/g' /etc/ssh/sshd_config; fi
sed -i 's/^#ClientAliveCountMax.*/ClientAliveCountMax 5/g' /etc/ssh/sshd_config
if ! grep -q "^ClientAliveCountMax" /etc/ssh/sshd_config; then echo "ClientAliveCountMax 5" >> /etc/ssh/sshd_config; else sed -i 's/^ClientAliveCountMax.*/ClientAliveCountMax 5/g' /etc/ssh/sshd_config; fi
sed -i 's/^#UseDNS.*/UseDNS no/g' /etc/ssh/sshd_config
if ! grep -q "^UseDNS no" /etc/ssh/sshd_config; then echo "UseDNS no" >> /etc/ssh/sshd_config; fi

# Enable Legacy SSH Algorithms for older VPN clients (HTTP Custom, etc)
if ! grep -q "^KexAlgorithms" /etc/ssh/sshd_config; then echo "KexAlgorithms +diffie-hellman-group1-sha1,diffie-hellman-group14-sha1,diffie-hellman-group-exchange-sha1,diffie-hellman-group-exchange-sha256" >> /etc/ssh/sshd_config; fi
if ! grep -q "^Ciphers" /etc/ssh/sshd_config; then echo "Ciphers +aes128-cbc,aes192-cbc,aes256-cbc,3des-cbc" >> /etc/ssh/sshd_config; fi
if ! grep -q "^HostKeyAlgorithms" /etc/ssh/sshd_config; then echo "HostKeyAlgorithms +ssh-rsa,ssh-dss" >> /etc/ssh/sshd_config; fi
if ! grep -q "^PubkeyAcceptedKeyTypes" /etc/ssh/sshd_config; then echo "PubkeyAcceptedKeyTypes +ssh-rsa,ssh-dss" >> /etc/ssh/sshd_config; fi

cat > /etc/issue.net << 'EOF_BANNER'
<br>
<div style="text-align:center">
  <font color="#00FFFF"><b>🚀 UNIDA 🚀</b></font><br>
  <font color="#FFFFFF">by</font><br>
  <font color="#FF0000"><b>Sixbravo</b></font> <font color="#FFFFFF">&amp;</font> <font color="#FFFF00"><b>BunyaBoy</b></font>
</div>
<br>
EOF_BANNER

sed -i 's/^#Banner.*/Banner \/etc\/issue.net/g' /etc/ssh/sshd_config
if ! grep -q "^Banner /etc/issue.net" /etc/ssh/sshd_config; then echo "Banner /etc/issue.net" >> /etc/ssh/sshd_config; fi

sed -i 's/^#IPQoS.*/IPQoS cs0 cs0/g' /etc/ssh/sshd_config
sed -i 's/^IPQoS lowdelay throughput/IPQoS cs0 cs0/g' /etc/ssh/sshd_config
if ! grep -q "^IPQoS cs0 cs0" /etc/ssh/sshd_config; then echo "IPQoS cs0 cs0" >> /etc/ssh/sshd_config; fi
sed -i 's/^#MaxSessions.*/MaxSessions 10000/g' /etc/ssh/sshd_config
if ! grep -q "^MaxSessions" /etc/ssh/sshd_config; then echo "MaxSessions 10000" >> /etc/ssh/sshd_config; else sed -i 's/^MaxSessions.*/MaxSessions 10000/g' /etc/ssh/sshd_config; fi
sed -i 's/^#MaxStartups.*/MaxStartups 1000:30:10000/g' /etc/ssh/sshd_config
if ! grep -q "^MaxStartups" /etc/ssh/sshd_config; then echo "MaxStartups 1000:30:10000" >> /etc/ssh/sshd_config; else sed -i 's/^MaxStartups.*/MaxStartups 1000:30:10000/g' /etc/ssh/sshd_config; fi
sed -i 's/^#LoginGraceTime.*/LoginGraceTime 120/g' /etc/ssh/sshd_config
if ! grep -q "^LoginGraceTime" /etc/ssh/sshd_config; then echo "LoginGraceTime 120" >> /etc/ssh/sshd_config; fi
systemctl daemon-reload
if sshd -t >/dev/null 2>&1; then
  systemctl restart sshd >/dev/null 2>&1 || systemctl restart ssh >/dev/null 2>&1 || true
else
  # Emergency rollback if syntax is broken
  echo "WARNING: sshd_config syntax error detected! Rolling back some settings to prevent lockout."
  cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config 2>/dev/null || true
  systemctl restart sshd >/dev/null 2>&1 || systemctl restart ssh >/dev/null 2>&1 || true
fi

echo "==> Starting services..."
systemctl daemon-reload
systemctl enable --now dnstt-unida.service
systemctl enable --now dnstt-unida-proxy.service
if [ -f /etc/systemd/system/badvpn-udpgw.service ]; then
  systemctl enable --now badvpn-udpgw.service
  systemctl enable --now badvpn-udpgw-ipv6.service 2>/dev/null || true
fi

if command -v ufw >/dev/null 2>&1; then
  ufw allow 22/tcp >/dev/null 2>&1 || true
  ufw allow 80/tcp >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
  ufw allow 1080/tcp >/dev/null 2>&1 || true
  ufw allow 53/udp >/dev/null 2>&1 || true
  ufw allow ${PROXY_PORT}/udp >/dev/null 2>&1 || true
  ufw allow 7300/tcp >/dev/null 2>&1 || true
  if [ -f /etc/default/ufw ]; then
    sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/g' /etc/default/ufw
  fi
  ufw reload >/dev/null 2>&1 || true
fi

# Install custom scripts to /usr/local/bin so they can be run globally by the user
################################################################################

# 1. speed-optimizer
cat > /usr/local/bin/speed-optimizer << 'EOF_SPEED'
#!/bin/bash
# VPS Speed Optimizer & Memory Cleaner
# This script applies aggressive network tuning and clears cache

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo)"
  exit 1
fi

echo "🚀 Applying aggressive network tuning for Tunneling..."

# Clear Old Sysctl settings
cat > /etc/sysctl.conf << 'SYSCTL_EOF'
# Optimized Sysctl for Tunneling (VPN/DNSTT)
fs.file-max = 2097152
fs.inotify.max_user_instances = 8192
net.ipv4.ip_forward=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# Network buffer tuning
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# Connection Limits and UDP tuning
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65536
net.ipv4.tcp_max_syn_backlog = 65536
net.ipv4.tcp_max_tw_buckets = 1440000
net.netfilter.nf_conntrack_max = 2000000
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 60

# Aggressive Timeout and Keepalive (fixes dropping connections over time)
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_syncookies = 1
SYSCTL_EOF

sysctl -p

echo "🧹 Clearing RAM & DROP CACHE..."
sync; echo 3 > /proc/sys/vm/drop_caches

echo "🔄 Restarting Tunneling Services to clear stalled connections..."
systemctl restart badvpn-udpgw 2>/dev/null || true
systemctl restart badvpn-udpgw-ipv6 2>/dev/null || true
systemctl restart sshd 2>/dev/null || true
systemctl restart stunnel4 2>/dev/null || true
systemctl restart xray 2>/dev/null || true
systemctl restart dnstt-unida 2>/dev/null || true

echo "✅ Optimization Complete! Your Network should be faster and stable."
EOF_SPEED
chmod +x /usr/local/bin/speed-optimizer

# 2. auto-clean script installer
cat > /usr/local/bin/auto-clean << 'EOF_AUTOCLEAN'
#!/bin/bash
# Install Auto-Clean Cronjob

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo)"
  exit 1
fi

CRON_FILE="/etc/cron.d/unida-autoclean"

cat > "$CRON_FILE" << 'EOF'
# UNIDA Auto Cleaner & Speed Optimizer - Runs Option 16 automatically every 2 hours
0 */2 * * * root /usr/local/bin/speed-optimizer >/dev/null 2>&1
EOF

chmod 644 "$CRON_FILE"
systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null || true

echo "✅ Auto-Clean Cronjob Installed (Runs every 2 hours)!"
echo "This will help prevent speed degradation over time by refreshing the cache and stalled VPN services."
EOF_AUTOCLEAN
chmod +x /usr/local/bin/auto-clean

# 3. ssh-burner 
cat > /usr/local/bin/ssh-burner << 'EOF_BURNER'
#!/bin/bash
# Minimal SSH Burner - Create temporary SSH users for tunneling

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo)"
  exit 1
fi

if [ $# -lt 3 ]; then
  echo "Usage: $0 <username> <password> <days_valid>"
  echo "Example: $0 testuser testpass 7"
  exit 1
fi

USERNAME=$1
PASSWORD=$2
DAYS=$3

# Calculate expiration date exactly as useradd requires (YYYY-MM-DD)
EXPDATE=$(date -d "+${DAYS} days" +"%Y-%m-%d")

# Check if user already exists
if id "$USERNAME" &>/dev/null; then
    echo "Error: User '$USERNAME' already exists!"
    exit 1
fi

# Create user (-e = expiry, -M = no home directory, -s = no shell access/only tunneling)
useradd -e "$EXPDATE" -M -s /bin/false "$USERNAME"

# Set password
echo "${USERNAME}:${PASSWORD}" | chpasswd

# Clear cleartext variables just in case
history -c 2>/dev/null || true

echo ""
echo "✅ SSH Account Created Successfully"
echo "======================================="
echo "  Username     : $USERNAME"
echo "  Password     : $PASSWORD"
echo "  Valid for    : $DAYS Days"
echo "  Expires on   : $EXPDATE"
echo "======================================="
EOF_BURNER
chmod +x /usr/local/bin/ssh-burner

################################################################################

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

# Cache installer for future update checks
curl -sL "https://raw.githubusercontent.com/Seven7388/Unida/main/public/unida-installer.sh" -o /etc/dnstt/unida-installer.sh 2>/dev/null || true