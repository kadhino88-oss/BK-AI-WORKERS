/* Test des regles de decision de l'invitation a installer (dashboard/pwa-install.js) sous Node :
 * detection iPhone/iPad, "deja installee", coque store, et quand la banniere a le droit d'apparaitre.
 * (L'affichage lui-meme est verifie dans un vrai navigateur, voir docs/MOBILE-APPS.md > Tests.)
 *   node tests/pwa/test_pwa_install.js */
"use strict";
const path = require("path");
const api = require(path.resolve(__dirname, "..", "..", "dashboard", "pwa-install.js"));

let failures = 0, total = 0;
function check(name, cond, detail) {
  total++;
  if (cond) console.log("  PASS  " + name);
  else { failures++; console.log("  FAIL  " + name + (detail !== undefined ? "  [" + detail + "]" : "")); }
}

const UA = {
  iphone: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1",
  ipad: "Mozilla/5.0 (iPad; CPU OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1",
  ipadDesktopMode: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15",
  mac: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15",
  android: "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36",
  windows: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
};

console.log("detection de la plateforme");
check("iPhone = iOS", api.isIos(UA.iphone, "iPhone", 5));
check("iPad = iOS", api.isIos(UA.ipad, "iPad", 5));
check("iPadOS en mode bureau (Macintosh + tactile) = iOS", api.isIos(UA.ipadDesktopMode, "MacIntel", 5));
check("vrai Mac (pas de tactile) = pas iOS", !api.isIos(UA.mac, "MacIntel", 0));
check("Android = pas iOS", !api.isIos(UA.android, "Linux armv8l", 5));
check("Windows = pas iOS", !api.isIos(UA.windows, "Win32", 0));
check("UA vide = pas iOS (aucune exception)", !api.isIos("", "", 0) && !api.isIos(undefined, undefined, undefined));
check("coque store reconnue par sa marque dans le User-Agent", api.isStoreApp(UA.iphone + " " + api.constants.STORE_UA_MARKER));
check("navigateur normal != coque store", !api.isStoreApp(UA.iphone) && !api.isStoreApp(""));

console.log("deja installee ?");
check("display-mode standalone", api.isStandalone({ displayModes: ["standalone"] }));
check("display-mode fullscreen / minimal-ui / window-controls-overlay", ["fullscreen", "minimal-ui", "window-controls-overlay"].every((m) => api.isStandalone({ displayModes: [m] })));
check("onglet de navigateur (display-mode browser) = non", !api.isStandalone({ displayModes: ["browser"] }) && !api.isStandalone({ displayModes: [] }));
check("Safari iOS 'ecran d'accueil' (navigator.standalone)", api.isStandalone({ displayModes: [], navigatorStandalone: true }));
check("navigator.standalone false = non", !api.isStandalone({ displayModes: [], navigatorStandalone: false }));
check("app Android TWA (referrer android-app://)", api.isStandalone({ displayModes: [], referrer: "android-app://com.bkaiworkers.app" }));
check("referrer web ordinaire = non", !api.isStandalone({ displayModes: [], referrer: "https://www.google.com/" }));
check("environnement vide = non (aucune exception)", !api.isStandalone() && !api.isStandalone({}));

console.log("la banniere a-t-elle le droit d'apparaitre ?");
const DAY = 24 * 3600 * 1000;
const now = 1_800_000_000_000;
const base = { standalone: false, storeApp: false, installedFlag: false, canInstall: true, dismissedAt: 0, now, visits: 2, force: false };
const show = (over) => api.shouldShowBanner(Object.assign({}, base, over));
check("2e visite, installable, jamais fermee: oui", show({}) === true);
check("1re visite: non (le lien du pied de page reste disponible)", show({ visits: 1 }) === false && show({ visits: 0 }) === false);
check("deja en mode application: non", show({ standalone: true }) === false);
check("coque store (Capacitor): non", show({ storeApp: true }) === false);
check("deja installee (drapeau): non", show({ installedFlag: true }) === false);
check("pas installable (ni evenement, ni iOS): non", show({ canInstall: false }) === false);
check("fermee hier: non", show({ dismissedAt: now - 1 * DAY }) === false);
check("fermee il y a 13 jours: non", show({ dismissedAt: now - 13 * DAY }) === false);
check("fermee il y a 15 jours: oui", show({ dismissedAt: now - 15 * DAY }) === true);
check("force (clic sur le lien du pied de page) ignore visites et fermeture", show({ force: true, visits: 0, dismissedAt: now }) === true);
check("force n'ignore jamais 'deja installee' ni 'coque store' ni 'pas installable'",
  show({ force: true, standalone: true }) === false && show({ force: true, storeApp: true }) === false && show({ force: true, canInstall: false }) === false && show({ force: true, installedFlag: true }) === false);

console.log(`\n${total - failures}/${total} controles passes`);
process.exit(failures ? 1 : 0);
