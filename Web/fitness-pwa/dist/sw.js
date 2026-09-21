/* Endgame Fitness service worker — app-shell caching, network-first for API.
   Scope is /fitness/ so the rest of batesai.org is untouched. The cache name
   is stamped with the build time by vite.config.ts, so every deploy installs
   a fresh worker and no one is stranded on a stale shell. */
const CACHE = 'endgame-fitness-1789965320707';
const SHELL = ['/fitness/', '/fitness/index.html', '/fitness/manifest.webmanifest'];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE).then((cache) => cache.addAll(SHELL)).then(() => self.skipWaiting()),
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))).then(() => self.clients.claim()),
  );
});

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);
  if (event.request.method !== 'GET') return;
  // API + auth: always network, never cache (stale XP is worse than slow XP).
  if (url.pathname.startsWith('/api/')) return;
  // App shell + hashed assets: cache-first, refresh in background.
  event.respondWith(
    caches.match(event.request).then((cached) => {
      const network = fetch(event.request).then((res) => {
        if (res.ok && url.origin === self.location.origin) {
          const copy = res.clone();
          caches.open(CACHE).then((cache) => cache.put(event.request, copy));
        }
        return res;
      }).catch(() => cached);
      return cached || network;
    }),
  );
});
