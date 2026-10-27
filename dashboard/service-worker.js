// Service worker de l'app installable (PWA). v2 (2026-10-07).
//
// REGLE A NE PAS CHANGER : reseau-d'abord, cache en secours UNIQUEMENT.
// Ce projet a deja eu un vrai incident de JS perime servi par un cache
// navigateur apres deploiement (voir le commentaire dans server.py,
// _send_file, 2026-09-24) — un service worker en cache-d'abord sur
// app.js/index.html reproduirait exactement ce bug, en pire (le cache
// serait alors sous le controle du SW, pas juste du navigateur). Le
// cache ne sert donc QUE de secours hors-ligne, jamais de premier choix
// quand le reseau repond.
//
// Ce que ce service worker fait :
//  1. Navigation (ouverture / rechargement d'une page) : reseau d'abord ;
//     si le reseau est coupe, ou si le serveur repond 502/503/504 (redeploiement),
//     il affiche la page de secours /offline.html (FR/EN, se recharge toute seule).
//     Il ne ressert JAMAIS une ancienne page de l'application hors-ligne : un tableau
//     de bord sans reseau ne peut rien faire, mieux vaut le dire clairement.
//  2. Fichiers statiques publics (css, js, images) : reseau d'abord, copie de secours
//     seulement si le reseau echoue.
//  3. Tout le reste passe sans etre touche (pas de respondWith) : /api/, /oauth/,
//     /webhooks/, toute requete qui n'est pas un simple GET, toute requete avec
//     en-tete Authorization ou Range, et les videos.
//
// Donnees personnelles : seule une liste blanche de fichiers statiques peut entrer
// dans le cache, et seulement une reponse 200 de meme origine sans "no-store" ni
// "private". Les reponses de l'API (comptes, missions, facturation) ne passent
// jamais par ici : rien d'authentifie n'est conserve hors-ligne.
const CACHE_NAME = "bk-shell-v3";
const CACHE_PREFIX = "bk-shell-";
const OFFLINE_URL = "/offline.html";

// Indispensable : si la page de secours ne peut pas etre mise en cache, l'installation
// echoue (l'ancien service worker reste en place) plutot que d'installer un SW sans secours.
const PRECACHE_REQUIRED = [OFFLINE_URL];
// Ce dont la page de secours a besoin pour s'afficher (icone, traduction EN) ; au mieux.
const PRECACHE_OPTIONAL = [
  "/i18n.js",
  "/i18n-en-pwa.js",
  "/icons/icon-192.png",
  "/icons/icon-512.png",
  "/manifest.json",
];

// Jamais intercepte : donnees dynamiques/personnelles, retours OAuth, webhooks,
// preuves de propriete des stores, flux video (Range).
const NEVER_INTERCEPT_PREFIXES = ["/api/", "/oauth/", "/webhooks/", "/.well-known/", "/videos/"];
// Liste blanche des fichiers qui peuvent etre gardes en copie de secours.
const STATIC_FILE_RE = /\.(?:css|js|png|jpe?g|svg|webp|ico|woff2?)$|^\/manifest\.json$/i;
// Le service worker lui-meme n'est jamais mis en cache par lui-meme.
const NEVER_CACHE_PATHS = ["/service-worker.js"];
const MAX_RUNTIME_ENTRIES = 80;

self.addEventListener("install", (event) => {
  event.waitUntil(
    (async () => {
      const cache = await caches.open(CACHE_NAME);
      // cache: "reload" = jamais depuis le cache HTTP du navigateur (pas de fichier perime).
      await Promise.all(PRECACHE_REQUIRED.map((u) => cache.add(new Request(u, { cache: "reload" }))));
      await Promise.allSettled(PRECACHE_OPTIONAL.map((u) => cache.add(new Request(u, { cache: "reload" }))));
    })()
  );
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((names) =>
        Promise.all(
          names.filter((n) => n.startsWith(CACHE_PREFIX) && n !== CACHE_NAME).map((n) => caches.delete(n))
        )
      )
  );
  self.clients.claim();
});

function isNeverIntercepted(url) {
  return NEVER_INTERCEPT_PREFIXES.some((p) => url.pathname.startsWith(p));
}

function isCacheableRequest(request, url) {
  return (
    request.method === "GET" &&
    url.origin === self.location.origin &&
    !isNeverIntercepted(url) &&
    !NEVER_CACHE_PATHS.includes(url.pathname) &&
    !request.headers.has("Authorization") &&
    !request.headers.has("Range") &&
    STATIC_FILE_RE.test(url.pathname)
  );
}

function isCacheableResponse(response) {
  if (!response || response.status !== 200) return false;
  if (response.type !== "basic" && response.type !== "default") return false;
  const cacheControl = (response.headers.get("Cache-Control") || "").toLowerCase();
  if (cacheControl.includes("no-store") || cacheControl.includes("private")) return false;
  if (response.headers.get("Vary") === "*") return false;
  return true;
}

// Garde au plus MAX_RUNTIME_ENTRIES copies de secours (les plus anciennes partent
// d'abord) ; les fichiers du precache ne sont jamais supprimes ici.
async function trimCache(cache) {
  const precached = new Set(PRECACHE_REQUIRED.concat(PRECACHE_OPTIONAL));
  const runtime = (await cache.keys()).filter((k) => !precached.has(new URL(k.url).pathname));
  for (let i = 0; i < runtime.length - MAX_RUNTIME_ENTRIES; i++) {
    await cache.delete(runtime[i]);
  }
}

const FALLBACK_HTML =
  '<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">' +
  "<title>BK-AI-WORKERS</title>" +
  '<body style="font-family:system-ui,sans-serif;background:#f7f6f3;color:#16171c;text-align:center;padding:48px 20px">' +
  "<h1>Hors connexion / Offline</h1>" +
  "<p>Reconnectez-vous puis rechargez la page. / Reconnect, then reload the page.</p>" +
  '<p><a href="/">BK-AI-WORKERS</a></p></body>';

async function offlineResponse(status) {
  try {
    const cache = await caches.open(CACHE_NAME);
    const cached = await cache.match(OFFLINE_URL);
    if (cached) {
      const body = await cached.arrayBuffer();
      return new Response(body, {
        status,
        headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" },
      });
    }
  } catch (e) {
    /* cache indisponible : page minimale ci-dessous */
  }
  return new Response(FALLBACK_HTML, {
    status,
    headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" },
  });
}

async function handleNavigation(request) {
  try {
    const response = await fetch(request);
    if (response.status === 502 || response.status === 503 || response.status === 504) {
      return offlineResponse(503);
    }
    return response;
  } catch (e) {
    return offlineResponse(200);
  }
}

async function handleStatic(request) {
  try {
    const response = await fetch(request);
    if (isCacheableResponse(response)) {
      const copy = response.clone();
      caches
        .open(CACHE_NAME)
        .then((cache) => cache.put(request, copy).then(() => trimCache(cache)))
        .catch(() => {});
    }
    return response;
  } catch (e) {
    const cached = await caches.match(request);
    return cached || Response.error();
  }
}

self.addEventListener("fetch", (event) => {
  const request = event.request;
  const url = new URL(request.url);

  if (request.method !== "GET" || url.origin !== self.location.origin || isNeverIntercepted(url)) {
    return;
  }
  if (request.headers.has("Authorization") || request.headers.has("Range")) {
    return;
  }
  if (request.mode === "navigate") {
    event.respondWith(handleNavigation(request));
    return;
  }
  if (isCacheableRequest(request, url)) {
    event.respondWith(handleStatic(request));
  }
});
