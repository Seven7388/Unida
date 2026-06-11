import fs from 'fs';
let text = fs.readFileSync('public/dnsgb-setup.sh', 'utf-8');

const t = 'new_exec=$(echo "$exec_line" | sed -E "s/(-udp\\\\s+:[0-9]+)/\\\\1 -mtu ${new_mtu}/")\\n        fi';

if (text.indexOf('new_exec=$(echo "$exec_line" | sed -E "s/(-udp\\s+:[0-9]+)/\\1 -mtu ${new_mtu}/")\n        fi') !== -1) {
    const srch = 'new_exec=$(echo "$exec_line" | sed -E "s/(-udp\\s+:[0-9]+)/\\1 -mtu ${new_mtu}/")\n        fi';
    const repl = 'new_exec=$(echo "$exec_line" | sed -E "s/(-udp\\\\s+:[0-9]+)/\\\\1 -mtu ${new_mtu}/")\n' +
                 '        fi\n' +
                 '        new_exec=$(echo "$new_exec" | sed -E "s/ 1800 [0-9]+/ 1800 ${new_mtu}/")';
                 
    text = text.replace(srch, repl);
    
    // Also remove the old bad patch
    text = text.replace(/        if \[ -f \/usr\/local\/bin\/dnsgb-edns-proxy\.py \]; then\n            print_info "Updating internal EDNS size in proxy\.\.\."\n            sed -i "s\/INTERNAL_EDNS_SIZE=\[0-9\]\\\+\/INTERNAL_EDNS_SIZE=\$\{new_mtu\}\/g" \/usr\/local\/bin\/dnsgb-edns-proxy\.py\n        fi\n\n/g, '');


    fs.writeFileSync('public/dnsgb-setup.sh', text);
    console.log("Patched successfully.");
} else {
    console.log("Not found.");
}
