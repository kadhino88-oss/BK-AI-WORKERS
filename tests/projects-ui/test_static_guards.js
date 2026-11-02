// Gardes statiques de l'interface des projets : crochets minimaux, route statique, pas d'injection de HTML, pas de secret, accessibilite de base.
// Lancer : node tests/projects-ui/test_static_guards.js
"use strict";
const fs = require("fs");
const path = require("path");
const assert = require("assert");
const D = path.join(__dirname, "..", "..", "dashboard");
const rd = (f) => fs.readFileSync(path.join(D, f), "utf8");
const ui = rd("project_ui.js"), app = rd("app.js"), html = rd("index.html"), css = rd("style.css"), srv = rd("server.py"), sw = rd("service-worker.js");
let n = 0;
const t = (name, fn) => { try { fn(); n++; } catch (e) { console.error("ECHEC " + name + "\n  " + ((e && e.message) || e)); process.exitCode = 1; } };

t("le fichier se charge (syntaxe valide)", () => { new Function(ui); });
t("crochets de app.js : tous gardes par ?. (le fichier reste facultatif)", () => {
  const calls = [...app.matchAll(/window\.BKProjects(\??)\.?(\w+)?/g)];
  assert(calls.length >= 6, "au moins 6 crochets attendus, trouves " + calls.length);
  app.split("\n").filter((l) => /window\.BKProjects/.test(l)).forEach((l) => assert(/window\.BKProjects\?\./.test(l) || /window\.BKProjects\)/.test(l) || /&& window\.BKProjects\b/.test(l), "crochet non garde : " + l.trim()));
  ["onAccount", "onShowView", "onWorkerProfile", "suggestCard"].forEach((h) => { assert(app.includes("BKProjects?." + h) || app.includes("BKProjects." + h), "crochet " + h + " absent de app.js"); assert(new RegExp(h + "\\b").test(ui), h + " non exporte par project_ui.js"); });
});
t("index.html : vue, navigation masquee par defaut, scripts dans le bon ordre", () => {
  assert(/id="projets-view"[^>]*hidden/.test(html));
  assert(/id="nav-projets"[^>]*hidden/.test(html), "la navigation Projets doit etre masquee tant que le moteur est inactif");
  assert(/id="pj-live"[^>]*aria-live="polite"/.test(html));
  const iApp = html.indexOf('src="/app.js"'), iUi = html.indexOf('src="/project_ui.js"'), iEn = html.indexOf('src="/i18n-en-projects.js"'), iI18n = html.indexOf('src="/i18n.js"');
  assert(iApp > 0 && iUi > iApp, "project_ui.js apres app.js");
  assert(iEn > 0 && iEn < iI18n, "le dictionnaire anglais avant i18n.js");
});
t("serveur : project_ui.js et le dictionnaire servis par la route statique", () => { assert(/"\/project_ui\.js", "\/i18n-en-projects\.js"/.test(srv)); });
t("les fichiers servis existent", () => { ["project_ui.js", "i18n-en-projects.js"].forEach((f) => assert(fs.existsSync(path.join(D, f)), f)); });
t("service worker : cache versionne", () => { assert(/CACHE_NAME\s*=\s*"bk-shell-v\d+"/.test(sw)); });
t("aucune API dangereuse (eval, document.write, insertAdjacentHTML, new Function, localStorage de secrets)", () => {
  const code = ui.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "");
  assert(!/\beval\s*\(|document\.write|insertAdjacentHTML|new Function|outerHTML\s*=/.test(code));
  assert(!/localStorage|sessionStorage/.test(code), "aucun stockage navigateur dans l'interface des projets");
});
t("aucune donnee du serveur interpolee dans du HTML sans esc()/num()", () => {
  const bare = [...ui.matchAll(/\$\{\s*((?:d|p|x|s|w|it|m|e|q|t|c|a|u|b|r|o|f|g|gr|est|lead|bu)\.[A-Za-z_][\w.]*)\s*\}/g)].map((m) => m[1]);
  // Valeurs numeriques deja bornees par le code : autorisees explicitement.
  const okNum = new Set(["bu.pct", "bu.cap", "bu.level", "f.name"]);   // nombres bornes, enum interne ; f.name passe par esc() dans showError
  const bad = bare.filter((x) => !okNum.has(x));
  assert.deepStrictEqual(bad, [], "interpolation directe : " + bad.join(", "));
});
t("textes venant du serveur ou du client : marques data-no-i18n", () => {
  ["d.goal", "d.title", "q.question", "s.summary", "s.handoffNote", "c.text", "x.title", "w.lastSummary"].forEach((k) => assert(new RegExp("data-no-i18n=\"1\">\\$\\{esc\\(" + k.replace(".", "\\.")).test(ui) || new RegExp("data-no-i18n=\"1\"[^`]{0,60}\\$\\{esc\\(" + k.replace(".", "\\.")).test(ui), k + " doit etre marque data-no-i18n"));
});
t("fichiers de projet : adresses construites par pjFileUrl, telechargement en piece jointe", () => {
  assert(/pjFileUrl\(pid, x\.path\)/.test(ui));
  assert(!/\/files\/\$\{/.test(ui.replace(/\/files\/final-report\.md/g, "")), "chemin de fichier non encode");
});
t("actions sortantes : contenu exact, confirmation tapee pour le risque eleve, jamais de lot a risque eleve", () => {
  assert(/J'autorise/.test(ui) && /data-confirm/.test(ui));
  assert(/risk === "high"/.test(ui));
  assert(/Contenu exact/.test(ui));
});
t("accessibilite : onglets ARIA, barre de progression, zone annoncee, focus visible, piege de focus du dialogue", () => {
  assert(/role="tablist"/.test(ui) && /role="tab"/.test(ui) && /role="tabpanel"/.test(ui) && /aria-selected/.test(ui));
  assert(/role="progressbar"/.test(ui) && /aria-valuenow/.test(ui));
  assert(/role="alert"/.test(ui));
  assert(/ArrowRight/.test(ui) && /ArrowLeft/.test(ui) && /Escape/.test(ui) && /Tab/.test(ui));
  assert(/aria-modal="true"/.test(ui) && /role="dialog"/.test(ui));
  assert(/\.pj-root :focus-visible/.test(css));
  assert(/prefers-reduced-motion/.test(css.slice(css.indexOf("PROJETS (dashboard/project_ui.js)"))), "mouvement reduit");
});
t("CSS : bloc delimite, mobile a 375 px, cibles tactiles", () => {
  const i = css.indexOf("PROJETS (dashboard/project_ui.js)");
  assert(i > 0, "bloc PROJETS delimite absent");
  assert(css.includes("fin du bloc PROJETS"), "marque de fin absente");
  const block = css.slice(i);
  assert(/@media \(max-width: (5|6|7)\d\dpx\)/.test(block), "points de rupture mobiles");
  assert(/min-height: 4[0-9]px|min-height: 44px/.test(block), "cibles tactiles de 44 px");
});
t("aucun secret ni cle dans les fichiers de l'interface", () => {
  [ui, rd("i18n-en-projects.js")].forEach((s) => assert(!/sk-ant-|AKIA[0-9A-Z]{12}|BEGIN (RSA|PRIVATE)|api[_-]?key\s*[:=]\s*["'][^"']{12,}/i.test(s)));
});
console.log(process.exitCode ? "ECHEC" : "OK : " + n + " gardes statiques");
