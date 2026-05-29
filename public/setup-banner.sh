#!/bin/bash
# Setup SSH Banner (Visible in HTTP Custom and other VPN apps)

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo)"
  exit 1
fi

BANNER_FILE="/etc/issue.net"

# Create HTML colored banner for VPN apps (HTTP Custom supports HTML)
cat > "$BANNER_FILE" << 'EOF'
<br>
<div style="text-align:center">
  <font color="#00FFFF"><b>🚀 UNIDA 🚀</b></font><br>
  <font color="#FFFFFF">by</font><br>
  <font color="#FF0000"><b>Sixbravo</b></font> <font color="#FFFFFF">&amp;</font> <font color="#FFFF00"><b>BunyaBoy</b></font>
</div>
<br>
EOF

# Update sshd_config to use the banner
sed -i 's/^#Banner.*/Banner \/etc\/issue.net/g' /etc/ssh/sshd_config
if ! grep -q "^Banner /etc/issue.net" /etc/ssh/sshd_config; then
    echo "Banner /etc/issue.net" >> /etc/ssh/sshd_config
fi

# Restart SSH service
systemctl restart sshd >/dev/null 2>&1 || systemctl restart ssh >/dev/null 2>&1

echo "✅ Colored SSH banner installed successfully!"
echo "It will display in HTTP Custom when connecting."
