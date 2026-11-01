// Offline support. Hashed build assets (assets/*) never change, so they are served from the cache first; everything
// else is network first (a new deploy is picked up at once) with the cache as the fallback.
// The build (build.mjs) replaces the block between the markers with the real file list and a content-hashed cache name.
// @precache-start
const CACHE = 'colby-dev';
const FILES = [
  './', 'index.html', 'app.css', 'icon.svg', 'manifest.webmanifest',
  'fonts/barlow-latin-400-normal.woff2', 'fonts/barlow-latin-500-normal.woff2', 'fonts/barlow-latin-600-normal.woff2',
  'fonts/barlow-latin-700-normal.woff2', 'fonts/barlow-condensed-latin-500-normal.woff2',
  'fonts/barlow-condensed-latin-600-normal.woff2',
];
// @precache-end

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
  if (url.pathname.includes('/assets/')) {
    e.respondWith(caches.match(e.request).then((hit) => hit ?? fetch(e.request)));
    return;
  }
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

// Acknowledge and Snooze act in the page without bringing it forward; a click on the notification itself opens Colby.
self.addEventListener('notificationclick', (e) => {
  const id = e.notification.data?.id;
  const action = e.action || 'open';
  e.notification.close();
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((list) => {
    if (id) for (const c of list) c.postMessage({ type: 'colby-alert', action, id });
    if (action !== 'open') return undefined;
    return list[0] ? list[0].focus() : self.clients.openWindow('./');
  }));
});
