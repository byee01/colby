// Offline support: network first (so a new deploy is picked up at once), cache as the fallback.
const CACHE = 'colby-v1';
const FILES = [
  './', 'index.html', 'app.css', 'icon.svg', 'manifest.webmanifest',
  'src/ui/main.js', 'src/ui/graph.js', 'src/ui/format.js', 'src/ui/platform.js',
  'src/core/app.js', 'src/core/support.js', 'src/core/probeStore.js', 'src/core/presenter.js', 'src/core/uartClient.js',
  'src/core/links.js', 'src/core/commands.js', 'src/core/alerts.js', 'src/core/history.js', 'src/core/storage.js',
  'src/transport/gatt.js', 'src/transport/webBluetooth.js', 'src/transport/simulated.js',
  'src/codec/index.js', 'src/codec/bytes.js', 'src/codec/fields.js', 'src/codec/advertisement.js', 'src/codec/status.js',
  'src/codec/uart.js',
  'fonts/barlow-latin-400-normal.woff2', 'fonts/barlow-latin-500-normal.woff2', 'fonts/barlow-latin-600-normal.woff2',
  'fonts/barlow-latin-700-normal.woff2', 'fonts/barlow-condensed-latin-500-normal.woff2',
  'fonts/barlow-condensed-latin-600-normal.woff2',
];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(FILES)));
  self.skipWaiting();
});

self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys()
    .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
    .then(() => self.clients.claim()));
});

self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);
  if (e.request.method !== 'GET' || url.origin !== self.location.origin) return;
  e.respondWith(fetch(e.request)
    .then((response) => {
      if (response.ok) {
        const copy = response.clone();
        caches.open(CACHE).then((c) => c.put(e.request, copy));
      }
      return response;
    })
    .catch(() => caches.match(e.request, { ignoreSearch: true })));
});

self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  e.waitUntil(self.clients.matchAll({ type: 'window' }).then((list) => (list[0] ? list[0].focus() : self.clients.openWindow('./'))));
});
