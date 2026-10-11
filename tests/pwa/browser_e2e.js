/* Verification dans un VRAI Chrome / Edge (headless) pilote par le protocole DevTools (CDP), sans bibliotheque :
 * installabilite selon Chrome lui-meme, service worker actif, cache, invitation a installer (ordinateur, Android,
 * iPhone), pas de chevauchement avec la bulle de Chloe, pas de defilement horizontal, raccourcis du manifeste,
 * page hors connexion (serveur coupe puis relance : rechargement automatique), anglais.
 *
 * Ne se lance pas seul : tests/pwa/browser_e2e.py demarre le serveur de test et pilote ce script
 * (il coupe et relance le serveur quand ce script le demande par une ligne "@@WAIT ...").
 * Variables : BK_TEST_BASE_URL (obligatoire), BK_CHROME (chemin de chrome/msedge), BK_SHOTS_DIR (captures PNG). */
"use strict";
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawn, spawnSync } = require("child_process");

const BASE = (process.env.BK_TEST_BASE_URL || "").replace(/\/$/, "");
const SHOTS = process.env.BK_SHOTS_DIR || "";
if (!BASE) { console.error("BK_TEST_BASE_URL manquant"); process.exit(2); }

let failures = 0, total = 0;
function check(name, cond, detail) {
  total++;
  if (cond) console.log("  PASS  " + name);
  else { failures++; console.log("  FAIL  " + name + (detail !== undefined ? "  [" + String(detail).slice(0, 400) + "]" : "")); }
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------- dialogue avec Python (couper / relancer le serveur) ----------
let stdinBuf = "", stdinWaiters = [];
process.stdin.on("data", (d) => {
  stdinBuf += d.toString();
  let i;
  while ((i = stdinBuf.indexOf("\n")) >= 0) { const line = stdinBuf.slice(0, i).trim(); stdinBuf = stdinBuf.slice(i + 1); const w = stdinWaiters.shift(); if (w) w(line); }
});
function askPython(what) {
  return new Promise((resolve) => { stdinWaiters.push(resolve); console.log("@@WAIT " + what); });
}

// ---------- Chrome ----------
function findChrome() {
  const c = [process.env.BK_CHROME, "C:/Program Files/Google/Chrome/Application/chrome.exe", "C:/Program Files (x86)/Google/Chrome/Application/chrome.exe",
    "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe", "/usr/bin/google-chrome", "/usr/bin/chromium", "/usr/bin/chromium-browser", "/usr/bin/microsoft-edge",
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"].filter(Boolean);
  return c.find((p) => fs.existsSync(p));
}
function launchChrome(exe) {
  const userDir = fs.mkdtempSync(path.join(os.tmpdir(), "bkpwa-chrome-"));
  const proc = spawn(exe, ["--headless=new", "--remote-debugging-port=0", "--user-data-dir=" + userDir, "--no-first-run", "--no-default-browser-check",
    "--disable-gpu", "--disable-breakpad", "--disable-extensions", "--disable-background-networking", "--disable-sync", "--mute-audio", "--window-size=1280,800", "about:blank"], { stdio: ["ignore", "ignore", "pipe"] });
  return new Promise((resolve, reject) => {
    let buf = "";
    const timer = setTimeout(() => reject(new Error("Chrome n'a pas annonce son port DevTools")), 30000);
    proc.stderr.on("data", (d) => {
      buf += d.toString();
      const m = buf.match(/DevTools listening on (ws:\/\/\S+)/);
      if (m) { clearTimeout(timer); resolve({ proc, wsUrl: m[1], userDir }); }
    });
    proc.on("exit", () => reject(new Error("Chrome s'est arrete : " + buf.slice(-300))));
  });
}

class Cdp {
  constructor(url) {
    this.id = 0; this.pending = new Map(); this.listeners = [];
    this.ws = new WebSocket(url);
    this.ready = new Promise((res, rej) => { this.ws.onopen = res; this.ws.onerror = (e) => rej(new Error("websocket CDP")); });
    this.ws.onmessage = (ev) => {
      const m = JSON.parse(ev.data);
      if (m.id) { const p = this.pending.get(m.id); if (p) { this.pending.delete(m.id); m.error ? p.rej(new Error(m.error.message)) : p.res(m.result); } }
      else this.listeners.forEach((l) => l(m));
    };
  }
  send(method, params = {}, sessionId) {
    const id = ++this.id;
    return new Promise((res, rej) => { this.pending.set(id, { res, rej }); this.ws.send(JSON.stringify({ id, method, params, sessionId })); });
  }
  on(fn) { this.listeners.push(fn); }
}

class Page {
  constructor(cdp, sessionId) {
    this.cdp = cdp; this.sessionId = sessionId; this.exceptions = []; this.requests = [];
    cdp.on((m) => {
      if (m.sessionId !== sessionId) return;
      if (m.method === "Runtime.exceptionThrown") this.exceptions.push((m.params.exceptionDetails.exception && m.params.exceptionDetails.exception.description) || m.params.exceptionDetails.text);
      if (m.method === "Network.requestWillBeSent") this.requests.push(m.params.request.url);
    });
  }
  send(method, params) { return this.cdp.send(method, params, this.sessionId); }
  waitEvent(name, timeout = 45000) {
    return new Promise((res, rej) => {
      const t = setTimeout(() => rej(new Error("delai depasse : " + name)), timeout);
      this.cdp.on((m) => { if (m.sessionId === this.sessionId && m.method === name) { clearTimeout(t); res(m.params); } });
    });
  }
  async goto(url) { const loaded = this.waitEvent("Page.loadEventFired"); await this.send("Page.navigate", { url }); await loaded; }
  async reload() { const loaded = this.waitEvent("Page.loadEventFired"); await this.send("Page.reload", {}); await loaded; }
  async eval(expression) {
    const r = await this.send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
    if (r.exceptionDetails) throw new Error("eval: " + ((r.exceptionDetails.exception && r.exceptionDetails.exception.description) || r.exceptionDetails.text));
    return r.result.value;
  }
  async waitFor(expression, timeout = 10000, step = 100) {
    const end = Date.now() + timeout;
    let last;
    while (Date.now() < end) { try { last = await this.eval(expression); if (last) return last; } catch (e) { last = e.message; } await sleep(step); }
    return false;
  }
  async shot(name) {
    if (!SHOTS) return;
    await sleep(600);               // laisse finir l'animation d'entree et la peinture des images
    const r = await this.send("Page.captureScreenshot", { format: "png" });
    fs.mkdirSync(SHOTS, { recursive: true });
    fs.writeFileSync(path.join(SHOTS, name + ".png"), Buffer.from(r.data, "base64"));
  }
}

const IOS_UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1";
const ANDROID_UA = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36";

const FAKE_PROMPT_EVENT = `(() => {
  const e = new Event('beforeinstallprompt', { cancelable: true });
  e.prompt = () => { window.__prompted = (window.__prompted || 0) + 1; return Promise.resolve(); };
  e.userChoice = Promise.resolve({ outcome: 'accepted', platform: 'web' });
  window.dispatchEvent(e);
  return e.defaultPrevented;
})()`;
// Libelle d'un bouton .btn : app.js double le texte (effet "roule au survol"), on lit la 1re copie.
const LABEL = (id) => `(() => { const b = document.getElementById(${JSON.stringify(id)}); const r = b.querySelector('.roll-in > span'); return (r || b).textContent; })()`;
// Chrome emet lui-meme un vrai beforeinstallprompt (page installable) : on le compte puis on le bloque, pour que
// seuls les evenements simules par le test atteignent l'application (sinon prompt() exige un vrai geste utilisateur).
const BLOCK_REAL_PROMPT = `window.addEventListener('beforeinstallprompt', (e) => { if (e.isTrusted) { window.__realPromptEvents = (window.__realPromptEvents || 0) + 1; e.stopImmediatePropagation(); } }, true);`;
const BANNER_VISIBLE = `(() => { const b = document.getElementById('pwa-install-banner'); return !!b && !b.hidden && getComputedStyle(b).display !== 'none'; })()`;
const RECTS = `(() => {
  const r = (el) => { if (!el) return null; const b = el.getBoundingClientRect(); return { l: b.left, t: b.top, r: b.right, b: b.bottom }; };
  return { banner: r(document.getElementById('pwa-install-banner')), fab: r(document.getElementById('chloe-fab-toggle')), vw: innerWidth, vh: innerHeight,
           scrollW: document.documentElement.scrollWidth, bodyScrollW: document.body.scrollWidth };
})()`;
// L'animation d'entree de la banniere (0,35 s) est terminee : avant, elle est encore decalee de 16 px vers le bas.
// (D'autres animations infinies de la page, comme la lueur du hero, ne se terminent jamais : on ne regarde que la banniere.)
const SETTLED = `(() => { const b = document.getElementById('pwa-install-banner'); return !!b && b.getAnimations().every((a) => a.playState === 'finished'); })()`;
const overlap = (a, b) => a && b && a.l < b.r && a.r > b.l && a.t < b.b && a.b > b.t;

async function resetStorage(page, extra = {}) {
  await page.eval(`localStorage.clear(); sessionStorage.setItem('bk_pwa_session','1'); ${Object.entries(extra).map(([k, v]) => `localStorage.setItem(${JSON.stringify(k)}, ${JSON.stringify(v)});`).join(" ")} true`);
}

// Arrete Chrome ET ses processus enfants (sous Windows, le gestionnaire de plantages garde des fichiers du profil ouverts).
function killTree(proc) {
  try {
    if (process.platform === "win32") spawnSync("taskkill", ["/pid", String(proc.pid), "/T", "/F"], { stdio: "ignore" });
    else proc.kill();
  } catch (e) { /* deja arrete */ }
}

// Windows garde quelques fichiers de Chrome verrouilles un instant apres son arret (EBUSY) : on reessaie, et un
// dossier temporaire qui reste ne doit jamais faire echouer le test.
async function removeDir(dir) {
  for (let i = 0; i < 20; i++) {
    try { fs.rmSync(dir, { recursive: true, force: true }); return; } catch (e) { await sleep(500); }
  }
  console.log("  (info) dossier temporaire non supprime : " + dir);
}

async function main() {
  const exe = findChrome();
  if (!exe) { console.log("SKIP : Chrome / Edge introuvable (definir BK_CHROME)"); process.exit(0); }
  const { proc, wsUrl, userDir } = await launchChrome(exe);
  const cdp = new Cdp(wsUrl);
  await cdp.ready;
  try {
    const { targetId } = await cdp.send("Target.createTarget", { url: "about:blank" });
    const { sessionId } = await cdp.send("Target.attachToTarget", { targetId, flatten: true });
    const page = new Page(cdp, sessionId);
    for (const m of ["Page.enable", "Runtime.enable", "Network.enable"]) await page.send(m);
    const version = await cdp.send("Browser.getVersion");
    console.log("navigateur : " + version.product);
    const desktop = async () => {
      await page.send("Emulation.setDeviceMetricsOverride", { width: 1280, height: 800, deviceScaleFactor: 1, mobile: false });
      await page.send("Emulation.setUserAgentOverride", { userAgent: ORIGINAL_UA });
    };
    await page.goto("about:blank");
    const ORIGINAL_UA = (await page.eval("navigator.userAgent")).replace("HeadlessChrome", "Chrome");
    await desktop();
    await page.send("Page.addScriptToEvaluateOnNewDocument", { source: BLOCK_REAL_PROMPT });

    // ===== installabilite, service worker, cache =====
    console.log("installabilite et service worker (Chrome lui-meme)");
    await page.goto(BASE + "/");
    check("le service worker devient actif (activated)", await page.waitFor(`navigator.serviceWorker.getRegistration().then(r => !!r && !!r.active && r.active.state === 'activated')`, 60000));
    const reg = await page.eval(`navigator.serviceWorker.getRegistration().then(r => ({ scope: r.scope }))`);
    check("portee du service worker = racine du site", reg.scope === BASE + "/", reg.scope);
    const cacheState = await page.eval(`(async () => { const out = {}; for (const n of await caches.keys()) out[n] = (await (await caches.open(n)).keys()).map(k => new URL(k.url).pathname); return out; })()`);
    check("cache bk-shell-v2 cree avec /offline.html", cacheState["bk-shell-v2"] && cacheState["bk-shell-v2"].includes("/offline.html"), JSON.stringify(cacheState));
    check("aucun cache bk-shell-v1 residuel", !cacheState["bk-shell-v1"]);
    const am = await page.send("Page.getAppManifest");
    check("manifeste lu par Chrome sans aucune erreur", (am.errors || []).length === 0, JSON.stringify(am.errors));
    const parsed = JSON.parse(am.data || "{}");
    check("Chrome voit les 2 raccourcis, id, categories et 3 icones", (parsed.shortcuts || []).length === 2 && parsed.id === "/?pwa=1" && (parsed.categories || []).length === 2 && (parsed.icons || []).length === 3, am.data && am.data.slice(0, 200));
    const ie = await page.send("Page.getInstallabilityErrors");
    check("Chrome: AUCUNE erreur d'installabilite", (ie.installabilityErrors || []).length === 0, JSON.stringify(ie.installabilityErrors));
    try {
      const appId = await page.send("Page.getAppId");
      check("identifiant de l'application stable (= ancien start_url, pas de doublon pour les installations existantes)", appId.appId === BASE + "/?pwa=1", JSON.stringify(appId));
    } catch (e) { console.log("  (Page.getAppId indisponible : " + e.message + ")"); }
    await page.reload();
    check("apres rechargement, la page est controlee par le service worker", await page.waitFor(`!!navigator.serviceWorker.controller`, 8000));
    check("aucune exception JavaScript sur la page d'accueil", page.exceptions.length === 0, page.exceptions.join(" | "));
    const realEvents = await page.waitFor(`window.__realPromptEvents || 0`, 6000);
    console.log("  (info) Chrome a emis " + (realEvents || 0) + " vrai(s) evenement(s) beforeinstallprompt sur cette page installable");

    // ===== invitation a installer : ordinateur =====
    console.log("invitation a installer : ordinateur (Chrome / Edge)");
    await resetStorage(page);                                   // 1re visite : visits=1 vient du chargement ; on force 1
    await page.eval(`localStorage.setItem('bk_pwa_visits','1'); true`);
    await page.reload();
    check("beforeinstallprompt : preventDefault() appele (invitation maison, pas la mini-barre)", await page.eval(FAKE_PROMPT_EVENT) === true);
    check("le lien 'Installer l'application' du pied de page apparait", await page.waitFor(`!document.getElementById('footer-install-app').hidden`, 3000));
    await sleep(5600);
    check("1re visite : PAS de banniere (le lien du pied de page suffit)", (await page.eval(BANNER_VISIBLE)) === false);

    await resetStorage(page, { bk_pwa_visits: "2" });
    await page.reload();
    await page.eval(FAKE_PROMPT_EVENT);
    check("2e visite : banniere visible apres ~5 s", await page.waitFor(BANNER_VISIBLE, 8000));
    check("texte FR de la banniere", await page.eval(`document.querySelector('.pwa-banner-title').textContent === "Installer l'application" && ${LABEL("pwa-banner-cta")} === 'Installer'`));
    await page.shot("desktop-banner");
    await page.eval(`document.getElementById('pwa-banner-cta').click(); true`);
    check("clic sur Installer : la vraie invite du navigateur est demandee (prompt() appele)", (await page.eval(`window.__prompted || 0`)) === 1);
    check("apres l'invite : banniere et lien du pied de page caches", (await page.eval(BANNER_VISIBLE)) === false && (await page.eval(`document.getElementById('footer-install-app').hidden`)) === true);
    check("choix 'accepted' memorise (plus jamais propose)", await page.waitFor(`localStorage.getItem('bk_pwa_installed') === '1'`, 3000));

    await resetStorage(page, { bk_pwa_visits: "2" });
    await page.reload();
    await page.eval(FAKE_PROMPT_EVENT);
    await page.waitFor(BANNER_VISIBLE, 8000);
    await page.eval(`document.getElementById('pwa-banner-close').click(); true`);
    check("bouton Fermer : banniere cachee + date memorisee", (await page.eval(BANNER_VISIBLE)) === false && !!(await page.eval(`localStorage.getItem('bk_pwa_dismissed_at')`)));
    await page.reload();
    await page.eval(FAKE_PROMPT_EVENT);
    await sleep(5600);
    check("apres Fermer : la banniere ne revient pas (14 jours)", (await page.eval(BANNER_VISIBLE)) === false);
    check("apres Fermer : le lien du pied de page reste disponible", (await page.eval(`document.getElementById('footer-install-app').hidden`)) === false);
    await page.eval(`document.getElementById('footer-install-app').click(); true`);
    check("lien du pied de page : ouvre la vraie invite du navigateur", (await page.eval(`window.__prompted || 0`)) === 1);

    // ===== anglais =====
    console.log("anglais");
    await resetStorage(page, { bk_pwa_visits: "2", bk_lang: "en" });
    await page.reload();
    await page.eval(FAKE_PROMPT_EVENT);
    await page.waitFor(BANNER_VISIBLE, 8000);
    const en = await page.eval(`({ title: document.querySelector('.pwa-banner-title').textContent, sub: document.querySelector('.pwa-banner-sub').textContent,
      cta: ${LABEL("pwa-banner-cta")}, close: document.getElementById('pwa-banner-close').getAttribute('aria-label'),
      region: document.getElementById('pwa-install-banner').getAttribute('aria-label'), footer: document.getElementById('footer-install-app').textContent.trim() })`);
    check("banniere en anglais", en.title === "Install the app" && en.cta === "Install" && en.close === "Close" && en.region === "Install the app" && en.footer === "Install the app" && en.sub.startsWith("A direct shortcut"), JSON.stringify(en));
    await page.eval(`localStorage.setItem('bk_lang','fr'); true`);

    // ===== telephone Android =====
    console.log("telephone Android (390x844, 320x640)");
    for (const [w, h] of [[390, 844], [320, 640]]) {
      await page.send("Emulation.setDeviceMetricsOverride", { width: w, height: h, deviceScaleFactor: 2, mobile: true });
      await page.send("Emulation.setUserAgentOverride", { userAgent: ANDROID_UA, platform: "Linux armv8l" });
      await resetStorage(page, { bk_pwa_visits: "2" });
      await page.reload();
      await page.eval(FAKE_PROMPT_EVENT);
      check(`${w}px : banniere visible`, await page.waitFor(BANNER_VISIBLE, 8000));
      check(`${w}px : l'icone de la banniere est chargee et affichee`, await page.waitFor(`(() => { const i = document.querySelector('.pwa-banner-icon'); return i.complete && i.naturalWidth === 192 && i.getBoundingClientRect().width >= 40; })()`, 5000));
      await page.waitFor(SETTLED, 3000);
      const g = await page.eval(RECTS);
      check(`${w}px : banniere entierement dans l'ecran`, g.banner.l >= 0 && g.banner.r <= g.vw && g.banner.t >= 0 && g.banner.b <= g.vh, JSON.stringify(g));
      check(`${w}px : ne recouvre PAS la bulle de Chloe`, !overlap(g.banner, g.fab), JSON.stringify(g));
      check(`${w}px : aucun defilement horizontal`, g.scrollW <= g.vw && g.bodyScrollW <= g.vw, JSON.stringify(g));
      await page.shot(`android-${w}`);
    }

    // ===== iPhone =====
    console.log("iPhone (Safari simule)");
    await page.send("Emulation.setDeviceMetricsOverride", { width: 375, height: 812, deviceScaleFactor: 3, mobile: true });
    await page.send("Emulation.setUserAgentOverride", { userAgent: IOS_UA, platform: "iPhone" });
    await resetStorage(page, { bk_pwa_visits: "2" });
    await page.reload();
    check("iPhone : banniere visible sans aucun evenement navigateur", await page.waitFor(BANNER_VISIBLE, 9000));
    check("iPhone : bouton 'Comment faire ?'", await page.eval(`${LABEL("pwa-banner-cta")} === 'Comment faire ?'`));
    await page.eval(`document.getElementById('pwa-banner-cta').click(); true`);
    const steps = await page.eval(`({ shown: !document.getElementById('pwa-ios-steps').hidden, n: document.querySelectorAll('#pwa-ios-steps li').length, text: document.getElementById('pwa-ios-steps').innerText, cta: ${LABEL("pwa-banner-cta")}, expanded: document.getElementById('pwa-banner-cta').getAttribute('aria-expanded') })`);
    check("iPhone : les 3 etapes (Partager > Sur l'ecran d'accueil > Ajouter) s'affichent", steps.shown && steps.n === 3 && /Partager/.test(steps.text) && /Sur l'écran d'accueil/.test(steps.text) && /Ajouter/.test(steps.text) && steps.cta === "Compris" && steps.expanded === "true", JSON.stringify(steps));
    await page.waitFor(SETTLED, 3000);
    const gi = await page.eval(RECTS);
    check("iPhone, etapes ouvertes : dans l'ecran, sans chevaucher la bulle de Chloe, sans defilement horizontal", gi.banner.l >= 0 && gi.banner.r <= gi.vw && gi.banner.t >= 0 && gi.banner.b <= gi.vh && !overlap(gi.banner, gi.fab) && gi.scrollW <= gi.vw, JSON.stringify(gi));
    await page.shot("ios-steps");
    await page.eval(`document.getElementById('pwa-banner-cta').click(); true`);
    check("iPhone : 'Compris' ferme la banniere", (await page.eval(BANNER_VISIBLE)) === false);
    check("iPhone : le lien du pied de page rouvre les etapes", await (async () => { await page.eval(`document.getElementById('footer-install-app').click(); true`); return await page.eval(`!document.getElementById('pwa-ios-steps').hidden`); })());

    // ===== jamais dans l'application deja installee =====
    console.log("jamais propose dans l'application installee / les coques store");
    const standaloneScript = await page.send("Page.addScriptToEvaluateOnNewDocument", { source: "Object.defineProperty(navigator, 'standalone', { get: () => true });" });
    await resetStorage(page, { bk_pwa_visits: "5" });
    await page.reload();
    await sleep(5600);
    const st = await page.eval(`({ banner: ${BANNER_VISIBLE}, footerHidden: document.getElementById('footer-install-app').hidden, cls: document.documentElement.classList.contains('is-installed-app') })`);
    check("iPhone, ecran d'accueil (navigator.standalone) : aucune banniere, aucun lien, classe is-installed-app", st.banner === false && st.footerHidden === true && st.cls === true, JSON.stringify(st));
    await page.send("Page.removeScriptToEvaluateOnNewDocument", { identifier: standaloneScript.identifier });
    await page.send("Emulation.setUserAgentOverride", { userAgent: IOS_UA + " BKAIWorkersApp/1.0", platform: "iPhone" });
    await resetStorage(page, { bk_pwa_visits: "5" });
    await page.reload();
    await sleep(5600);
    const sa = await page.eval(`({ banner: ${BANNER_VISIBLE}, footerHidden: document.getElementById('footer-install-app').hidden, store: document.documentElement.classList.contains('is-store-app'), ios: document.documentElement.classList.contains('is-ios-app') })`);
    check("coque iOS (marque BKAIWorkersApp) : aucune invitation, classes is-store-app + is-ios-app", sa.banner === false && sa.footerHidden === true && sa.store && sa.ios, JSON.stringify(sa));

    // ===== raccourcis du manifeste =====
    console.log("raccourcis du manifeste");
    await desktop();
    await resetStorage(page);
    await page.goto(BASE + "/?pwa=1&shortcut=automations");
    check("raccourci 'Automatisations' : la vue s'ouvre", await page.waitFor(`!document.getElementById('automations-view').hidden`, 8000));
    check("raccourci : le parametre ?shortcut disparait de l'adresse (pwa=1 reste)", await page.eval(`location.search === '?pwa=1'`));
    await page.goto(BASE + "/?pwa=1&shortcut=new-mission");
    check("raccourci 'Nouvelle mission' : la fiche de Chloe s'ouvre", await page.waitFor(`!document.getElementById('profile-view').hidden`, 8000));
    check("raccourci 'Nouvelle mission' : le champ de mission est selectionne", await page.waitFor(`document.activeElement && document.activeElement.id === 'task-input'`, 8000));
    page.exceptions.length = 0;
    await page.goto(BASE + "/?pwa=1&shortcut=n-importe-quoi");
    check("raccourci inconnu : accueil normal, sans erreur", (await page.eval(`!document.getElementById('home-view').hidden`)) && page.exceptions.length === 0, page.exceptions.join("|"));

    // ===== hors connexion =====
    console.log("hors connexion (serveur coupe pour de vrai)");
    await resetStorage(page);
    await page.goto(BASE + "/");
    await page.waitFor(`!!navigator.serviceWorker.controller`, 8000);
    await askPython("stop-server");
    page.requests = [];
    await page.goto(BASE + "/");
    page.exceptions.length = 0;      // seules comptent les exceptions de la page de secours (l'ancienne page d'accueil perd son serveur : comportement existant de app.js)
    const off = await page.eval(`({ h1: document.querySelector('h1').innerText, title: document.title, server: !document.getElementById('msg-server').hidden, offline: !document.getElementById('msg-offline').hidden, retry: !!document.getElementById('retry') })`);
    check("serveur coupe : la page de secours de BK-AI-WORKERS s'affiche (pas la page d'erreur du navigateur)", off.h1 === "Vous êtes hors connexion" && off.title.startsWith("Hors connexion") && off.retry, JSON.stringify(off));
    check("appareil en ligne mais serveur muet : message 'ne repond pas pour le moment'", off.server === true && off.offline === false, JSON.stringify(off));
    await page.send("Network.emulateNetworkConditions", { offline: true, latency: 0, downloadThroughput: -1, uploadThroughput: -1 });
    await page.waitFor(`!document.getElementById('msg-offline').hidden`, 5000);
    check("appareil hors ligne : message 'Aucune connexion Internet'", await page.eval(`!document.getElementById('msg-offline').hidden && document.getElementById('msg-server').hidden`));
    await page.send("Network.emulateNetworkConditions", { offline: false, latency: 0, downloadThroughput: -1, uploadThroughput: -1 });
    await page.shot("offline-fr");
    check("la page de secours n'appelle que le meme site (aucune ressource externe)", page.requests.every((u) => u.startsWith(BASE + "/") || u.startsWith("data:") || u.startsWith("blob:")), page.requests.filter((u) => !u.startsWith(BASE + "/")).join(" "));
    await page.goto(BASE + "/workers.html");
    check("une autre page du site, serveur coupe : meme page de secours", await page.eval(`document.querySelector('h1').innerText === 'Vous êtes hors connexion'`));
    await page.eval(`document.getElementById('lang-toggle').click(); true`);
    const offEn = await page.eval(`({ h1: document.querySelector('h1').innerText, title: document.title, btn: document.getElementById('retry').textContent, note: document.querySelector('.note').textContent })`);
    check("page de secours en anglais (titre, bouton, note de confidentialite)", offEn.h1 === "You are offline" && offEn.title === "Offline — BK-AI-WORKERS" && offEn.btn === "Try again now" && offEn.note.startsWith("For your security"), JSON.stringify(offEn));
    await page.shot("offline-en");
    await page.eval(`document.getElementById('lang-toggle').click(); true`);
    check("API jamais mise en cache : aucune URL /api/ dans le cache", await page.eval(`(async () => { for (const n of await caches.keys()) for (const k of await (await caches.open(n)).keys()) if (/\\/api\\//.test(k.url)) return false; return true; })()`));
    check("aucune exception JavaScript sur la page de secours", page.exceptions.length === 0, page.exceptions.join(" | "));

    await askPython("start-server");
    check("serveur relance : la page de secours se recharge toute seule vers la page demandee (/workers.html)", await page.waitFor(`location.pathname === '/workers.html' && !document.getElementById('retry') && document.querySelector('h1') && document.querySelector('h1').innerText !== 'Vous êtes hors connexion'`, 40000, 500));
  } finally {
    try { cdp.ws.close(); } catch (e) { /* ignore */ }
    killTree(proc);
    await removeDir(userDir);
  }
  console.log(`\n${total - failures}/${total} controles passes`);
  process.exit(failures ? 1 : 0);
}

main().catch((e) => { console.error(e); process.exit(2); });
