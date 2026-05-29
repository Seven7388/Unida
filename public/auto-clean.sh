#!/bin/bash
# Install Auto-Clean Cronjob

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo)"
  exit 1
fi

CRON_FILE="/etc/cron.d/unida-autoclean"

cat > "$CRON_FILE" << 'EOF'
# UNIDA Auto Cleaner - Clears RAM and restarts stalled services every 4 hours
0 */4 * * * root /bin/sync && /usr/bin/echo 3 > /proc/sys/vm/drop_caches && /bin/systemctl restart badvpn-udpgw 2>/dev/null && /bin/systemctl restart dnstt-unida 2>/dev/null
EOF

chmod 644 "$CRON_FILE"
systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null || true

echo "✅ Auto-Clean Cronjob Installed (Runs every 4 hours)!"
echo "This will help prevent speed degradation over time by refreshing the cache and stalled VPN services."
