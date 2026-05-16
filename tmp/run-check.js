const fs = require('fs');
const content = fs.readFileSync('public/unida-installer.sh', 'utf-8');
const lines = content.split('\n');
const script = lines.slice(380, 628).join('\n');
fs.writeFileSync('/tmp/temp.sh', script);
try {
  require('child_process').execSync('bash -n /tmp/temp.sh', {stdio:'inherit'});
  console.log('No syntax error');
} catch(e) {
  console.log('Syntax error');
}
