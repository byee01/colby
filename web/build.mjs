// Production build for static hosting (GitHub Pages). The source runs as is without this; the build only makes the
// deployed site faster: one minified JS bundle instead of 25 modules fetched five levels deep, minified CSS, content-
// hashed file names, preloaded fonts, and a service worker that precaches exactly the deployed files.
//
//   npm run build        → dist/
//   npm run preview      → serves dist/ on http://localhost:8080
import { build } from 'esbuild';
import { createHash } from 'node:crypto';
import { cpSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { gzipSync } from 'node:zlib';
import { join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('.', import.meta.url));
const out = join(root, 'dist');
rmSync(out, { recursive: true, force: true });
mkdirSync(out);

const result = await build({
  absWorkingDir: root,
  entryPoints: { app: 'src/ui/main.js', style: 'app.css' },
  bundle: true,
  minify: true,
  format: 'esm',
  // Web Bluetooth needs Chrome/Edge 56+; top-level await (main.js) needs 89+.
  target: ['chrome100', 'edge100', 'firefox100', 'safari15'],
  outdir: join(out, 'assets'),
  entryNames: '[name]-[hash]',
  assetNames: '[name]-[hash]',
  loader: { '.woff2': 'file', '.svg': 'file' },
  sourcemap: 'linked',
  metafile: true,
  legalComments: 'none',
  logLevel: 'warning',
});

const outputs = Object.keys(result.metafile.outputs).map((p) => relative(out, join(root, p)));
const js = outputs.find((p) => /^assets\/app-.*\.js$/.test(p));
const css = outputs.find((p) => /^assets\/style-.*\.css$/.test(p));
const fonts = outputs.filter((p) => p.endsWith('.woff2'));
// Fonts on the first screen: body text and the big condensed numbers.
const preload = fonts.filter((p) => /barlow-latin-400|barlow-condensed-latin-500/.test(p));

for (const f of ['icon.svg', 'manifest.webmanifest']) cpSync(join(root, f), join(out, f));
cpSync(join(root, 'fonts/OFL.txt'), join(out, 'assets/OFL.txt'));

let html = readFileSync(join(root, 'index.html'), 'utf8');
html = html
  .replace('<link rel="stylesheet" href="app.css">', [
    ...preload.map((f) => `<link rel="preload" href="${f}" as="font" type="font/woff2" crossorigin>`),
    `<link rel="stylesheet" href="${css}">`,
  ].join('\n  '))
  .replace('<script type="module" src="src/ui/main.js"></script>', `<script type="module" src="${js}"></script>`);
if (!html.includes(js) || !html.includes(css)) throw new Error('index.html: script or stylesheet tag not found');
writeFileSync(join(out, 'index.html'), html);

// Service worker: the real file list and a cache name that changes with the content.
const precache = ['./', 'index.html', 'icon.svg', 'manifest.webmanifest', js, css, ...fonts];
const version = createHash('sha256').update(precache.join('\n')).update(html).digest('hex').slice(0, 10);
const sw = readFileSync(join(root, 'sw.js'), 'utf8').replace(
  /\/\/ @precache-start[\s\S]*?\/\/ @precache-end/,
  `const CACHE = 'colby-${version}';\nconst FILES = ${JSON.stringify(precache)};`,
);
if (!sw.includes(`colby-${version}`)) throw new Error('sw.js: precache markers not found');
writeFileSync(join(out, 'sw.js'), sw);

// Report what a first visit downloads.
const files = (dir) => readdirSync(dir).flatMap((f) => (statSync(join(dir, f)).isDirectory() ? files(join(dir, f)) : [join(dir, f)]));
let total = 0;
for (const f of files(out).filter((f) => !f.endsWith('.map') && !f.endsWith('.txt'))) {
  const gz = gzipSync(readFileSync(f), { level: 9 }).length;
  total += gz;
  console.log(`${relative(out, f).padEnd(48)} ${(gz / 1024).toFixed(1).padStart(6)} KB gz`);
}
console.log(`${'total'.padEnd(48)} ${(total / 1024).toFixed(1).padStart(6)} KB gz → dist/`);
