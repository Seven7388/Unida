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
        echo "  8) Change Backend Target (SOCKS5/SSH/VLESS)"
        echo "  9) Change MTU Size"
        echo " 10) Uninstall Unida Server"
        echo "  0) Exit"
        echo "==============================================="
        read -rp "Select an option [0-10]: " choice
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
            10) uninstall_unida ;;
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