// Contrat de charge utile : ce que l'interface LIT dans les reponses de l'API des projets existe, avec le bon type, dans les reponses REELLES du
// moteur (tests/projects-ui/fixtures/real-*.json, captees par capture_fixtures.py sur un vrai serveur) ; chaque statut, type d'evenement et statut
// d'etape rencontre a un libelle. Lancer : node tests/projects-ui/test_contract.js
"use strict";
const fs = require("fs");
const path = require("path");
const assert = require("assert");
const FIX = path.join(__dirname, "fixtures");
const src = fs.readFileSync(path.join(__dirname, "..", "..", "dashboard", "project_ui.js"), "utf8");
const m = /BK-PROJ-PURE-BEGIN[^\n]*\n([\s\S]*?)\/\/ BK-PROJ-PURE-END/.exec(src);
const names = [...m[1].matchAll(/^  (?:const|function) (pj\w+|PJ_\w+)/gm)].map((x) => x[1]);
const L = new Function(m[1] + "\nreturn {" + [...new Set(names)].join(",") + "};")();
const load = (f) => JSON.parse(fs.readFileSync(path.join(FIX, f), "utf8"));
const files = fs.readdirSync(FIX);
let n = 0;
const t = (name, fn) => { try { fn(); n++; } catch (e) { console.error("ECHEC " + name + "\n  " + ((e && e.message) || e)); process.exitCode = 1; } };
const has = (o, k, type) => { assert(o && Object.prototype.hasOwnProperty.call(o, k), "champ absent : " + k); if (type) assert(type === "array" ? Array.isArray(o[k]) : typeof o[k] === type, k + " devrait etre " + type + " (" + typeof o[k] + ")"); };
const details = files.filter((f) => /^real-.*-detail\.json$/.test(f));
t("des fixtures reelles existent (une par etat)", () => { assert(details.length >= 4, "fixtures : " + details.length + " (lancer capture_fixtures.py)"); });

details.forEach((f) => t("detail " + f, () => {
  const d = load(f);
  ["projectId", "title", "goal", "status"].forEach((k) => has(d, k, "string"));
  ["percent", "creditsCharged", "creditsCap", "approvalsPending"].forEach((k) => has(d, k, "number"));
  has(d, "plan"); has(d, "budget", "object"); has(d, "usage", "object"); has(d, "capabilities", "object"); has(d, "deliverables", "array"); has(d, "workers", "array"); has(d, "questions", "array"); has(d, "events", "array");
  ["canPause", "canResume", "canCancel", "canApprove", "canRaiseBudget", "canMessage"].forEach((k) => has(d.capabilities, k, "boolean"));
  has(d.budget, "creditsCap", "number"); has(d.budget, "creditsCharged", "number");
  assert(L.PJ_STATUS[d.status], "statut sans libelle : " + d.status);
  const plan = d.plan || {};
  (plan.criteria || []).forEach((c) => { has(c, "id", "string"); has(c, "text", "string"); has(c, "kind", "string"); if (c.verdict) assert(L.PJ_VERDICT[c.verdict], "verdict inconnu " + c.verdict); });
  (plan.steps || []).forEach((s) => {
    ["id", "title", "worker", "status"].forEach((k) => has(s, k, "string")); has(s, "dependsOn", "array"); has(s, "kind", "string");
    assert(L.PJ_STEP_STATUS[s.status], "statut d'etape sans libelle : " + s.status);
    if (s.blockedReason) assert(L.PJ_BLOCKED_REASON[s.blockedReason], "raison de blocage sans texte : " + s.blockedReason);
  });
  d.workers.forEach((w) => { ["id", "name", "status"].forEach((k) => has(w, k, "string")); ["stepsDone", "stepsTotal", "creditsUsed"].forEach((k) => has(w, k, "number")); });
  d.deliverables.forEach((x) => { has(x, "path", "string"); has(x, "title", "string"); assert(!/\.\.|^\//.test(x.path), "chemin de livrable suspect " + x.path); });
  d.events.forEach((e) => { has(e, "seq", "number"); has(e, "type", "string"); has(e, "ts", "string"); assert(L.PJ_EVENT_ICON[e.type], "type d'evenement sans icone : " + e.type); });
  // l'etat doit dire quoi faire si le client est attendu
  const info = L.pjStatusInfo(d);
  assert(info.label && info.tone, "libelle/ton");
}));

files.filter((f) => /^real-.*-progress\.json$/.test(f)).forEach((f) => t("progression " + f, () => {
  const p = load(f);
  has(p, "seq", "number"); has(p, "status", "string"); has(p, "events", "array"); has(p, "percent", "number");
  assert(L.PJ_STATUS[p.status]);
  p.events.forEach((e) => assert(L.PJ_EVENT_ICON[e.type], "type d'evenement inconnu : " + e.type));
  assert(!/file_[A-Za-z0-9]{6}|container_|sk-ant-/.test(JSON.stringify(p)), "identifiant du fournisseur d'IA ou secret dans la progression");
}));

files.filter((f) => /^real-.*-approvals\.json$/.test(f)).forEach((f) => t("validations " + f, () => {
  const a = load(f);
  if (!a.approvals) return;     // projet sans validation : reponse minimale
  has(a, "approvals", "array");
  a.approvals.forEach((it) => {
    ["id", "batchId", "status", "risk", "operation"].forEach((k) => it.kind === "manual_action" && ["operation"].includes(k) ? 0 : has(it, k));
    has(it, "display", "object"); has(it.display, "title", "string"); has(it, "params", "object"); has(it, "expiresUtc", "string");
    assert(L.PJ_APPROVAL_STATUS[it.status], "statut de validation sans libelle : " + it.status);
    assert(L.PJ_RISK[it.risk], "risque inconnu : " + it.risk);
    assert(it.recipients === null || typeof it.recipients === "number" || Array.isArray(it.recipients), "recipients : nombre, liste ou null (" + typeof it.recipients + ")");
  });
}));

t("liste", () => {
  const l = load("list.json");
  has(l, "projects", "array");
  l.projects.forEach((p) => { ["projectId", "title", "goal", "status"].forEach((k) => has(p, k, "string")); ["percent", "creditsCharged", "creditsCap"].forEach((k) => has(p, k, "number")); has(p, "workers", "array"); assert(!("plan" in p), "la liste ne doit pas porter le plan"); });
  assert(L.pjBadgeCount(l.projects) >= 0);
});

t("usage : les champs lus par la colonne de budget", () => {
  const u = load("usage.json");
  has(u, "ok"); has(u, "binding"); has(u, "allowedNow", "number"); has(u, "session", "object"); has(u, "week", "object"); has(u, "month", "object"); has(u, "upgrade", "object");
  ["limit", "used", "remaining"].forEach((k) => has(u.session, k, "number"));
  has(u, "enforced", "boolean"); has(u, "windowsApply", "boolean");
});

t("detail : l'usage d'un projet porte le mois (affiche quand session/semaine ne s'appliquent pas)", () => {
  const d = load(details[0]);
  has(d.usage, "month", "object"); has(d.usage.month, "remaining", "number"); has(d.usage.month, "resetsAtUtc", "string");
});

t("aucun identifiant de client ni adresse reelle dans les fixtures", () => {
  files.forEach((f) => { const s = fs.readFileSync(path.join(FIX, f), "utf8"); assert(!/CLI-CUST-|@mail-test\.example|[A-Za-z0-9]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}/.test(s), f); });
});
console.log(process.exitCode ? "ECHEC" : "OK : " + n + " verifications du contrat de charge utile (" + details.length + " etats reels)");
