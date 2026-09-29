/* Traduction de l'interface (FR <-> EN), cote navigateur.
   Le francais est la langue source du site ; l'anglais est applique par
   dictionnaire (window.BK_EN, voir i18n-en*.js) sur les textes affiches,
   y compris ceux inseres plus tard par l'application (MutationObserver).
   Un texte absent du dictionnaire reste en francais : jamais de page cassee.
   Langue : choix memorise (localStorage bk_lang) sinon langue du navigateur. */
(function () {
  "use strict";
  var ATTRS = ["placeholder", "title", "aria-label", "alt"];
  var SKIP_TAGS = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, TEXTAREA: 0 };
  var dict = {};
  var lang = "fr";
  var origText = new WeakMap();
  var origAttr = new WeakMap();
  var wroteText = new WeakMap();   // valeur que NOUS avons ecrite (evite de traiter nos propres mutations)
  var wroteAttr = new WeakMap();
  var observer = null;
  var busy = false;

  function stored() { try { return localStorage.getItem("bk_lang"); } catch (e) { return null; } }
  function detect() {
    var s = stored();
    if (s === "fr" || s === "en") return s;
    var n = ((navigator.languages && navigator.languages[0]) || navigator.language || "fr").toLowerCase();
    return n.indexOf("fr") === 0 ? "fr" : "en";
  }
  function norm(s) { return String(s).replace(/\s+/g, " ").trim(); }

  // Modeles pour les textes avec un nombre / un nom inseres.
  var PATTERNS = [
    [/^(.+) \((\d+)\)$/, function (m, t) { var x = t(m[1]); return x === null ? null : x + " (" + m[2] + ")"; }],
    [/^(\d+) (Workers?|missions?)$/i, function (m) { return m[1] + " " + m[2]; }],
    [/^Confier une mission à (.+)$/, function (m) { return "Give " + m[1] + " a mission"; }],
    [/^Discuter avec (.+)$/, function (m) { return "Chat with " + m[1]; }],
    [/^Traité par : (.+)$/, function (m) { return "Handled by: " + m[1]; }],
    [/^ou (.+)\/an — 2 mois offerts$/, function (m) { return "or " + m[1] + "/year — 2 months free"; }],
    [/^Alex — (.+)$/, null]
  ];

  function translate(str) {
    var k = norm(str);
    if (!k) return null;
    if (Object.prototype.hasOwnProperty.call(dict, k)) return dict[k];
    var helper = function (s) { var v = translate(s); return v; };
    for (var i = 0; i < PATTERNS.length; i++) {
      var p = PATTERNS[i];
      if (!p[1]) continue;
      var m = k.match(p[0]);
      if (m) { var r = p[1](m, helper); if (r !== null && r !== undefined) return r; }
    }
    // "Nom — Domaine" (listes de Workers) : traduit chaque morceau
    if (k.indexOf(" — ") > 0) {
      var parts = k.split(" — "), out = [], any = false;
      for (var j = 0; j < parts.length; j++) {
        var t = Object.prototype.hasOwnProperty.call(dict, parts[j]) ? dict[parts[j]] : null;
        if (t !== null) any = true;
        out.push(t !== null ? t : parts[j]);
      }
      if (any) return out.join(" — ");
    }
    // Fragments (phrases avec valeurs inserees)
    var frag = window.BK_EN_FRAG, changed = false, res = k;
    if (frag) {
      for (var f = 0; f < frag.length; f++) {
        if (res.indexOf(frag[f][0]) !== -1) { res = res.split(frag[f][0]).join(frag[f][1]); changed = true; }
      }
    }
    return changed ? res : null;
  }

  function keepSpace(orig, translated) {
    var lead = (orig.match(/^\s*/) || [""])[0], trail = (orig.match(/\s*$/) || [""])[0];
    return lead + translated + trail;
  }

  function skip(el) {
    for (var e = el; e; e = e.parentElement) {
      if (SKIP_TAGS[e.tagName]) return true;
      if (e.hasAttribute && e.hasAttribute("data-no-i18n")) return true;
    }
    return false;
  }

  function textNode(node) {
    var p = node.parentElement;
    if (!p || skip(p)) return;
    if (lang === "en") {
      var base = origText.has(node) ? origText.get(node) : node.nodeValue;
      var t = translate(base);
      if (t !== null) {
        if (!origText.has(node)) origText.set(node, node.nodeValue);
        var v = keepSpace(base, t);
        if (node.nodeValue !== v) node.nodeValue = v;
        wroteText.set(node, v);
      }
    } else if (origText.has(node)) {
      var o = origText.get(node);
      origText.delete(node);
      if (node.nodeValue !== o) node.nodeValue = o;
    }
  }

  function attrs(el) {
    if (!el.getAttribute || skip(el)) return;
    for (var i = 0; i < ATTRS.length; i++) {
      var a = ATTRS[i], cur = el.getAttribute(a);
      if (cur === null) continue;
      var saved = origAttr.get(el) || {};
      if (lang === "en") {
        var base = Object.prototype.hasOwnProperty.call(saved, a) ? saved[a] : cur;
        var t = translate(base.replace(/^Ex ?: ?/, function (m) { return m; }));
        if (t === null && /^Ex ?: /.test(base)) {
          var inner = translate(base.replace(/^Ex ?: ?/, ""));
          if (inner !== null) t = "E.g. " + inner;
        }
        if (t !== null) {
          saved[a] = base; origAttr.set(el, saved);
          if (cur !== t) el.setAttribute(a, t);
          var wa = wroteAttr.get(el) || {}; wa[a] = t; wroteAttr.set(el, wa);
        }
      } else if (Object.prototype.hasOwnProperty.call(saved, a)) {
        el.setAttribute(a, saved[a]); delete saved[a];
      }
    }
  }

  function walk(root) {
    if (!root) return;
    if (root.nodeType === 3) { textNode(root); return; }
    if (root.nodeType !== 1) return;
    attrs(root);
    var w = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, null);
    var n;
    while ((n = w.nextNode())) { n.nodeType === 3 ? textNode(n) : attrs(n); }
  }

  function applyAll() {
    busy = true;
    try {
      walk(document.body);
      document.documentElement.lang = lang;
      var meta = document.querySelector('meta[name="description"]');
      if (!window.__bkOrigHead) window.__bkOrigHead = { title: document.title, desc: meta ? meta.content : "" };
      if (lang === "en" && window.BK_EN_HEAD) {
        document.title = window.BK_EN_HEAD.title;
        if (meta) meta.content = window.BK_EN_HEAD.description;
      } else {
        document.title = window.__bkOrigHead.title;
        if (meta) meta.content = window.__bkOrigHead.desc;
      }
    } finally { busy = false; }
  }

  function startObserver() {
    if (observer || !window.MutationObserver) return;
    observer = new MutationObserver(function (muts) {
      if (busy || lang !== "en") return;
      busy = true;
      try {
        for (var i = 0; i < muts.length; i++) {
          var m = muts[i];
          if (m.type === "childList") { for (var j = 0; j < m.addedNodes.length; j++) walk(m.addedNodes[j]); }
          else if (m.type === "characterData") { if (wroteText.get(m.target) === m.target.nodeValue) continue; origText.delete(m.target); textNode(m.target); }
          else if (m.type === "attributes") { var wa2 = wroteAttr.get(m.target); if (wa2 && wa2[m.attributeName] === m.target.getAttribute(m.attributeName)) continue; var s = origAttr.get(m.target); if (s) delete s[m.attributeName]; attrs(m.target); }
        }
      } finally { busy = false; }
    });
    observer.observe(document.body, { childList: true, subtree: true, characterData: true, attributes: true, attributeFilter: ATTRS });
  }

  function updateToggle() {
    var b = document.getElementById("lang-toggle");
    if (b) {
      b.textContent = lang === "en" ? "FR" : "EN";
      b.setAttribute("aria-label", lang === "en" ? "Passer en français" : "Switch to English");
      b.setAttribute("data-no-i18n", "1");
      b.title = lang === "en" ? "Français" : "English";
    }
  }

  function setLang(next) {
    lang = next === "en" ? "en" : "fr";
    try { localStorage.setItem("bk_lang", lang); } catch (e) {}
    applyAll();
    updateToggle();
    document.dispatchEvent(new CustomEvent("bk:lang", { detail: lang }));
  }

  function init() {
    dict = window.BK_EN || {};
    lang = detect();
    window.BK_LANG = function () { return lang; };
    window.bkTr = function (s) { if (lang !== "en") return s; var t = translate(s); return t === null ? s : t; };
    window.bkSetLang = setLang;
    var b = document.getElementById("lang-toggle");
    if (b) b.addEventListener("click", function () { setLang(lang === "en" ? "fr" : "en"); });
    startObserver();
    if (lang === "en") applyAll();
    updateToggle();
    if (lang === "en") document.dispatchEvent(new CustomEvent("bk:lang", { detail: lang }));
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
})();
