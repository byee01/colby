import { chromium } from '/opt/node-tools/node_modules/playwright/index.mjs';
import http from 'node:http'; import fs from 'node:fs'; import path from 'node:path';
const [root, out, ...specs] = process.argv.slice(2);
const PORT = 8767;
const srv = http.createServer((q, r) => { const f = path.join(root, decodeURIComponent(q.url.split('?')[0])); if (!fs.existsSync(f)) { r.writeHead(404); return r.end(); } r.writeHead(200, {'content-type': f.endsWith('.js') ? 'text/javascript' : 'text/html'}); fs.createReadStream(f).pipe(r); }).listen(PORT);
const b = await chromium.launch();
for (const s of specs) { const [n, w, h, mode] = s.split(':'); const p = await b.newPage({ viewport: { width: +w, height: +h } }); const errs = []; p.on('pageerror', e => errs.push(e.message.slice(0,150))); await p.goto(`http://127.0.0.1:${PORT}/${n}.dc.html`, { waitUntil: 'networkidle' }); await p.waitForTimeout(2500); if (mode === 'hover') { const ph = await p.evaluate(() => document.documentElement.scrollHeight); await p.setViewportSize({ width: +w, height: ph }); await p.waitForTimeout(300); const r = await p.locator('svg rect[fill="transparent"]').first().boundingBox(); await p.mouse.move(r.x + r.width * 0.42, r.y + r.height / 2); await p.waitForTimeout(400); } await p.screenshot({ path: `${out}/${n}${mode ? '-' + mode : ''}.png`, fullPage: true }); console.log(n, errs.join(' | ') || 'ok'); await p.close(); }
await b.close(); srv.close();
