#!/usr/bin/env bash
set -euo pipefail

echo "==> Unida DNSTT Server Installer (clean + stable + optimized)"

# Root check
if [ "$(id -u)" -ne 0 ]; then
  echo "[-] Tafadhali run kama root: sudo bash $0"
  exit 1
fi

read -rp "Ingiza DNS tunnel domain (mfano: ns-unida.skychart.online): " TDOMAIN
if [ -z "${TDOMAIN:-}" ]; then
  echo "[-] Domain haiwezi kuwa tupu."
  exit 1
fi

MTU="${MTU:-1232}"
DNSTT_PORT="${DNSTT_PORT:-5300}"   # dnstt-server internal UDP
PROXY_PORT="${PROXY_PORT:-53}"     # public UDP

echo "==> Domain: ${TDOMAIN}"
echo "==> MTU   : ${MTU}"
sleep 1

echo "==> Kuzima old dnstt/slowdns services kama zipo..."
for svc in dnstt-smart dnstt dnstt-server dnstt-b dnstt-proxy dnsttloc slowdns dnstt-unida dnstt-unida-proxy; do
  systemctl disable --now "${svc}.service" 2>/dev/null || true
done

# Free port 53 from systemd-resolved stub
if [ -f /etc/systemd/resolved.conf ]; then
  echo "==> Kusetup systemd-resolved (DNSStubListener=no)..."
  if grep -q '^#DNSStubListener=' /etc/systemd/resolved.conf; then
    sed -i 's/^#DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
  elif grep -q '^DNSStubListener=' /etc/systemd/resolved.conf; then
    sed -i 's/^DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
  else
    echo "DNSStubListener=no" >> /etc/systemd/resolved.conf
  fi

  if grep -q '^DNS=' /etc/systemd/resolved.conf; then
    sed -i 's/^DNS=.*/DNS=8.8.8.8 8.8.4.4/' /etc/systemd/resolved.conf
  else
    echo "DNS=8.8.8.8 8.8.4.4" >> /etc/systemd/resolved.conf
  fi

  systemctl restart systemd-resolved || true
  ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf || true
fi

echo "==> Installing packages..."
apt-get update -y
apt-get install -y curl python3 nginx >/dev/null 2>&1 || true

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

# dnstt-server internal on 5300 UDP and public on 53 TCP
echo "==> Kuunda service /etc/systemd/system/dnstt-unida.service..."
cat >/etc/systemd/system/dnstt-unida.service <<EOF
[Unit]
Description=Unida DNSTT DNS Tunnel (stable)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/dnstt-server -udp 127.0.0.1:${DNSTT_PORT} -tcp :53 -mtu ${MTU} -privkey-file /etc/dnstt/server.key ${TDOMAIN} 127.0.0.1:22
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# EDNS Proxy (public :53 -> internal :5300)
echo "==> Kuunda EDNS proxy (512 <-> 1232)..."
cat >/usr/local/bin/dnstt-edns-proxy.py <<'PY'
#!/usr/bin/env python3
import socket, threading, struct

LISTEN_HOST="0.0.0.0"
LISTEN_PORT=53
UPSTREAM_HOST="127.0.0.1"
UPSTREAM_PORT=5300

EXTERNAL_EDNS_SIZE=512
INTERNAL_EDNS_SIZE=1232

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

# Start services
echo "==> Kuanza services..."
systemctl daemon-reload
systemctl enable --now dnstt-unida.service
systemctl enable --now dnstt-unida-proxy.service

# Firewall (if ufw)
if command -v ufw >/dev/null 2>&1; then
  ufw allow 22/tcp || true
  ufw allow 53/udp || true
  ufw allow 53/tcp || true
fi

IPV4=$(hostname -I | awk '{print $1}')

echo
echo "==============================================="
echo "        UNIDA DNSTT SERVER READY"
echo "==============================================="
echo "Server IP        : ${IPV4}"
echo "Tunnel Domain    : ${TDOMAIN}"
echo "MTU              : ${MTU}"
echo "dnstt-server     : UDP 127.0.0.1:${DNSTT_PORT}, TCP :53"
echo "proxy public     : UDP :${PROXY_PORT}"
echo
echo "Public key:"
cat /etc/dnstt/server.pub || true
echo
echo "Quick status:"
systemctl --no-pager --full status dnstt-unida.service | head -n 12 || true
systemctl --no-pager --full status dnstt-unida-proxy.service | head -n 12 || true
echo "==============================================="
