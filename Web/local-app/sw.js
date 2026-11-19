// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
const CACHE='endgame-local-v1.1.0-build7-dragon-3';
const BASE=new URL('./',self.location).pathname;
const FILES=['','index.html','style.css','app.mjs','engine.mjs','native-programs.mjs','exercise_library.json','dragon-dark.webp','dragon-light.webp','dragon-checkered.webp','dragon-192.png','dragon-512.png','manifest.webmanifest'];
self.addEventListener('install',e=>e.waitUntil(caches.open(CACHE).then(c=>c.addAll(FILES.map(f=>BASE+f)))));
self.addEventListener('activate',e=>e.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k.startsWith('endgame-local-')&&k!==CACHE).map(k=>caches.delete(k)))).then(()=>self.clients.claim())));
self.addEventListener('fetch',e=>{if(e.request.method!=='GET'||new URL(e.request.url).origin!==self.location.origin||!new URL(e.request.url).pathname.startsWith(BASE))return;e.respondWith(fetch(e.request).then(r=>{if(r.ok){const copy=r.clone();caches.open(CACHE).then(c=>c.put(e.request,copy));}return r;}).catch(()=>caches.match(e.request).then(r=>r||(e.request.mode==='navigate'?caches.match(BASE+'index.html'):Response.error()))));});
