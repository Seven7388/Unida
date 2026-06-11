import fs from 'fs';

// 1. the python script text
const ednsScript = `
cat >/usr/local/bin/dnsgb-edns-proxy.py <<'EOF_PY'
#!/usr/bin/env python3
import socket, struct, concurrent.futures, sys
if len(sys.argv) < 7:
    print("Usage: proxy.py listen_host listen_port upstream_host upstream_port ext_mtu int_mtu")
    sys.exit(1)

LISTEN_HOST = sys.argv[1]
LISTEN_PORT = int(sys.argv[2])
UPSTREAM_HOST = sys.argv[3]
UPSTREAM_PORT = int(sys.argv[4])
EXTERNAL_EDNS_SIZE = int(sys.argv[5])
INTERNAL_EDNS_SIZE = int(sys.argv[6])

def extract_and_patch_edns(data: bytes, new_size: int):
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
    try:
        upstream_sock.settimeout(2.0)
        upstream_data, orig_size = extract_and_patch_edns(data, INTERNAL_EDNS_SIZE)
        upstream_sock.sendto(upstream_data, (UPSTREAM_HOST, UPSTREAM_PORT))
        resp, _ = upstream_sock.recvfrom(4096)
        
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
chmod +x /usr/local/bin/dnsgb-edns-proxy.py
`;

const udpgwScript = `
    print_info "Downloading and Installing High-Performance BadVPN UDPGW..."
    wget -q -O /usr/local/bin/badvpn-udpgw https://raw.githubusercontent.com/daybreakersx/premscript/master/badvpn-udpgw64
    chmod +x /usr/local/bin/badvpn-udpgw

    cat >/etc/systemd/system/badvpn-udpgw.service <<EOF
[Unit]
Description=BadVPN UDPGW Service
After=network.target

[Service]
Type=simple
LimitNOFILE=1048576
LimitNPROC=1048576
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 1000 --max-connections-for-client 10
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    cat >/etc/systemd/system/badvpn-udpgw-ipv6.service <<EOF
[Unit]
Description=BadVPN UDPGW Service IPv6
After=network.target

[Service]
Type=simple
LimitNOFILE=1048576
LimitNPROC=1048576
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr [::1]:7300 --max-clients 1000 --max-connections-for-client 10
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now badvpn-udpgw.service badvpn-udpgw-ipv6.service 2>/dev/null || true
`;

const speedOptimizerScript = `
    print_info "Installing Auto-Clean and Speed Optimizer..."
    cat > /usr/local/bin/speed-optimizer << 'EOF_SPEED'
#!/bin/bash
# VPS Speed Optimizer & Memory Cleaner
if [ "\$EUID" -ne 0 ]; then exit 1; fi
cat > /etc/sysctl.conf << 'SYSCTL_EOF'
fs.file-max = 2097152
fs.inotify.max_user_instances = 8192
net.ipv4.ip_forward=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65536
net.ipv4.tcp_max_syn_backlog = 65536
net.ipv4.tcp_max_tw_buckets = 1440000
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_syncookies = 1
SYSCTL_EOF
sysctl -p >/dev/null 2>&1
sync; echo 3 > /proc/sys/vm/drop_caches
systemctl restart badvpn-udpgw badvpn-udpgw-ipv6 sshd dnsgb-dnsrouter 2>/dev/null || true
EOF_SPEED
    chmod +x /usr/local/bin/speed-optimizer
    
    cat > /etc/cron.d/dnsgb-autoclean << 'EOF_CRON'
0 */2 * * * root /usr/local/bin/speed-optimizer >/dev/null 2>&1
EOF_CRON
    chmod 644 /etc/cron.d/dnsgb-autoclean
    
    /usr/local/bin/speed-optimizer
`;

const overrideFnScript = `
create_edns_service_override() {
    local tag="$1"
    local service="dnsgb-\${tag}.service"
    local dropin_dir="/etc/systemd/system/\${service}.d"
    local dropin_file="\${dropin_dir}/10-edns-proxy.conf"

    local orig_exec
    orig_exec=$(systemctl cat "\$service" 2>/dev/null | grep '^ExecStart=/' | head -1 || true)
    if [[ -z "\$orig_exec" ]]; then
        orig_exec=$(systemctl cat "\$service" 2>/dev/null | grep '^ExecStart=.*dnstt-server' | tail -1 || true)
    fi
    if [[ -z "\$orig_exec" ]]; then
        print_fail "Could not read ExecStart from \${service}"
        return 1
    fi

    local tunnel_port
    tunnel_port=$(echo "\$orig_exec" | grep -oE '\-udp[[:space:]]+[^ ]+' | grep -oE '[0-9]+$' || true)
    if [[ -z "\$tunnel_port" ]]; then return 1; fi

    local privkey_path
    privkey_path=$(echo "\$orig_exec" | grep -oE '\-privkey-file\s+[^ ]+' | sed 's/-privkey-file\s*//' || true)
    if [[ -z "\$privkey_path" ]]; then privkey_path="/etc/dnsgb/tunnels/\${tag}/server.key"; fi

    local mtu_val
    mtu_val=$(echo "\$orig_exec" | grep -oE '\-mtu\s+[0-9]+' | grep -oE '[0-9]+' || true)
    if [[ -z "\$mtu_val" ]]; then mtu_val=1398; fi

    local positional
    positional=$(echo "\$orig_exec" | sed 's|^ExecStart=[^ ]*||; s|-udp[[:space:]]*[^ ]*||; s|-privkey-file[[:space:]]*[^ ]*||; s|-mtu[[:space:]]*[0-9]*||' | xargs || true)
    domain=$(echo "\$positional" | awk '{print $1}')
    upstream=$(echo "\$positional" | awk '{print $2}')
    if [[ -z "\$domain" || -z "\$upstream" ]]; then return 1; fi

    local up_port=\$((tunnel_port + 10000))
    if [[ "\$up_port" -gt 65535 ]]; then up_port=\$((tunnel_port - 10000)); fi

    mkdir -p "\$dropin_dir" 2>/dev/null || true

    cat > "\$dropin_file" <<EOF
[Service]
ExecStart=
ExecStart=/bin/sh -c 'python3 /usr/local/bin/dnsgb-edns-proxy.py 127.0.0.1 \${tunnel_port} 127.0.0.1 \${up_port} 1800 \${mtu_val} & exec /usr/local/bin/dnstt-server -udp :\${up_port} -privkey-file \${privkey_path} -mtu \${mtu_val} \${domain} \${upstream}'
EOF
    systemctl daemon-reload
    print_ok "EDNS Proxy override added: \${service}"
}
`;

let text = fs.readFileSync('public/dnsgb-setup.sh', 'utf-8');

// Inject the override helper function
text = text.replace('create_noizdns_service_override() {', overrideFnScript + '\ncreate_noizdns_service_override() {');

// Inject BadVPN, EDNS Proxy python script, and Speed optimizer into step_install_dnsgb
let injectPoint = '    ensure_vaydns_binary || true\n    fi';
text = text.replace(injectPoint, injectPoint + '\n' + ednsScript + '\n' + udpgwScript + '\n' + speedOptimizerScript);

// Add create_edns_service_override for dnstt1 and dnstt-ssh
// Find dnstt tunnel output and override it
let dnstt1Inject = `
    if [[ -n "$DNSTT_PUBKEY" ]]; then
        print_ok "Created: dnstt1 (DNSTT + SOCKS) on d.\${DOMAIN}"
`;
text = text.replace(dnstt1Inject, `
    create_edns_service_override "dnstt1"
    systemctl restart dnsgb-dnstt1.service 2>/dev/null || true
` + dnstt1Inject);

let dnsttSshInject = `
    if dnsgb tunnel add --transport dnstt --backend ssh --domain "ds.\${DOMAIN}" --tag "$dnstt_ssh_tag" --mtu "$DNSTT_MTU" 2>&1; then
        print_ok "Created: \${dnstt_ssh_tag} (DNSTT + SSH) on ds.\${DOMAIN}"
`;
text = text.replace(dnsttSshInject, dnsttSshInject + `
        create_edns_service_override "$dnstt_ssh_tag"
        systemctl restart dnsgb-\${dnstt_ssh_tag}.service 2>/dev/null || true
`);

fs.writeFileSync('public/dnsgb-setup.sh', text);

