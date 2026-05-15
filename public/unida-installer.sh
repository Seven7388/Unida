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

# If domain wasn't provided via flag, prompt
if [ -z "$TDOMAIN" ]; then
  read -rp "Ingiza DNS tunnel domain (mfano: ns-unida.skychart.online): " TDOMAIN
fi

if [ -z "$TDOMAIN" ]; then
  echo "[-] Domain haiwezi kuwa tupu."
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
DEBIAN_FRONTEND=noninteractive apt-get install -y curl python3 wget >/dev/null 2>&1 || true

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

show_help() {
    echo "==============================================="
    echo "       Unida DNSTT Manager CLI"
    echo "==============================================="
    echo "Usage: unida <command>"
    echo ""
    echo "Commands:"
    echo "  useradd <username> [password] - Create a new SSH user"
    echo "  userdel <username>            - Delete an SSH user"
    echo "  users                           - List all SSH users"
    echo "  status                          - Show DNSTT tunnel status"
    echo "  logs [tunnel|proxy]             - View live logs"
    echo "  restart                         - Restart DNSTT services"
    echo "  key                             - Show the server public key"
    echo "  help                            - Show this help message"
    echo "==============================================="
}

if [ "$#" -eq 0 ]; then
    show_help
    exit 0
fi

CMD=$1
shift

case "$CMD" in
    useradd)
        if [ "$#" -lt 1 ]; then
            echo "Usage: unida useradd <username> [password]"
            exit 1
        fi
        USER=$1
        PASS=${2:-}

        if id "$USER" &>/dev/null; then
            echo "[-] User $USER already exists!"
            exit 1
        fi

        useradd -m -s /bin/false "$USER"
        if [ -n "$PASS" ]; then
            echo "$USER:$PASS" | chpasswd
            echo "[+] Created user: $USER with provided password."
        else
            echo "[+] Created user: $USER. No password set."
            passwd "$USER"
        fi
        ;;
    userdel)
        if [ "$#" -lt 1 ]; then
            echo "Usage: unida userdel <username>"
            exit 1
        fi
        USER=$1
        if ! id "$USER" &>/dev/null; then
            echo "[-] User $USER doesn't exist!"
            exit 1
        fi
        userdel -r "$USER"
        echo "[+] Deleted user: $USER"
        ;;
    users)
        echo "--- List of created SSH tunnel users ---"
        awk -F':' '/\/bin\/false/{print "- " $1}' /etc/passwd
        ;;
    status)
        echo "--- Tunnel Status ---"
        systemctl status dnstt-unida.service --no-pager || true
        echo ""
        echo "--- Proxy Status ---"
        systemctl status dnstt-unida-proxy.service --no-pager || true
        ;;
    logs)
        if [ "$#" -gt 0 ] && [ "$1" == "proxy" ]; then
            journalctl -u dnstt-unida-proxy.service -f
        else
            journalctl -u dnstt-unida.service -f
        fi
        ;;
    restart)
        echo "[+] Restarting services..."
        systemctl restart dnstt-unida.service dnstt-unida-proxy.service
        echo "[+] Services restarted successfully."
        ;;
    key)
        echo "Public Key:"
        cat /etc/dnstt/server.pub 2>/dev/null || echo "Key not found!"
        ;;
    help)
        show_help
        ;;
    *)
        echo "[-] Unknown command: $CMD"
        show_help
        exit 1
        ;;
esac
EOF_MANAGER
chmod +x /usr/local/bin/unida

echo "==> Starting services..."
systemctl daemon-reload
systemctl enable --now dnstt-unida.service
systemctl enable --now dnstt-unida-proxy.service

if command -v ufw >/dev/null 2>&1; then
  ufw allow 22/tcp >/dev/null 2>&1 || true
  ufw allow 53/udp >/dev/null 2>&1 || true
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
echo ""
echo "Public key:"
cat /etc/dnstt/server.pub || true
echo ""
echo "🔥 NEW: Use the 'unida' command to manage your server!"
echo "    Add SSH user    : unida useradd username password"
echo "    Check status    : unida status"
echo "    See all commands: unida help"
echo "==============================================="
