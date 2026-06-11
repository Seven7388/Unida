import fs from 'fs';
let text = fs.readFileSync('public/dnsgb-setup.sh', 'utf-8');

const changeMtuInject = "    if [[ $changed -gt 0 ]]; then\n        systemctl daemon-reload\n        echo \"\"\n        print_info \"Restarting DNSTT tunnels...\"\n";

const newValue = "    if [[ $changed -gt 0 ]]; then\n        if [ -f /usr/local/bin/dnsgb-edns-proxy.py ]; then\n            print_info \"Updating internal EDNS size in proxy...\"\n            sed -i \"s/INTERNAL_EDNS_SIZE=[0-9]\\\\+/INTERNAL_EDNS_SIZE=${new_mtu}/g\" /usr/local/bin/dnsgb-edns-proxy.py\n        fi\n\n        systemctl daemon-reload\n        echo \"\"\n        print_info \"Restarting DNSTT tunnels...\"\n";

if (text.includes(changeMtuInject)) {
    text = text.replace(changeMtuInject, newValue);
    fs.writeFileSync('public/dnsgb-setup.sh', text);
    console.log("Patched do_change_mtu successfully.");
} else {
    console.log("Could not find injection point.");
}
