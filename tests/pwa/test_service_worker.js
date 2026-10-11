/* Test du service worker (dashboard/service-worker.js) sous Node, sans navigateur.
 *
 * Le vrai fichier est charge dans un contexte `vm` avec une fausse API Cache en memoire ;
 * le reseau est soit simule (par defaut), soit le VRAI serveur si BK_TEST_BASE_URL est defini
 * (tests/pwa/e2e_server.py le fait) : le precache va alors chercher les vrais fichiers.
 *
 *   node tests/pwa/test_service_worker.js
 *   BK_TEST_BASE_URL=http://127.0.0.1:PORT node tests/pwa/test_service_worker.js
 *
 * Ce qui est verifie : navigation (reseau d'abord, page de secours hors connexion et sur 502/503/504),
 * /api/ /oauth/ /webhooks/ jamais interceptes, POST/Authorization/Range jamais interceptes,
 * fichiers statiques reseau-d'abord (jamais de version perimee quand le reseau repond), rien
 * d'authentifie ni de "no-store" dans le cache, nettoyage des anciens caches, plafond du cache. */
"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const REPO = path.resolve(__dirname, "..", "..");
const SW_FILE = process.env.BK_SW_FILE || path.join(REPO, "dashboard", "service-worker.js");   // BK_SW_FILE : variante mutee (test des tests)
const SW_SOURCE = fs.readFileSync(SW_FILE, "utf8");
const REAL_BASE = process.env.BK_TEST_BASE_URL ? process.env.BK_TEST_BASE_URL.replace(/\/$/, "") : null;
const ORIGIN = REAL_BASE || "https://bk.test";

let failures = 0;
let total = 0;
function check(name, cond, detail) {
  total++;
  if (cond) console.log("  PASS  " + name);
  else {
    failures++;
    console.log("  FAIL  " + name + (detail !== undefined ? "  [" + detail + "]" : ""));
  }
}

// ---------- fausse API Cache (en memoire) ----------
function urlKey(req) {
  const u = typeof req === "string" ? req : req.url;
  return new URL(u, ORIGIN).href;
}
class FakeCache {
  constructor() { this.map = new Map(); }
  async put(req, res) {
    this.map.set(urlKey(req), { status: res.status, statusText: res.statusText, headers: [...res.headers.entries()], body: Buffer.from(await res.arrayBuffer()) });
  }
  async match(req) {
    const e = this.map.get(urlKey(req));
    return e ? new Response(e.body, { status: e.status, statusText: e.statusText, headers: e.headers }) : undefined;
  }
  async add(req) {
    const res = await fetchImpl(req);
    if (!res.ok) throw new TypeError("add(): statut " + res.status);
    await this.put(req, res);
  }
  async keys() { return [...this.map.keys()].map((url) => ({ url })); }
  async delete(req) { return this.map.delete(urlKey(req)); }
}
class FakeCacheStorage {
  constructor() { this.stores = new Map(); }
  async open(name) { if (!this.stores.has(name)) this.stores.set(name, new FakeCache()); return this.stores.get(name); }
  async keys() { return [...this.stores.keys()]; }
  async delete(name) { return this.stores.delete(name); }
  async match(req) {
    for (const c of this.stores.values()) { const r = await c.match(req); if (r) return r; }
    return undefined;
  }
}

// ---------- reseau : simule ou vrai serveur ----------
let online = true;
let useReal = false;           // vrai serveur seulement dans le dernier bloc ; les scenarios precedents sont simules
let stub = {};                 // chemin -> {status, headers, body}
let networkLog = [];
async function fetchImpl(input) {
  const url = new URL(typeof input === "string" ? input : input.url, ORIGIN);
  networkLog.push(url.pathname);
  if (!online) throw new TypeError("Failed to fetch");
  let res;
  if (useReal) {
    res = await fetch(url.href, { headers: input.headers ? Object.fromEntries(input.headers.entries()) : {} });
  } else {
    const s = stub[url.pathname] || { status: 404, body: "not found" };
    res = new Response(s.body === undefined ? "ok" : s.body, { status: s.status || 200, headers: s.headers || {} });
  }
  try { Object.defineProperty(res, "type", { value: "basic" }); } catch (e) { /* deja basic */ }
  return res;
}

// Dans un navigateur, new Request("/x") se resout par rapport a l'adresse du service worker ; Node n'a pas de base.
class SwRequest extends Request {
  constructor(input, init) { super(typeof input === "string" ? new URL(input, ORIGIN).href : input, init); }
}

// ---------- charge le vrai service worker ----------
function loadSw() {
  const listeners = {};
  const state = { skipped: false, claimed: false };
  const self = {
    location: { origin: ORIGIN },
    addEventListener: (type, fn) => { listeners[type] = fn; },
    skipWaiting: () => { state.skipped = true; },
    clients: { claim: () => { state.claimed = true; } },
  };
  const caches = new FakeCacheStorage();
  const ctx = vm.createContext({ self, caches, fetch: fetchImpl, Request: SwRequest, Response, URL, Headers, Promise, Set, console });
  vm.runInContext(SW_SOURCE, ctx, { filename: "service-worker.js" });
  const consts = (name) => vm.runInContext(name, ctx);
  async function lifecycle(type) {
    let waiting = Promise.resolve();
    await listeners[type]({ waitUntil: (p) => { waiting = p; } });
    await waiting;
  }
  async function dispatchFetch(req) {
    let answer = null;
    const event = { request: req, respondWith: (p) => { answer = p; } };
    listeners.fetch(event);
    return answer === null ? null : await answer;
  }
  return { caches, state, consts, lifecycle, dispatchFetch };
}

function req(pathname, opts = {}) {
  return {
    url: new URL(pathname, opts.origin || ORIGIN).href,
    method: opts.method || "GET",
    mode: opts.mode || "cors",
    headers: new Headers(opts.headers || {}),
  };
}
const nav = (p) => req(p, { mode: "navigate" });

async function cachedPaths(sw) {
  const out = [];
  for (const name of await sw.caches.keys()) for (const k of await (await sw.caches.open(name)).keys()) out.push(new URL(k.url).pathname);
  return out;
}

async function main() {
  const OFFLINE_BODY = "<!doctype html><title>Hors connexion</title><h1>Vous êtes hors connexion</h1>";
  function resetNetwork() {
    online = true; networkLog = [];
    stub = {
      "/offline.html": { status: 200, body: OFFLINE_BODY, headers: { "Content-Type": "text/html" } },
      "/i18n.js": { status: 200, body: "// i18n", headers: { "Cache-Control": "no-cache, must-revalidate" } },
      "/i18n-en-pwa.js": { status: 200, body: "// dict" },
      "/icons/icon-192.png": { status: 200, body: "png192" },
      "/icons/icon-512.png": { status: 200, body: "png512" },
      "/manifest.json": { status: 200, body: "{}" },
      "/": { status: 200, body: "<html>home</html>", headers: { "Content-Type": "text/html" } },
      "/style.css": { status: 200, body: "body{}", headers: { "Cache-Control": "no-cache, must-revalidate" } },
      "/app.js": { status: 200, body: "console.log('v1')" },
      "/api/workers": { status: 200, body: '{"workers":[]}', headers: { "Content-Type": "application/json" } },
      "/api/billing": { status: 200, body: '{"plan":"private"}', headers: { "Content-Type": "application/json" } },
    };
  }

  // ===== install / activate =====
  console.log("install / activate");
  resetNetwork();
  let sw = loadSw();
  const CACHE_NAME = sw.consts("CACHE_NAME");
  await sw.lifecycle("install");
  let cached = await cachedPaths(sw);
  check("install: /offline.html est dans le cache", cached.includes("/offline.html"), cached.join(","));
  check("install: skipWaiting appele (le nouveau SW prend la main tout de suite)", sw.state.skipped);
  for (const p of ["/i18n.js", "/i18n-en-pwa.js", "/icons/icon-192.png", "/manifest.json"]) {
    check(`install: ${p} precache (offline.html en a besoin)`, cached.includes(p));
  }
  check("install: le precache ne contient AUCUNE page de l'application ni /api/", !cached.some((p) => p === "/" || p.startsWith("/api/") || p === "/app.js" || p === "/index.html"), cached.join(","));

  resetNetwork();
  delete stub["/icons/icon-512.png"];            // un fichier optionnel manque -> l'installation reussit quand meme
  sw = loadSw();
  let failed = false;
  try { await sw.lifecycle("install"); } catch (e) { failed = true; }
  check("install: un fichier optionnel manquant n'empeche pas l'installation", !failed);

  resetNetwork();
  delete stub["/offline.html"];                  // la page de secours manque -> echec : l'ancien SW reste en place
  sw = loadSw();
  failed = false;
  try { await sw.lifecycle("install"); } catch (e) { failed = true; }
  check("install: sans /offline.html l'installation ECHOUE (jamais de SW sans page de secours)", failed);

  resetNetwork();
  sw = loadSw();
  await (await sw.caches.open("bk-shell-v1")).put("/app.js", new Response("vieux"));
  await (await sw.caches.open(CACHE_NAME)).put("/offline.html", new Response("ok"));
  await (await sw.caches.open("autre-application")).put("/x", new Response("x"));
  await sw.lifecycle("activate");
  const names = await sw.caches.keys();
  check("activate: l'ancien cache bk-shell-v1 est supprime", !names.includes("bk-shell-v1"), names.join(","));
  check("activate: le cache courant et ceux d'autres applications sont conserves", names.includes(CACHE_NAME) && names.includes("autre-application"), names.join(","));
  check("activate: clients.claim() appele", sw.state.claimed);

  // ===== navigation =====
  console.log("navigation");
  resetNetwork();
  sw = loadSw();
  await sw.lifecycle("install");
  let res = await sw.dispatchFetch(nav("/"));
  check("navigation en ligne: reponse du reseau, intacte", res && (await res.text()) === "<html>home</html>");
  check("navigation en ligne: la page n'est PAS mise en cache (pas de tableau de bord perime hors ligne)", !(await cachedPaths(sw)).includes("/"));

  online = false;
  res = await sw.dispatchFetch(nav("/"));
  let body = res ? await res.text() : "";
  check("navigation hors ligne: page de secours /offline.html", res && res.status === 200 && body.includes("Vous êtes hors connexion"), res && res.status);
  check("navigation hors ligne: la page de secours n'est pas mise en cache HTTP (no-store)", res && res.headers.get("Cache-Control") === "no-store");
  res = await sw.dispatchFetch(nav("/workers.html"));
  check("navigation hors ligne vers une autre page: meme page de secours", res && (await res.text()).includes("hors connexion"));
  online = true;
  for (const status of [502, 503, 504]) {
    stub["/"] = { status, body: "Bad Gateway" };
    res = await sw.dispatchFetch(nav("/"));
    check(`navigation ${status} (serveur en redeploiement): page de secours en 503`, res && res.status === 503 && (await res.text()).includes("hors connexion"), res && res.status);
  }
  for (const status of [404, 500]) {
    stub["/"] = { status, body: "boom" };
    res = await sw.dispatchFetch(nav("/"));
    check(`navigation ${status}: reponse du serveur conservee telle quelle`, res && res.status === status && (await res.text()) === "boom");
  }
  stub["/"] = { status: 200, body: "home" };
  // cache de secours vide -> page minimale integree
  sw = loadSw();
  online = false;
  res = await sw.dispatchFetch(nav("/"));
  body = await res.text();
  check("navigation hors ligne sans cache: page minimale integree (FR/EN)", res.status === 200 && body.includes("Hors connexion / Offline"));
  online = true;

  // ===== jamais intercepte =====
  console.log("jamais intercepte (donnees dynamiques / personnelles)");
  resetNetwork();
  sw = loadSw();
  await sw.lifecycle("install");
  const untouched = [
    ["GET /api/workers (fetch)", req("/api/workers")],
    ["GET /api/billing (fetch)", req("/api/billing", { headers: { Cookie: "bk_account=secret" } })],
    ["GET /api/ en navigation", nav("/api/billing")],
    ["GET /oauth/google/start (navigation)", nav("/oauth/google/start?provider=gmail")],
    ["GET /oauth/slack/callback", req("/oauth/slack/callback?code=abc")],
    ["GET /webhooks/twilio/voice", req("/webhooks/twilio/voice")],
    ["GET /.well-known/assetlinks.json", req("/.well-known/assetlinks.json")],
    ["GET /videos/intro.mp4", req("/videos/intro.mp4")],
    ["POST /api/missions", req("/api/missions", { method: "POST" })],
    ["POST en navigation (envoi d'un formulaire)", req("/", { method: "POST", mode: "navigate" })],
    ["POST /style.css", req("/style.css", { method: "POST" })],
    ["PUT /api/x", req("/api/x", { method: "PUT" })],
    ["DELETE /api/automations/1", req("/api/automations/1", { method: "DELETE" })],
    ["GET avec Authorization", req("/style.css", { headers: { Authorization: "Bearer k" } })],
    ["GET avec Range", req("/style.css", { headers: { Range: "bytes=0-10" } })],
    ["GET d'une autre origine", req("/lib.js", { origin: "https://cdn.example" })],
    ["GET /service-worker.js", req("/service-worker.js")],
    ["GET /workers.html (sous-ressource, pas dans la liste blanche)", req("/workers.html")],
    ["GET /api/ avec extension statique (/api/x.css)", req("/api/x.css")],
  ];
  for (const [name, r] of untouched) {
    const out = await sw.dispatchFetch(r);
    check(`non intercepte: ${name}`, out === null);
  }
  const paths = await cachedPaths(sw);
  check("aucune URL /api/, /oauth/, /webhooks/ dans le cache", !paths.some((p) => /^\/(api|oauth|webhooks|videos|\.well-known)\//.test(p)), paths.join(","));

  // ===== fichiers statiques : reseau d'abord =====
  console.log("fichiers statiques : reseau d'abord");
  stub["/app.js"] = { status: 200, body: "console.log('v1')" };
  res = await sw.dispatchFetch(req("/app.js"));
  check("statique en ligne: reponse du reseau", res && (await res.text()) === "console.log('v1')");
  await new Promise((r) => setTimeout(r, 20));
  check("statique en ligne: copie de secours gardee", (await cachedPaths(sw)).includes("/app.js"));
  stub["/app.js"] = { status: 200, body: "console.log('v2')" };
  res = await sw.dispatchFetch(req("/app.js"));
  check("NOUVELLE version servie des que le reseau repond (jamais de JS perime)", res && (await res.text()) === "console.log('v2')");
  await new Promise((r) => setTimeout(r, 20));
  online = false;
  res = await sw.dispatchFetch(req("/app.js"));
  check("statique hors ligne: copie de secours (derniere version vue)", res && (await res.text()) === "console.log('v2')");
  res = await sw.dispatchFetch(req("/portraits/jamais-vu.svg"));
  check("statique hors ligne et jamais vu: erreur reseau (pas de reponse inventee)", res && res.type === "error" || (res && res.status === 0));
  online = true;

  stub["/private.css"] = { status: 200, body: "x", headers: { "Cache-Control": "private, max-age=60" } };
  stub["/secret.js"] = { status: 200, body: "x", headers: { "Cache-Control": "no-store" } };
  stub["/missing.png"] = { status: 404, body: "no" };
  stub["/partial.png"] = { status: 206, body: "pa", headers: { "Content-Range": "bytes 0-1/9" } };
  stub["/vary.css"] = { status: 200, body: "x", headers: { Vary: "*" } };
  for (const p of ["/private.css", "/secret.js", "/missing.png", "/partial.png", "/vary.css"]) await sw.dispatchFetch(req(p));
  await new Promise((r) => setTimeout(r, 20));
  const after = await cachedPaths(sw);
  for (const [p, why] of [["/private.css", "Cache-Control: private"], ["/secret.js", "Cache-Control: no-store"], ["/missing.png", "404"], ["/partial.png", "206"], ["/vary.css", "Vary: *"]]) {
    check(`jamais en cache: ${p} (${why})`, !after.includes(p));
  }

  // ===== plafond du cache =====
  console.log("plafond du cache");
  for (let i = 0; i < 100; i++) { stub[`/portraits/w${i}.svg`] = { status: 200, body: "<svg/>" }; await sw.dispatchFetch(req(`/portraits/w${i}.svg`)); }
  await new Promise((r) => setTimeout(r, 200));
  const finalPaths = await cachedPaths(sw);
  const runtime = finalPaths.filter((p) => p.startsWith("/portraits/") || p === "/app.js");
  check("le cache de secours est plafonne (80 copies)", runtime.length <= 80, runtime.length);
  check("le plafond ne supprime jamais le precache (offline.html, i18n.js)", finalPaths.includes("/offline.html") && finalPaths.includes("/i18n.js"));
  check("en fin de parcours: aucune donnee authentifiee dans le cache", !finalPaths.some((p) => p.startsWith("/api/")));

  // ===== vrai serveur (si fourni) =====
  if (REAL_BASE) {
    console.log("vrai serveur : " + REAL_BASE);
    online = true; stub = {}; useReal = true;
    sw = loadSw();
    await sw.lifecycle("install");
    const real = await cachedPaths(sw);
    check("vrai serveur: precache complet (offline.html + i18n + icones + manifeste)", ["/offline.html", "/i18n.js", "/i18n-en-pwa.js", "/icons/icon-192.png", "/icons/icon-512.png", "/manifest.json"].every((p) => real.includes(p)), real.join(","));
    res = await sw.dispatchFetch(nav("/"));
    check("vrai serveur: navigation / = 200 HTML", res && res.status === 200 && /<html/i.test(await res.text()));
    online = false;
    res = await sw.dispatchFetch(nav("/"));
    check("vrai serveur, reseau coupe: la vraie page offline.html du depot", res && res.status === 200 && (await res.text()).includes("Vous êtes hors connexion"));
    online = true;
    await sw.dispatchFetch(req("/api/workers"));
    await sw.dispatchFetch(req("/style.css"));
    await new Promise((r) => setTimeout(r, 50));
    const realAfter = await cachedPaths(sw);
    check("vrai serveur: /style.css gardé en secours, /api/workers jamais", realAfter.includes("/style.css") && !realAfter.includes("/api/workers"), realAfter.join(","));
  }

  console.log(`\n${total - failures}/${total} controles passes`);
  process.exit(failures ? 1 : 0);
}

main().catch((e) => { console.error(e); process.exit(2); });
