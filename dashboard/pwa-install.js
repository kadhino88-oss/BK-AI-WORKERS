/* Installation de l'application (PWA) — 2026-10-07.
   - Chrome / Edge / Samsung Internet (Android et ordinateur) : on garde l'evenement
     beforeinstallprompt et on propose "Installer l'application" ; un clic ouvre la vraie
     fenetre d'installation du navigateur.
   - iPhone / iPad (Safari) : aucune API d'installation n'existe ; on affiche les trois
     gestes a faire ("Partager" > "Sur l'ecran d'accueil" > "Ajouter").
   - Jamais propose dans l'application deja installee (mode standalone, app TWA Android,
     coque Capacitor iOS/Android) ni apres "Fermer" (14 jours). Le lien du pied de page
     reste disponible tant que l'app n'est pas installee.
   - Raccourcis du manifeste (?shortcut=new-mission | automations) : ouvre la bonne vue.
   Les textes sont en francais (langue source) ; la version anglaise vient de
   i18n-en-pwa.js via le mecanisme habituel (i18n.js) — rien a faire ici.
   Aucun appel reseau, aucune donnee personnelle : trois cles localStorage (visites,
   date de fermeture, "installee"), toutes facultatives. */
(function () {
  "use strict";

  var DISMISS_KEY = "bk_pwa_dismissed_at";
  var VISITS_KEY = "bk_pwa_visits";
  var SESSION_KEY = "bk_pwa_session";
  var INSTALLED_KEY = "bk_pwa_installed";
  var DISMISS_MS = 14 * 24 * 60 * 60 * 1000;
  var MIN_VISITS = 2;          // la bannière n'apparait qu'a partir de la 2e visite ; le lien du pied de page est toujours la
  var SHOW_DELAY_MS = 5000;
  // Marque ajoutee au User-Agent par les coques store (Capacitor "appendUserAgent", voir docs/MOBILE-APPS.md).
  var STORE_UA_MARKER = "BKAIWorkersApp";

  // ---------- Fonctions pures (testees sous Node : tests/pwa/test_pwa_install.js) ----------

  function isIos(ua, platform, maxTouchPoints) {
    ua = ua || "";
    if (/iPad|iPhone|iPod/.test(ua)) return true;
    // iPadOS 13+ se presente comme un Mac ; seul le tactile le distingue.
    return platform === "MacIntel" && (maxTouchPoints || 0) > 1;
  }

  function isStoreApp(ua) {
    return (ua || "").indexOf(STORE_UA_MARKER) !== -1;
  }

  // env : { displayModes:[...matchMedia vrais], navigatorStandalone, referrer }
  function isStandalone(env) {
    env = env || {};
    var modes = env.displayModes || [];
    if (modes.indexOf("standalone") !== -1 || modes.indexOf("fullscreen") !== -1 ||
        modes.indexOf("minimal-ui") !== -1 || modes.indexOf("window-controls-overlay") !== -1) return true;
    if (env.navigatorStandalone === true) return true;                       // Safari iOS "ecran d'accueil"
    return String(env.referrer || "").indexOf("android-app://") === 0;      // Trusted Web Activity
  }

  // s : { standalone, storeApp, installedFlag, canInstall, dismissedAt, now, visits, force }
  function shouldShowBanner(s) {
    if (s.standalone || s.storeApp || s.installedFlag || !s.canInstall) return false;
    if (s.force) return true;
    if ((s.visits || 0) < MIN_VISITS) return false;
    if (s.dismissedAt && s.now - s.dismissedAt < DISMISS_MS) return false;
    return true;
  }

  var helpers = {
    isIos: isIos,
    isStoreApp: isStoreApp,
    isStandalone: isStandalone,
    shouldShowBanner: shouldShowBanner,
    constants: { DISMISS_MS: DISMISS_MS, MIN_VISITS: MIN_VISITS, STORE_UA_MARKER: STORE_UA_MARKER }
  };

  if (typeof document === "undefined") {                                    // Node (tests)
    if (typeof module !== "undefined" && module.exports) module.exports = helpers;
    return;
  }
  window.bkPwa = helpers;

  // ---------- Stockage (facultatif : navigation privee, donnees bloquees...) ----------

  var memory = {};
  function store(kind) { try { return window[kind]; } catch (e) { return null; } }
  function getItem(kind, key) {
    try { var v = store(kind).getItem(key); return v === null ? (memory[kind + key] || null) : v; } catch (e) { return memory[kind + key] || null; }
  }
  function setItem(kind, key, value) {
    memory[kind + key] = value;
    try { store(kind).setItem(key, value); } catch (e) { /* stockage indisponible : on garde en memoire */ }
  }

  // ---------- Etat ----------

  var ua = navigator.userAgent || "";
  var ios = isIos(ua, navigator.platform, navigator.maxTouchPoints);
  var storeApp = isStoreApp(ua) || !!window.Capacitor;
  var deferred = null;           // evenement beforeinstallprompt garde pour plus tard
  var banner = null;
  var iosOpen = false;

  function currentStandalone() {
    var modes = [];
    ["standalone", "fullscreen", "minimal-ui", "window-controls-overlay"].forEach(function (m) {
      try { if (window.matchMedia("(display-mode: " + m + ")").matches) modes.push(m); } catch (e) { /* ancien navigateur */ }
    });
    return isStandalone({ displayModes: modes, navigatorStandalone: navigator.standalone, referrer: document.referrer });
  }

  var standalone = currentStandalone();
  var root = document.documentElement;
  if (standalone) root.classList.add("is-installed-app");
  if (storeApp) {
    root.classList.add("is-store-app");
    if (ios) root.classList.add("is-ios-app");
    else if (/Android/i.test(ua)) root.classList.add("is-android-app");
  }

  function canInstall() { return !!deferred || ios; }
  function installedFlag() { return getItem("localStorage", INSTALLED_KEY) === "1"; }

  function countVisit() {
    if (getItem("sessionStorage", SESSION_KEY)) return;
    setItem("sessionStorage", SESSION_KEY, "1");
    setItem("localStorage", VISITS_KEY, String((parseInt(getItem("localStorage", VISITS_KEY), 10) || 0) + 1));
  }

  function visits() { return parseInt(getItem("localStorage", VISITS_KEY), 10) || 0; }

  function state(force) {
    return {
      standalone: standalone, storeApp: storeApp, installedFlag: installedFlag(), canInstall: canInstall(),
      dismissedAt: parseInt(getItem("localStorage", DISMISS_KEY), 10) || 0, now: Date.now(), visits: visits(), force: !!force
    };
  }

  // ---------- Interface ----------

  var SHARE_SVG = '<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 15V3"/><path d="M8 7l4-4 4 4"/><path d="M6 11H5a1 1 0 0 0-1 1v8a1 1 0 0 0 1 1h14a1 1 0 0 0 1-1v-8a1 1 0 0 0-1-1h-1"/></svg>';

  function el(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text) n.textContent = text;
    return n;
  }

  // Les boutons .btn sont "equipes" par app.js (effet de texte qui roule au survol : deux copies du texte
  // dans .roll-in). On met alors a jour les deux copies au lieu de casser la structure.
  function setButtonText(btn, text) {
    var roll = btn.querySelector(".roll-in");
    if (roll && roll.children.length) { for (var i = 0; i < roll.children.length; i++) roll.children[i].textContent = text; }
    else btn.textContent = text;
  }

  function buildBanner() {
    var b = el("div", "pwa-banner");
    b.id = "pwa-install-banner";
    b.setAttribute("role", "region");
    b.setAttribute("aria-label", "Installer l'application");
    b.hidden = true;

    var icon = el("img", "pwa-banner-icon");
    icon.src = "/icons/icon-192.png"; icon.width = 44; icon.height = 44; icon.alt = "";
    var text = el("div", "pwa-banner-text");
    text.appendChild(el("strong", "pwa-banner-title", "Installer l'application"));
    text.appendChild(el("span", "pwa-banner-sub", "Un accès direct depuis votre écran d'accueil, en plein écran."));

    var steps = el("ol", "pwa-ios-steps");
    steps.id = "pwa-ios-steps";
    steps.hidden = true;
    [["Touchez le bouton Partager, en bas ou en haut de l'écran.", true],
     ["Faites défiler puis choisissez « Sur l'écran d'accueil ».", false],
     ["Touchez « Ajouter » : l'icône BK-AI-WORKERS apparaît sur votre écran d'accueil.", false]].forEach(function (s) {
      var li = el("li");
      if (s[1]) { var ico = el("span", "pwa-share-ico"); ico.innerHTML = SHARE_SVG; li.appendChild(ico); }
      li.appendChild(el("span", "", s[0]));
      steps.appendChild(li);
    });

    var cta = el("button", "btn btn-gold pwa-banner-cta", ios && !deferred ? "Comment faire ?" : "Installer");
    cta.type = "button"; cta.id = "pwa-banner-cta";
    var close = el("button", "pwa-banner-close", "×");
    close.type = "button"; close.id = "pwa-banner-close"; close.setAttribute("aria-label", "Fermer");

    b.appendChild(icon); b.appendChild(text); b.appendChild(close); b.appendChild(steps); b.appendChild(cta);
    cta.addEventListener("click", onInstallClick);
    close.addEventListener("click", dismiss);
    document.body.appendChild(b);
    return b;
  }

  function setIosOpen(open) {
    iosOpen = open;
    if (!banner) return;
    var steps = banner.querySelector("#pwa-ios-steps");
    var cta = banner.querySelector("#pwa-banner-cta");
    steps.hidden = !open;
    setButtonText(cta, open ? "Compris" : "Comment faire ?");
    cta.setAttribute("aria-expanded", open ? "true" : "false");
    banner.classList.toggle("is-open", open);
  }

  function showBanner(openSteps) {
    if (!banner) banner = buildBanner();
    banner.hidden = false;
    if (ios && !deferred) setIosOpen(!!openSteps);
  }

  function hideBanner() { if (banner) banner.hidden = true; }

  function dismiss() {
    setItem("localStorage", DISMISS_KEY, String(Date.now()));
    hideBanner();
  }

  function syncFooterLink() {
    var link = document.getElementById("footer-install-app");
    if (link) link.hidden = !(canInstall() && !standalone && !storeApp && !installedFlag());
  }

  function onInstallClick(e) {
    if (e && e.preventDefault) e.preventDefault();
    if (deferred) {
      var ev = deferred;
      deferred = null;                       // prompt() ne peut servir qu'une fois par evenement
      hideBanner();
      syncFooterLink();
      try {
        var shown = ev.prompt();
        if (shown && shown.catch) shown.catch(function () { /* refus du navigateur : rien a faire de plus */ });
        if (ev.userChoice && ev.userChoice.then) {
          ev.userChoice.then(function (c) {
            if (c && c.outcome === "accepted") setItem("localStorage", INSTALLED_KEY, "1");
          }, function () { /* ignore */ });
        }
      } catch (err) { /* le navigateur a refuse : rien a faire de plus */ }
      return;
    }
    if (ios) {
      if (!banner || banner.hidden) { showBanner(true); return; }
      if (iosOpen) dismiss(); else setIosOpen(true);
    }
  }

  function maybeShow() {
    if (shouldShowBanner(state(false))) showBanner(false);
  }

  window.addEventListener("beforeinstallprompt", function (e) {
    e.preventDefault();                      // on affiche notre propre invitation, au bon moment
    deferred = e;
    syncFooterLink();
    if (banner && !banner.hidden) { var c = banner.querySelector("#pwa-banner-cta"); if (c) setButtonText(c, "Installer"); }
    setTimeout(maybeShow, SHOW_DELAY_MS);
  });

  window.addEventListener("appinstalled", function () {
    deferred = null;
    setItem("localStorage", INSTALLED_KEY, "1");
    hideBanner();
    syncFooterLink();
    if (typeof window.showToast === "function") window.showToast("Application installée ✓", true);
  });

  try {
    var mq = window.matchMedia("(display-mode: standalone)");
    var onMode = function () { standalone = currentStandalone(); if (standalone) { hideBanner(); } syncFooterLink(); };
    if (mq.addEventListener) mq.addEventListener("change", onMode); else if (mq.addListener) mq.addListener(onMode);
  } catch (e) { /* matchMedia indisponible */ }

  // ---------- Raccourcis du manifeste ----------

  // Passe par les vrais boutons de navigation de l'application (memes gestes qu'un clic) :
  // ce module ne depend donc d'aucune fonction interne de app.js, seulement d'identifiants.
  function routeShortcut() {
    var params, name;
    try { params = new URLSearchParams(location.search); name = params.get("shortcut"); } catch (e) { return; }
    if (!name) return;
    params.delete("shortcut");
    var qs = params.toString();
    try { history.replaceState(null, "", location.pathname + (qs ? "?" + qs : "") + location.hash); } catch (e) { /* ignore */ }

    function click(id) { var n = document.getElementById(id); if (n) n.click(); return !!n; }
    if (name === "automations") { click("nav-automations"); return; }
    if (name === "new-mission" && click("nav-chloe")) {
      var tries = 0;
      var timer = setInterval(function () {
        var view = document.getElementById("profile-view");
        var input = document.getElementById("task-input");
        tries++;
        if (view && !view.hidden && input) {
          clearInterval(timer);
          try { input.focus({ preventScroll: false }); } catch (e) { input.focus(); }
        } else if (tries > 30) {
          clearInterval(timer);
        }
      }, 100);
    }
  }

  // ---------- Demarrage ----------

  function init() {
    countVisit();
    var link = document.getElementById("footer-install-app");
    if (link) link.addEventListener("click", onInstallClick);
    syncFooterLink();
    if (ios && !standalone && !storeApp) setTimeout(maybeShow, SHOW_DELAY_MS);
    routeShortcut();
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
})();
