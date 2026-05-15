import React, { useEffect, useState } from 'react';
import { Check, Clipboard, Download, TerminalSquare, Settings2, Github } from 'lucide-react';

export default function App() {
  const [scriptContent, setScriptContent] = useState<string>('');
  const [copied, setCopied] = useState<{ [key: string]: boolean }>({});
  
  const appUrl = import.meta.env.VITE_APP_URL || window.location.origin;

  useEffect(() => {
    fetch('/unida-installer.sh')
      .then((res) => res.text())
      .then((text) => setScriptContent(text))
      .catch((err) => console.error("Could not fetch the script", err));
  }, []);

  const copyToClipboard = (text: string, id: string) => {
    navigator.clipboard.writeText(text);
    setCopied({ ...copied, [id]: true });
    setTimeout(() => {
      setCopied({ ...copied, [id]: false });
    }, 2000);
  };

  const downloadFile = (content: string, filename: string) => {
    const element = document.createElement("a");
    const file = new Blob([content], { type: 'text/plain' });
    element.href = URL.createObjectURL(file);
    element.download = filename;
    document.body.appendChild(element);
    element.click();
    document.body.removeChild(element);
  };

  return (
    <div className="min-h-screen bg-neutral-950 text-neutral-200 font-sans p-6 sm:p-12">
      <div className="max-w-4xl mx-auto space-y-12">
        {/* Header */}
        <header className="space-y-4">
          <div className="flex items-center space-x-3 text-indigo-400">
            <TerminalSquare size={32} />
            <h1 className="text-3xl font-bold text-white tracking-tight">Unida DNSTT Manager</h1>
          </div>
          <p className="text-neutral-400 text-lg max-w-2xl leading-relaxed">
            Your installer script has been fixed, fully optimized, and wrapped into a single executable. 
            It now automatically sets up both the main server and the <code className="text-indigo-300">unida</code> management CLI tool.
          </p>
        </header>

        {/* Section 1: Quick Install on VPS */}
        <section className="bg-neutral-900 border border-neutral-800 rounded-2xl p-6 sm:p-8 space-y-6">
          <div className="space-y-2">
            <h2 className="text-xl font-semibold flex items-center gap-2 text-white">
              <Download size={20} className="text-indigo-400" /> Option 1: Direct VPS Installation
            </h2>
            <p className="text-neutral-400">Run this command on your VPS to download and run the installer immediately.</p>
          </div>
          
          <div className="relative group">
            <div className="absolute inset-y-0 left-0 pl-4 flex items-center pointer-events-none">
              <span className="text-neutral-500 font-mono">$</span>
            </div>
            <code className="block w-full bg-black border border-neutral-800 text-green-400 rounded-lg py-4 pl-10 pr-16 font-mono text-sm overflow-x-auto whitespace-nowrap">
              wget -qO unida-installer.sh {appUrl}/unida-installer.sh && sudo bash unida-installer.sh -d your-domain.com
            </code>
            <button
              onClick={() => copyToClipboard(`wget -qO unida-installer.sh ${appUrl}/unida-installer.sh && sudo bash unida-installer.sh -d your-domain.com`, 'direct')}
              className="absolute right-2 top-1/2 -translate-y-1/2 p-2 bg-neutral-800 hover:bg-neutral-700 text-neutral-300 rounded-md transition-colors"
              title="Copy to clipboard"
            >
              {copied['direct'] ? <Check size={16} className="text-green-400" /> : <Clipboard size={16} />}
            </button>
          </div>
        </section>

        {/* Section 2: Publish to Github */}
        <section className="bg-neutral-900 border border-neutral-800 rounded-2xl overflow-hidden flex flex-col">
          <div className="p-6 sm:p-8 border-b border-neutral-800 flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4">
            <div className="space-y-1">
              <h2 className="text-xl font-semibold flex items-center gap-2 text-white">
                <Github size={20} className="text-white" /> Option 2: Publish to GitHub
              </h2>
              <p className="text-neutral-400">Copy or download the fixed source code.</p>
            </div>
            <div className="flex gap-3">
              <button
                onClick={() => copyToClipboard(scriptContent, 'script')}
                className="flex items-center gap-2 px-4 py-2 bg-neutral-800 hover:bg-neutral-700 text-white rounded-lg transition-colors font-medium text-sm"
              >
                {copied['script'] ? <Check size={16} /> : <Clipboard size={16} />}
                {copied['script'] ? "Copied!" : "Copy Code"}
              </button>
              <button
                onClick={() => downloadFile(scriptContent, 'unida-installer.sh')}
                className="flex items-center gap-2 px-4 py-2 bg-indigo-600 hover:bg-indigo-500 text-white rounded-lg transition-colors shadow-lg shadow-indigo-900/20 font-medium text-sm"
              >
                <Download size={16} /> Download .sh
              </button>
            </div>
          </div>
          <div className="bg-black p-4 sm:p-6 overflow-x-auto max-h-96">
            <pre className="text-neutral-300 font-mono text-sm leading-relaxed">
              <code>{scriptContent || 'Loading script...'}</code>
            </pre>
          </div>
        </section>

        {/* Section 3: Manager CLI Usage */}
        <section className="bg-neutral-900 border border-neutral-800 rounded-2xl p-6 sm:p-8 space-y-6">
          <div className="space-y-2">
            <h2 className="text-xl font-semibold flex items-center gap-2 text-white">
              <Settings2 size={20} className="text-indigo-400" /> How to use the 'unida' CLI
            </h2>
            <p className="text-neutral-400">After running the installer on your server, the <code className="text-indigo-300">unida</code> command becomes globally available.</p>
          </div>

          <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
            {[
              { cmd: "unida useradd testuser password123", desc: "Create a new SSH tunnel user" },
              { cmd: "unida userdel testuser", desc: "Remove an existing SSH user" },
              { cmd: "unida users", desc: "List all created SSH users" },
              { cmd: "unida status", desc: "Check if the tunnel and proxy are active" },
              { cmd: "unida logs proxy", desc: "View live traffic logs for the EDNS proxy" },
              { cmd: "unida restart", desc: "Restart both background services" },
              { cmd: "unida key", desc: "Display the server's public key securely" },
            ].map((item, idx) => (
              <div key={idx} className="bg-black border border-neutral-800 rounded-xl p-4 flex flex-col justify-between">
                <code className="text-green-400 font-mono text-xs sm:text-sm mb-2">{item.cmd}</code>
                <span className="text-neutral-500 text-sm">{item.desc}</span>
              </div>
            ))}
          </div>
        </section>

      </div>
    </div>
  );
}

