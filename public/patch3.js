import fs from 'fs';
let text = fs.readFileSync('public/dnsgb-setup.sh', 'utf-8');

// protect urls
let urls = [];
text = text.replace(/https?:\/\/[^\s"'<>]+/g, (m) => {
    urls.push(m);
    return `___URL_${urls.length-1}___`;
});

text = text.replace(/dnstm/g, 'dnsgb');
text = text.replace(/DNSTM/g, 'DNSGB');

// put urls back
for (let i = 0; i < urls.length; i++) {
    text = text.replace(`___URL_${i}___`, urls[i]);
}

fs.writeFileSync('public/dnsgb-setup.sh', text);
