const fs = require('fs');
const content = fs.readFileSync('public/unida-installer.sh', 'utf-8');
const lines = content.split('\n');
const script = lines.slice(380, 628).join('\n');
fs.writeFileSync('temp.sh', script);
try {
  require('child_process').execSync('bash -n temp.sh', {stdio:'pipe'});
  console.log('No syntax error');
} catch(e) {
  console.log('Syntax error:\n' + e.message + '\n' + e.stderr.toString());
}
