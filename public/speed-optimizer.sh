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

# Connection Limits
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65536
net.ipv4.tcp_max_syn_backlog = 65536
net.ipv4.tcp_max_tw_buckets = 1440000

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
systemctl restart sshd 2>/dev/null || true
systemctl restart dnstt-unida 2>/dev/null || true

echo "✅ Optimization Complete! Your Network should be faster and stable."
