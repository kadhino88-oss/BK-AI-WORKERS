// PWA app shell (2026-09-30). Reseau-d'abord, cache en secours UNIQUEMENT :
// ce projet a deja eu un vrai incident de JS perime servi par un cache
// navigateur apres deploiement (voir le commentaire dans server.py,
// _send_file, 2026-09-24) — un service worker en cache-d'abord sur
// app.js/index.html reproduirait exactement ce bug, en pire (le cache
// serait alors sous le controle du SW, pas juste du navigateur). Le
// cache ne sert donc QUE de secours hors-ligne, jamais de premier choix
// quand le reseau repond.
const CACHE_NAME = "bk-shell-v1";
const SHELL_ASSETS = [
  "/",
  "/style.css",
  "/app.js",
  "/particles.js",
  "/manifest.json",
  "/icons/icon-192.png",
  "/icons/icon-512.png",
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(SHELL_ASSETS)).catch(() => {})
  );
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((names) =>
      Promise.all(names.filter((n) => n !== CACHE_NAME).map((n) => caches.delete(n)))
    )
  );
  self.clients.claim();
});

self.addEventListener("fetch", (event) => {
  const url = new URL(event.request.url);

  // Jamais intercepte : API (donnees dynamiques/personnelles, jamais mises
  // en cache) et tout ce qui n'est pas une simple lecture GET.
  if (url.pathname.startsWith("/api/") || event.request.method !== "GET") {
    return;
  }
  // Meme origine uniquement (jamais les CDN de polices/scripts externes).
  if (url.origin !== self.location.origin) {
    return;
  }

  event.respondWith(
    fetch(event.request)
      .then((response) => {
        if (response && response.ok) {
          const copy = response.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(event.request, copy)).catch(() => {});
        }
        return response;
      })
      .catch(() => caches.match(event.request).then((cached) => cached || Response.error()))
  );
});
