import fs from 'fs';
let text = fs.readFileSync('public/dnsgb-setup.sh', 'utf-8');

text = text.replace(/step_install_dnstm/g, 'step_install_dnsgb');
text = text.replace(/dnstm/ig, (m) => m === 'dnstm' ? 'dnsgb' : 'DNSGB');

fs.writeFileSync('public/dnsgb-setup.sh', text);
