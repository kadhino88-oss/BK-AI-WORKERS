// Logique pure de dashboard/project_ui.js (bloc BK-PROJ-PURE) : aucun DOM, aucun reseau. Lancer : node tests/projects-ui/test_pure_logic.js
"use strict";
const fs = require("fs");
const path = require("path");
const assert = require("assert");
const src = fs.readFileSync(path.join(__dirname, "..", "..", "dashboard", "project_ui.js"), "utf8");
const m = /BK-PROJ-PURE-BEGIN[^\n]*\n([\s\S]*?)\/\/ BK-PROJ-PURE-END/.exec(src);
assert(m, "bloc BK-PROJ-PURE introuvable");
const names = [...m[1].matchAll(/^  (?:const|function) (pj\w+|PJ_\w+)/gm)].map((x) => x[1]);
const L = new Function(m[1] + "\nreturn {" + [...new Set(names)].join(",") + "};")();
let n = 0;
const t = (name, fn) => { try { fn(); n++; } catch (e) { console.error("ECHEC " + name + "\n  " + ((e && e.stack) || e)); process.exitCode = 1; } };

t("statuts: les 12 statuts du contrat ont un libelle", () => {
  ["PLANNING", "QUEUED", "RUNNING", "WAITING_APPROVAL", "WAITING_INPUT", "WAITING_QUOTA", "VERIFYING", "PAUSED", "BUDGET_REACHED", "DONE", "FAILED", "CANCELLED"]
    .forEach((s) => assert(L.PJ_STATUS[s] && L.PJ_STATUS[s].label, s));
});
t("etapes: les 8 statuts d'etape ont un libelle et une icone", () => {
  ["PENDING", "READY", "RUNNING", "DONE", "PARTIAL", "FAILED", "SKIPPED", "BLOCKED"].forEach((s) => assert(L.PJ_STEP_STATUS[s].label && L.PJ_STEP_STATUS[s].icon, s));
});
t("blocages: les 8 raisons du contrat sont expliquees", () => {
  ["APPROVAL", "INPUT", "QUOTA", "CONNECTOR", "INSTALLATION_PAUSED", "WORKER_NOT_INCLUDED", "DEPENDENCY_FAILED", "APPROVAL_EXPIRED"].forEach((s) => assert(L.PJ_BLOCKED_REASON[s], s));
});
t("approbations: les 9 statuts du contrat ont un libelle", () => {
  ["PENDING", "APPROVED", "EXECUTING", "EXECUTED", "FAILED", "UNKNOWN_CHECK_MANUALLY", "REJECTED", "EXPIRED", "SUPERSEDED"].forEach((s) => assert(L.PJ_APPROVAL_STATUS[s], s));
});
t("evenements: les 28 types du contrat ont une icone", () => {
  ["project_created", "plan_ready", "plan_approved", "plan_rejected", "status_changed", "step_started", "step_finished", "step_failed", "step_retry", "step_cost",
    "deliverable_added", "approval_created", "approval_decided", "approval_executed", "approval_failed", "input_requested", "message_received", "assistant_message",
    "quota_wait", "quota_resume", "budget_reached", "verification_started", "verification_result", "replan", "notification_sent", "done", "failed", "cancelled"]
    .forEach((s) => assert(L.PJ_EVENT_ICON[s], s));
});
t("etat: chaque etat qui attend le client dit quoi faire", () => {
  const act = (p) => L.pjStatusInfo(p);
  assert.strictEqual(act({ status: "WAITING_INPUT", waitingFor: "PLAN_VALIDATION" }).actionKind, "plan");
  assert.strictEqual(act({ status: "WAITING_INPUT", waitingFor: "CRITERIA_FAILED" }).actionKind, "criteria");
  assert.strictEqual(act({ status: "WAITING_INPUT", waitingFor: "CONNECTOR" }).actionKind, "connector");
  assert.strictEqual(act({ status: "WAITING_INPUT", waitingFor: "APPROVAL_EXPIRED" }).actionKind, "expired");
  assert.strictEqual(act({ status: "WAITING_INPUT", waitingFor: "INPUT" }).actionKind, "input");
  assert.strictEqual(act({ status: "WAITING_APPROVAL" }).actionKind, "approval");
  assert.strictEqual(act({ status: "WAITING_QUOTA" }).actionKind, "quota");
  assert.strictEqual(act({ status: "BUDGET_REACHED" }).actionKind, "budget");
  assert.strictEqual(act({ status: "PAUSED" }).actionKind, "resume");
  assert.strictEqual(act({ status: "PAUSED", statusReason: "OWNER_PAUSED" }).actionKind, null, "pause d'administration: le client ne peut pas reprendre");
  assert.strictEqual(act({ status: "FAILED" }).actionKind, "failed");
  assert(/Position 3/.test(act({ status: "QUEUED", queuePosition: 3 }).action));
  assert.strictEqual(act({ status: "RUNNING" }).actionKind, null);
  assert(act({ status: "WAITING_QUOTA" }).label.length > 3 && act({ status: "BUDGET_REACHED" }).tone === "act");
});
t("pastille: ne compte ni les termines ni les projets qui avancent seuls", () => {
  const list = [{ status: "WAITING_APPROVAL", approvalsPending: 3 }, { status: "WAITING_INPUT", waitingFor: "PLAN_VALIDATION" }, { status: "BUDGET_REACHED" },
    { status: "RUNNING" }, { status: "DONE", approvalsPending: 5 }, { status: "WAITING_QUOTA" }, { status: "WAITING_INPUT", waitingFor: "INPUT", inputsPending: 2 }];
  assert.strictEqual(L.pjBadgeCount(list), 3 + 1 + 1 + 2);
  assert.strictEqual(L.pjBadgeCount(null), 0);
});
t("interrogation: 3 s actif, 10 s en attente, 30 s masque, rien si termine (contrat 7.4)", () => {
  assert.strictEqual(L.pjPollDelay("RUNNING", false), 3000);
  assert.strictEqual(L.pjPollDelay("VERIFYING", false), 3000);
  assert.strictEqual(L.pjPollDelay("WAITING_QUOTA", false), 10000);
  assert.strictEqual(L.pjPollDelay("RUNNING", true), 30000);
  ["DONE", "FAILED", "CANCELLED"].forEach((s) => assert.strictEqual(L.pjPollDelay(s, false), 0));
});
t("adresse de fichier: segments encodes, jamais de .. ni de chemin absolu", () => {
  assert.strictEqual(L.pjFileUrl("PRJ-A", "site/dist/index.html"), "/api/projects/PRJ-A/files/site/dist/index.html");
  assert.strictEqual(L.pjFileUrl("PRJ-A", "../../etc/passwd"), "/api/projects/PRJ-A/files/etc/passwd");
  assert.strictEqual(L.pjFileUrl("PRJ-A", "/a b/c#d?.md"), "/api/projects/PRJ-A/files/a%20b/c%23d%3F.md");
  assert(!/\.\./.test(L.pjFileUrl("PRJ-A", "a/./../b")));
});
t("lots: regroupement par batchId, risque eleve exclu de l'approbation en lot, 50 au plus", () => {
  const items = [];
  for (let i = 0; i < 60; i++) items.push({ id: "APR-" + i, batchId: "B1", status: "PENDING", risk: "medium" });
  items.push({ id: "APR-H", batchId: "B1", status: "PENDING", risk: "high" }, { id: "APR-X", batchId: "B1", status: "EXECUTED", risk: "low" }, { id: "APR-S", status: "PENDING", risk: "low" });
  const g = L.pjGroupApprovals(items);
  assert.strictEqual(g.length, 2);
  assert.strictEqual(g[0].items.length, 62);
  assert.strictEqual(L.pjBatchIds(g[0], "approve").length, 50);
  assert(!L.pjBatchIds(g[0], "approve").includes("APR-H"));
  assert(!L.pjBatchIds(g[0], "approve").includes("APR-X"));
  assert.strictEqual(L.pjBatchIds(g[0], "reject", ["APR-H", "APR-1"]).join(), "APR-1,APR-H".split(",").sort((a, b) => (g[0].items.findIndex((i) => i.id === a) - g[0].items.findIndex((i) => i.id === b))).join(), "rejeter un risque eleve en lot reste permis");
  assert.deepStrictEqual(L.pjBatchIds({ items: [{ id: "a", status: "PENDING", risk: "low" }, { id: "b", status: "PENDING", risk: "low" }] }, "approve", ["b"]), ["b"]);
});
t("exemples: 3 au hasard au-dela de 10 actions, tout sinon", () => {
  const mk = (k) => ({ items: Array.from({ length: k }, (_, i) => ({ id: "x" + i })) });
  assert.strictEqual(L.pjSampleIds(mk(10), 3).length, 10);
  const s = L.pjSampleIds(mk(40), 3, () => 0.5);
  assert.strictEqual(s.length, 3);
  assert.strictEqual(new Set(s).size, 3);
});
t("champs modifiables: la valeur garde le type de l'original", () => {
  assert.deepStrictEqual(L.pjCoerceParam("a", "b"), { ok: true, value: "b" });
  assert.deepStrictEqual(L.pjCoerceParam(5, " 7,5 "), { ok: true, value: 7.5 });
  assert.strictEqual(L.pjCoerceParam(5, "abc").ok, false);
  assert.deepStrictEqual(L.pjCoerceParam(true, "Non"), { ok: true, value: false });
  assert.strictEqual(L.pjCoerceParam(true, "peut-etre").ok, false);
  assert.deepStrictEqual(L.pjCoerceParam({ a: 1 }, '{"a":2}'), { ok: true, value: { a: 2 } });
  assert.strictEqual(L.pjCoerceParam(["a"], "[").ok, false);
  assert.strictEqual(L.pjParamText({ a: 1 }), '{\n  "a": 1\n}');
  assert.strictEqual(L.pjParamText(null), "");
});
t("evenements: fusion sans doublon, recents d'abord, 300 au plus", () => {
  assert.deepStrictEqual(L.pjMergeEvents([{ seq: 1 }, { seq: 2 }], [{ seq: 2 }, { seq: 3 }]).map((e) => e.seq), [3, 2, 1]);
  const many = Array.from({ length: 400 }, (_, i) => ({ seq: i }));
  assert.strictEqual(L.pjMergeEvents([], many).length, 300);
  assert.strictEqual(L.pjMergeEvents([], many)[0].seq, 399);
});
t("rechargement du detail: seulement sur evenement utile ou changement d'etat", () => {
  assert.strictEqual(L.pjNeedsReload(null), false);
  assert.strictEqual(L.pjNeedsReload({ reset: true }), true);
  assert.strictEqual(L.pjNeedsReload({ status: "RUNNING", events: [{ type: "step_cost" }, { type: "notification_sent" }] }, { status: "RUNNING" }), false);
  assert.strictEqual(L.pjNeedsReload({ status: "RUNNING", events: [{ type: "deliverable_added" }] }, { status: "RUNNING" }), true);
  assert.strictEqual(L.pjNeedsReload({ status: "WAITING_QUOTA", events: [] }, { status: "RUNNING" }), true);
  assert.strictEqual(L.pjNeedsReload({ status: "RUNNING", approvalsPending: 2, events: [] }, { status: "RUNNING", approvalsPending: 0 }), true);
});
t("budget: utilise/plafond, niveaux d'alerte, plafond propose", () => {
  const b = L.pjBudget({ budget: { creditsCap: 100, creditsCharged: 85, costToFinishCredits: 40 } });
  assert.deepStrictEqual([b.cap, b.used, b.left, b.pct, b.level, b.toFinish], [100, 85, 15, 85, "warn", 40]);
  assert.strictEqual(L.pjBudget({ creditsCap: 50, creditsCharged: 50 }).level, "full");
  assert.strictEqual(L.pjBudget({ creditsCap: 0, creditsCharged: 3 }).pct, 0);
  assert.strictEqual(L.pjBudget({ budget: { creditsCap: 100, creditsCharged: 130 } }).pct, 100);
  assert.strictEqual(L.pjSuggestedCap({ budget: { creditsCap: 100, creditsCharged: 100, costToFinishCredits: 40 } }), 140);
  assert.strictEqual(L.pjSuggestedCap({ budget: { creditsCap: 100, creditsCharged: 100 } }), 106, "au moins minStartCredits (6) de plus");
});
t("lien des e-mails: #projet/PRJ-<32 hex majuscules> seulement", () => {
  const id = "PRJ-" + "0123456789ABCDEF".repeat(2);
  assert.deepStrictEqual(L.pjParseHash("#projet/" + id), { id });
  assert.deepStrictEqual(L.pjParseHash("#projets"), { id: null });
  assert.strictEqual(L.pjParseHash("#projet/PRJ-xyz"), null);
  assert.strictEqual(L.pjParseHash("#projet/" + id + "<script>"), null);
  assert.strictEqual(L.pjParseHash("#autre"), null);
});
t("objectif et fichiers: memes bornes que le serveur", () => {
  assert(L.pjGoalError("") && L.pjGoalError("court") && L.pjGoalError("x".repeat(4001)));
  assert.strictEqual(L.pjGoalError("Créer un site vitrine pour mon cabinet"), null);
  assert.strictEqual(L.pjInputsError([{ name: "a.pdf", size: 10 }]), null);
  assert(L.pjInputsError([{ name: "a.exe", size: 10 }]));
  assert(L.pjInputsError(Array.from({ length: 11 }, () => ({ name: "a.txt", size: 1 }))));
  assert(L.pjInputsError([{ name: "a.pdf", size: 7 * 1024 * 1024 }]));
});
t("etapes: celles du plan d'abord, systeme ensuite, les reponses jamais", () => {
  const rows = L.pjStepRows({ steps: [{ id: "S2", system: true, kind: "verify" }, { id: "S1" }, { id: "S3", system: true, kind: "answer" }, { id: "S4", system: true, kind: "fix" }] });
  assert.deepStrictEqual(rows.map((s) => s.id), ["S1", "S2", "S4"]);
  assert.deepStrictEqual(L.pjStepRows(null), []);
});
t("pourcentage borne, filtres de liste", () => {
  assert.strictEqual(L.pjPercent({ percent: 140 }), 100);
  assert.strictEqual(L.pjPercent({ percent: "x" }), 0);
  const list = [{ status: "DONE" }, { status: "RUNNING" }, { status: "WAITING_APPROVAL", approvalsPending: 1 }];
  assert.strictEqual(L.pjFilter(list, "todo").length, 1);
  assert.strictEqual(L.pjFilter(list, "active").length, 2);
  assert.strictEqual(L.pjFilter(list, "done").length, 1);
  assert.strictEqual(L.pjFilter(list, "all").length, 3);
});
console.log(process.exitCode ? "ECHEC" : "OK : " + n + " tests de logique pure");
