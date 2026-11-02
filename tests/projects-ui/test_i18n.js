// Chaque texte francais de dashboard/project_ui.js a sa traduction anglaise dans dashboard/i18n-en-projects.js.
// Lancer : node tests/projects-ui/test_i18n.js
"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const D = path.join(__dirname, "..", "..", "dashboard");
const src = fs.readFileSync(path.join(D, "project_ui.js"), "utf8");
const win = { BK_EN: {}, BK_EN_FRAG: [] };
const ctx = vm.createContext({ window: win });
["i18n-en.js", "i18n-en-app.js", "i18n-en-projects.js"].forEach((f) => vm.runInContext(fs.readFileSync(path.join(D, f), "utf8"), ctx, { filename: f }));
const dict = win.BK_EN;
const frag = win.BK_EN_FRAG;
const norm = (s) => String(s).replace(/\s+/g, " ").trim();

// Chaines francaises = chaines entre guillemets doubles ET texte statique des gabarits, hors code (selecteurs, expressions, identifiants).
const found = new Set();
for (const m of src.matchAll(/"((?:[^"\\\n]|\\.)*)"/g)) found.add(m[1]);
for (const m of src.matchAll(/`((?:[^`\\]|\\.)*)`/g)) m[1].replace(/\$\{(?:[^{}]|\{[^{}]*\})*\}/g, "\u0000").split(/<[^>]*>|\u0000/).forEach((x) => found.add(x));
const looksFrench = (s) => /[A-Za-zÀ-ÿ]{3}/.test(s) && (/[À-ÿ]/.test(s) || /\s/.test(s) || /^[A-Z][a-z]+$/.test(s))
  && !/\$\{|[{}]=|^[a-z0-9_.#\[\]=\-\/:,>"'*() ]+$|^(pj-|data-|btn|\/api|width:|button, |textarea, )|\.pj-|\[href\]/.test(s);
const IGNORE = new Set([
  "Home", "End", "Escape", "Tab", "Position", // noms de touches du clavier (code), « Position » : voir fragments
  "J'autorise",   // valeur de confirmation tapee, deja dans le dictionnaire (traduite a l'affichage)
]);
const need = [...found].map((s) => norm(s.replace(/\\"/g, '"').replace(/\\'/g, "'"))).filter((s) => s && looksFrench(s) && !IGNORE.has(s) && !/^[,;:)(.+ ]|[(]$|^return|\.join\(|s\.status ===/.test(s));

let bad = 0;
const covered = (s) => Object.prototype.hasOwnProperty.call(dict, s) || frag.some((f) => s.indexOf(f[0].trim()) !== -1);
const missing = need.filter((s) => !covered(s));
if (missing.length) { bad++; console.error("ECHEC textes sans traduction (" + missing.length + ") :\n  " + missing.join("\n  ")); }

// Pas de traduction vide, pas d'accolade perdue ou ajoutee, pas de francais residuel evident dans les valeurs.
for (const [k, v] of Object.entries(dict)) {
  if (!Object.prototype.hasOwnProperty.call(dict, k) || typeof v !== "string") continue;
  const ph = (s) => (s.match(/\{\w+\}/g) || []).sort().join();
  if (/^[^]*\{\w+\}/.test(k) && ph(k) !== ph(v)) { bad++; console.error("ECHEC valeurs inserees differentes : " + k + " -> " + v); }
}
const mine = Object.keys(dict).filter((k) => fs.readFileSync(path.join(D, "i18n-en-projects.js"), "utf8").indexOf(JSON.stringify(k).slice(1, -1)) !== -1);
const empty = mine.filter((k) => !norm(dict[k]));
if (empty.length) { bad++; console.error("ECHEC traductions vides : " + empty.join(" | ")); }
const sameAsFr = mine.filter((k) => dict[k] === k && k.length > 12);
if (sameAsFr.length) { bad++; console.error("ECHEC traduction identique au francais : " + sameAsFr.join(" | ")); }
// Les chaines a texte insere doivent rester detectables par le moteur (cle exacte ou fragment).
if (!frag.some((f) => f[0].indexOf("L'objectif est trop long") === 0)) { bad++; console.error("ECHEC fragment objectif trop long absent"); }

console.log(bad ? "ECHEC" : "OK : " + need.length + " textes francais couverts par la traduction anglaise");
process.exitCode = bad ? 1 : 0;
