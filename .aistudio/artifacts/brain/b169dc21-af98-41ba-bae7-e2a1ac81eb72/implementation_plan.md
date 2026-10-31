# Implementation Plan: Adding SSL/TLS (HTTPS Obfuscation) to Unida

## Objective
To implement SSL/TLS obfuscation on port 443, allowing the Unida server traffic to mimic standard HTTPS. This will enhance connectivity stability and bypass potential restrictions, mirroring the behavior of tools like V2Ray or DNSTT.

## Implementation Details
1.  **Backend Tool**: We will use `stunnel4` to terminate TLS on port 443 and forward traffic to the existing Protocol Multiplexer on port 2222.
2.  **Automated Setup**:
    *   `unida-installer.sh` will be updated to install `stunnel4` (via `apt-get`).
    *   A `stunnel` configuration file will be created to define the 443 -> 2222 tunnel.
3.  **Management Panel (`unida` CLI)**:
    *   Add a new option to the `unida` menu: "Enable/Disable SSL/TLS (Port 443)".
    *   Add support for generating/renewing self-signed certificates or integrating with Let's Encrypt (via `certbot`) if desired.
4.  **Workflow**:
    *   User runs `unida` -> Select "Enable SSL".
    *   CLI checks if `stunnel` is configured.
    *   If not, runs setup (installs `stunnel`, generates/fetches certs, starts service).
    *   Traffic on 443 is now TLS-wrapped and routed to the Multiplexer.

## User Action Required
1.  Review and approve this plan.
2.  Once approved, run the updated `unida-installer.sh` on the VPS to update the system and the CLI tool.
