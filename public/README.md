# Unida DNSTT Server

A robust, automated installer for setting up a DNSTT (SlowDNS) tunnel server on Linux, complete with a built-in EDNS proxy and a powerful CLI manager (`unida`).

## Features

- **Instant Setup:** Downloads the core DNSTT server binary, creates systemd background services, and generates keys automatically.
- **Advanced Networking:** Automatically configures IPv4 forwarding (`ip_forward`), `iptables` NAT Masquerading, and SSH port forwarding (`AllowTcpForwarding`, `GatewayPorts`) so that clients instantly have internet access without extra manual configuration.
- **Port Collision Prevention:** Automatically stops conflicting services (like `bind9`, `dnsmasq`) and proactively kills any zombie processes blocking required ports (`53`, `5300`, `7300`) ensuring a clean setup.
- **Smart Port Routing:** If you choose to run the EDNS proxy on a custom port, `iptables` rules will automatically route default port 53 traffic incoming from apps like HTTP Injector directly to your custom port, guaranteeing client compatibility.
- **BadVPN UDPGW:** Compiles and runs a dedicated UDP over TCP Gateway for handling VoIP calls (WhatsApp) and online gaming across the DNS tunnel seamlessly (runs on port 7300).
- **EDNS Proxy:** Includes an intelligent Python-based EDNS UDP size proxy (`512` <-> `1800`) to ensure DNS requests pass through strict firewalls and routers smoothly.
- **Single-File Installer:** The installer script seamlessly embeds the management terminal tool, meaning you only need one script to install everything perfectly.
- **Management CLI:** A global `unida` command is installed on your server to easily manage your SSH users, tunnel status, and logs.

---

## Prerequisites

- A fresh Linux VPS (Ubuntu/Debian recommended).
- Root access (run via `sudo` or as completely logged in as `root`).
- A custom domain with NS records properly pointed to your VPS IP address.

---

## 🚀 Installation

To install the server directly on your VPS, run the following automated command:

```bash
wget -qO unida.sh https://raw.githubusercontent.com/Seven7388/Unida/main/public/unida-installer.sh && sudo bash unida.sh
```

### DNS Configuration Options During Setup

The script will ask you how you want to configure your DNS records for the VPN:

1. **Automatic Setup (Cloudflare API)** 
   If your domain is managed by Cloudflare, simply provide your API Token and Base Domain. The script will automatically generate unique prefixes, securely connect to Cloudflare, and create the required `A` and `NS` records instantly.
   
2. **Manual Setup**
   If you use another registrar or prefer to do it yourself, the script will pause and provide you with exact instructions on what records to create (an `A` record pointing to your server's IP, and an `NS` record pointing to that `A` record).

---

## 🛠️ Management CLI (`unida`)

The installer automatically configures the `unida` command on your server. **You do not need a separate script to access it!** Just type `unida` in your server console after installation.

### Available Options:

When you run `unida`, an interactive menu will appear with the following options:

1. **Create new SSH User**: Interactively create a new user and password for your SSH tunnel.
2. **Delete SSH User**: Remove an existing user from the system.
3. **List all SSH Users**: View a list of all currently configured SSH tunnel users.
4. **Show DNSTT Tunnel Status**: Check if the main tunnel, proxy, and BadVPN UDPGW are actively running.
5. **View Live Logs**: View the live traffic/error logs for the DNSTT server, EDNS proxy, or BadVPN UDPGW.
6. **Restart DNSTT Services**: Instantly restart all background tunnel services.
7. **Show Server Public Key**: Display the Server's Public Key (needed for your VPN client apps).
8. **Change MTU Size**: Dynamically update the MTU size for both the tunnel and the proxy, and auto-restart services seamlessly.
9. **Uninstall Unida Server**: Completely remove Unida DNSTT, the proxy, BadVPN, and all configurations from your server.
0. **Exit**: Close the manager.

---

### Technical Notes on the CLI Manager Structure
If you are viewing the repository and wondering where the manager script is located: **it is embedded directly inside the installer script**. 

When you run `unida-installer.sh`, it uses a Linux "Here-Doc" to extract the `unida` command-line tool and places it directly into `/usr/local/bin/unida` on your VPS, automatically setting its permissions and allowing you to access it from anywhere globally. This keeps installation to a clean, single-command process!
