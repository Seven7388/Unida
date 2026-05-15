import React, { useEffect, useState } from 'react';
import { Check, Clipboard, Download, TerminalSquare, Github, FileText, Code } from 'lucide-react';

export default function App() {
  const [scriptContent, setScriptContent] = useState<string>('');
  const [readmeContent, setReadmeContent] = useState<string>('');
  const [copied, setCopied] = useState<{ [key: string]: boolean }>({});
  const [activeTab, setActiveTab] = useState<'readme' | 'script'>('readme');
  
  useEffect(() => {
    fetch('/unida-installer.sh')
      .then((res) => res.text())
      .then((text) => setScriptContent(text))
      .catch((err) => console.error("Could not fetch the script", err));

    fetch('/README.md')
      .then((res) => res.text())
      .then((text) => setReadmeContent(text))
      .catch((err) => console.error("Could not fetch the readme", err));
  }, []);

  const copyToClipboard = (text: string, id: string) => {
    navigator.clipboard.writeText(text);
    setCopied({ ...copied, id: true });
    setTimeout(() => {
      setCopied({ ...copied, id: false });
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
            <h1 className="text-3xl font-bold text-white tracking-tight">Unida DNSTT Repository Files</h1>
          </div>
          <p className="text-neutral-400 text-lg max-w-2xl leading-relaxed">
            Your repository files are ready! We've added a comprehensive <code className="text-indigo-300">README.md</code> that explains the installation process and how the <code className="text-indigo-300">unida</code> manager command works.
          </p>
        </header>

        {/* Github Files Section */}
        <section className="bg-neutral-900 border border-neutral-800 rounded-2xl overflow-hidden flex flex-col shadow-xl">
          <div className="p-4 sm:p-6 border-b border-neutral-800 flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4 bg-neutral-950/50">
            <div className="space-y-1">
              <h2 className="text-xl font-semibold flex items-center gap-2 text-white">
                <Github size={20} className="text-white" /> GitHub Repository Source
              </h2>
              <p className="text-neutral-400 text-sm">Download or copy these two files to your GitHub repository.</p>
            </div>
            
            {/* Tabs */}
            <div className="flex bg-neutral-800 p-1 rounded-lg">
              <button 
                onClick={() => setActiveTab('readme')}
                className={`flex items-center gap-2 px-4 py-2 rounded-md transition-colors text-sm font-medium ${activeTab === 'readme' ? 'bg-indigo-600 text-white shadow' : 'text-neutral-400 hover:text-white'}`}
              >
                <FileText size={16} /> README.md
              </button>
              <button 
                onClick={() => setActiveTab('script')}
                className={`flex items-center gap-2 px-4 py-2 rounded-md transition-colors text-sm font-medium ${activeTab === 'script' ? 'bg-indigo-600 text-white shadow' : 'text-neutral-400 hover:text-white'}`}
              >
                <Code size={16} /> unida-installer.sh
              </button>
            </div>
          </div>

          {/* Active Tab Content Header */}
          <div className="px-6 py-4 bg-neutral-800/50 flex flex-col sm:flex-row gap-4 justify-between sm:items-center border-b border-neutral-800">
             <span className="font-mono text-sm text-indigo-300">
               {activeTab === 'readme' ? '📄 README.md' : '🐚 unida-installer.sh'}
             </span>
             <div className="flex gap-3">
                <button
                  onClick={() => copyToClipboard(activeTab === 'readme' ? readmeContent : scriptContent, activeTab)}
                  className="flex items-center justify-center gap-2 px-4 py-2 bg-neutral-800 hover:bg-neutral-700 text-white rounded-lg transition-colors font-medium text-xs shadow-sm w-full sm:w-auto"
                >
                  {copied[activeTab] ? <Check size={14} className="text-green-400" /> : <Clipboard size={14} />}
                  {copied[activeTab] ? "Copied!" : "Copy Full Text"}
                </button>
                <button
                  onClick={() => downloadFile(activeTab === 'readme' ? readmeContent : scriptContent, activeTab === 'readme' ? 'README.md' : 'unida-installer.sh')}
                  className="flex items-center justify-center gap-2 px-4 py-2 bg-indigo-600 hover:bg-indigo-500 text-white rounded-lg transition-colors font-medium text-xs shadow-sm w-full sm:w-auto"
                >
                  <Download size={14} /> Download File
                </button>
              </div>
          </div>

          {/* Code Previewer */}
          <div className="bg-black p-4 sm:p-6 overflow-x-auto max-h-[600px] overflow-y-auto">
            <pre className="text-neutral-300 font-mono text-sm leading-relaxed whitespace-pre-wrap">
              <code>{activeTab === 'readme' ? (readmeContent || 'Loading...') : (scriptContent || 'Loading...')}</code>
            </pre>
          </div>
        </section>
      </div>
    </div>
  );
}
