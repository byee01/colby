// Renders a captured command log as a terminal-style PNG.
// Usage: node tools/term-shot.mjs <title> <log file> <out.png> [width]
import { chromium } from '/opt/node-tools/node_modules/playwright/index.mjs';
import fs from 'node:fs';
const [title, log, out, width = '1100'] = process.argv.slice(2);
const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;');
const body = esc(fs.readFileSync(log, 'utf8').replace(/\x1b\[[0-9;]*m/g, ''))
  .replace(/^(.*(✔|Passed!|passed|PASS).*)$/gm, '<span class="ok">$1</span>')
  .replace(/^(.*(✘|Failed:\s+[1-9]|error:|FAIL).*)$/gm, '<span class="bad">$1</span>');
const html = `<!doctype html><meta charset="utf-8"><style>
body{margin:0;background:#0d1117;color:#c9d1d9;font:13px/1.45 ui-monospace,Menlo,Consolas,monospace}
header{background:#161b22;padding:8px 14px;color:#8b949e;border-bottom:1px solid #30363d}
pre{margin:0;padding:12px 14px;white-space:pre-wrap;word-break:break-all}
.ok{color:#3fb950}.bad{color:#f85149}</style>
<header>$ ${esc(title)}</header><pre>${body}</pre>`;
const b = await chromium.launch();
const p = await b.newPage({ viewport: { width: +width, height: 200 } });
await p.setContent(html);
await p.screenshot({ path: out, fullPage: true });
await b.close();
