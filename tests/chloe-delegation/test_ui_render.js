// Interface du resultat d'une mission de Chloe (dashboard/app.js, bloc CHLOE-TEAM) : le VRAI code est extrait du fichier et execute dans un contexte vide avec un faux DOM.
//   node tests/chloe-delegation/test_ui_render.js
// Prouve : un seul Worker = l'affichage d'avant ; plusieurs Workers = une carte par Worker avec SES actions a valider et SES fichiers ; les Workers a embaucher ;
// la file d'attente et l'avancement ; et que rien de ce qu'un Worker ou le client ecrit n'entre dans la page sans etre echappe.
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const REPO = path.resolve(__dirname, "..", "..");
const src = fs.readFileSync(path.join(REPO, "dashboard", "app.js"), "utf8").split("\r\n").join("\n");

function sliceBetween(startMarker, endMarker) {
  const a = src.indexOf(startMarker);
  const b = src.indexOf(endMarker, a);
  assert(a >= 0 && b > a, "bloc introuvable : " + startMarker);
  return src.slice(a, b + endMarker.length);
}

function extractFunction(name) {
  const a = src.indexOf("function " + name + "(");
  assert(a >= 0, "fonction introuvable : " + name);
  let i = src.indexOf("{", a);
  let depth = 0;
  for (; i < src.length; i++) {
    if (src[i] === "{") depth++;
    else if (src[i] === "}") { depth--; if (depth === 0) return src.slice(a, i + 1); }
  }
  throw new Error("accolades non fermees : " + name);
}

// ---- faux DOM : assez pour lire ce que le code ecrit, rien de plus
class El {
  constructor(tag) { this.tagName = tag; this.children = []; this.className = ""; this._html = ""; this._text = ""; this.listeners = {}; this.open = false; this.type = ""; this.hidden = false; }
  set innerHTML(v) { this._html = String(v); this.children = []; }
  get innerHTML() { return this._html + this._text + this.children.map((c) => c.outer()).join(""); }
  set textContent(v) { this._text = String(v).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])); this._html = ""; this.children = []; }
  get textContent() { return this._text; }
  appendChild(c) { this.children.push(c); return c; }
  addEventListener(type, fn) { this.listeners[type] = fn; }
  click() { if (this.listeners.click) this.listeners.click(); }
  outer() { return `<${this.tagName} class="${this.className}">${this.innerHTML}</${this.tagName}>`; }
  find(pred, out = []) { if (pred(this)) out.push(this); this.children.forEach((c) => c.find(pred, out)); return out; }
  querySelector(sel) { return sel === ".task-loading-text" ? (this.loadingText || null) : null; }
}

function build() {
  const hired = [];
  const ctx = vm.createContext({
    document: { createElement: (tag) => new El(tag) },
    allWorkers: [{ id: "lea", portraitUrl: "/portraits/lea.jpg" }, { id: "emma", portraitUrl: "/portraits/emma.jpg" }],
    workerNameById: (id) => ({ clara: "Clara", seoya: "Séoya" }[id] || id),
    iwGoHire: (id) => hired.push(id),
    renderTaskFilesBlock: (taskId, files) => {
      if (!files || !files.length) return null;
      const el = new El("div"); el.className = "task-files"; el.taskId = taskId;
      el.innerHTML = files.map((f) => String(f.filename).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]))).join(",");
      return el;
    },
    renderPendingActionCard: (p) => { const el = new El("div"); el.className = "pending-card"; el.pending = p; el.innerHTML = "pending:" + p.operation; return el; },
  });
  const script = [extractFunction("escapeHtml"), extractFunction("renderAnswer"), sliceBetween("const CHLOE_STATUS_LABELS", "return CHLOE_STATUS_LABELS[status] || status;\n}"),
    sliceBetween("// ===== CHLOE-TEAM BEGIN", "// ===== CHLOE-TEAM END =====")].join("\n") +
    "\nthis.__api = { renderChloeResult, updateMissionProgress, chloeHireActions };";
  vm.runInContext(script, ctx);
  return { api: ctx.__api, hired };
}

let failures = 0;
function test(name, fn) {
  try { fn(); console.log("  PASS  " + name); } catch (e) { failures++; console.log("  FAIL  " + name + "\n        " + (e && e.message)); }
}
const section = (o) => Object.assign({ step: "T1", worker: "lea", workerName: "Lea", status: "DONE", statusLabel: "Terminé", objective: "Cree la charte.", answer: "Charte prete.", note: "", files: [], taskId: "TASK-" + "A".repeat(32), durationSec: 12 }, o);
const html = (el) => el.outer();

test("un seul Worker sans incident : l'affichage d'avant (statut, reponse, fichiers, carte de validation), aucune grille", () => {
  const { api } = build();
  const turn = new El("div"), resp = new El("div");
  api.renderChloeResult({ Status: "SUCCESS", SelectedWorkers: ["LEA"], FinalSynthesis: "Voici votre logo.", Sections: [section({})],
    Results: [{ Result: { TaskId: "TASK-" + "A".repeat(32), Files: [{ filename: "logo.svg" }] } }], pendingActions: [{ operation: "SEND", taskId: "TASK-" + "A".repeat(32) }] }, turn, resp, null);
  assert(resp.innerHTML.includes("Traité par : LEA"), resp.innerHTML);
  assert(resp.innerHTML.includes("Voici votre logo."));
  assert.strictEqual(turn.find((e) => e.className === "chloe-team").length, 0, "pas de grille pour un seul Worker");
  assert.strictEqual(turn.find((e) => e.className === "task-files").length, 1, "le bloc de fichiers est conserve");
  assert.strictEqual(turn.find((e) => e.className === "pending-card").length, 1, "la carte de validation est conservee");
});

test("plusieurs Workers : l'apercu de Chloe, puis une carte par Worker avec SES fichiers et SES actions a valider", () => {
  const { api } = build();
  const T1 = "TASK-" + "1".repeat(32), T2 = "TASK-" + "2".repeat(32), T3 = "TASK-" + "3".repeat(32);
  const turn = new El("div"), resp = new El("div");
  api.renderChloeResult({
    Status: "SUCCESS", SelectedWorkers: ["LEA", "EMMA", "LUCAS"], Overview: "**Chloé a réparti votre demande entre 3 Workers.**", FinalSynthesis: "texte complet",
    Sections: [section({ step: "T1", worker: "lea", workerName: "Lea", taskId: T1, files: [{ filename: "charte.md" }] }),
      section({ step: "T2", worker: "emma", workerName: "Emma", taskId: T2, objective: "Ecris les textes.", answer: "Textes prets." }),
      section({ step: "T3", worker: "lucas", workerName: "Lucas", taskId: T3, objective: "Construis la page.", answer: "Page prete." })],
    pendingActions: [{ operation: "DRAFT_POST", taskId: T2, workerId: "emma" }, { operation: "ORPHAN", taskId: "TASK-" + "9".repeat(32) }],
  }, turn, resp, null);
  assert(resp.innerHTML.includes("Traité par 3 Workers"));
  assert(resp.innerHTML.includes("<strong>Chloé a réparti votre demande entre 3 Workers.</strong>"), "l'apercu remplace le texte complet");
  assert(!resp.innerHTML.includes("texte complet"));
  const cards = turn.find((e) => /chloe-worker-card/.test(e.className));
  assert.strictEqual(cards.length, 3);
  assert(cards[0].innerHTML.includes("Lea") && cards[1].innerHTML.includes("Emma") && cards[2].innerHTML.includes("Lucas"));
  assert.strictEqual(cards[0].find((e) => e.className === "task-files").length, 1, "les fichiers de Lea sont sous Lea");
  assert.strictEqual(cards[1].find((e) => e.className === "task-files").length, 0);
  assert.strictEqual(cards[1].find((e) => e.className === "pending-card").length, 1, "la carte de validation d'Emma est sous Emma");
  assert.strictEqual(cards[0].find((e) => e.className === "pending-card").length, 0);
  assert.strictEqual(turn.children.filter((e) => e.className === "pending-card").length, 1, "une action sans Worker connu reste visible, jamais perdue");
  assert(cards[0].innerHTML.includes('src="/portraits/lea.jpg"'), "portrait du Worker");
});

test("un Worker en echec : sa carte le dit, les autres restent affichees, et l'entete compte ceux qui ont termine", () => {
  const { api } = build();
  const turn = new El("div"), resp = new El("div");
  api.renderChloeResult({
    Status: "PARTIAL_SUCCESS", SelectedWorkers: ["LEA", "LUCAS", "SEOYA"], Overview: "**Chloé a réparti.**\n\nNon réalisé : Lucas n'a pas abouti.", FinalSynthesis: "x",
    Sections: [section({}), section({ step: "T2", worker: "lucas", workerName: "Lucas", status: "FAILED", answer: null, note: "délai dépassé", taskId: "TASK-" + "B".repeat(32) }),
      section({ step: "T3", worker: "seoya", workerName: "Séoya", status: "BLOCKED", answer: null, note: "un résultat dont il dépendait manque", taskId: null })],
  }, turn, resp, null);
  assert(resp.innerHTML.includes("1 sur 3 Workers ont terminé"), resp.innerHTML);
  const cards = turn.find((e) => /chloe-worker-card/.test(e.className));
  assert(/chloe-worker-ok/.test(cards[0].className) && /chloe-worker-bad/.test(cards[1].className) && /chloe-worker-wait/.test(cards[2].className));
  assert(cards[1].innerHTML.includes("délai dépassé") && cards[2].innerHTML.includes("un résultat dont il dépendait manque"));
  assert(cards[1].innerHTML.includes("Échec") && cards[2].innerHTML.includes("Non lancé"));
});

test("les Workers hors forfait : un bouton « Embaucher X » par Worker (jamais Chloe), qui ferme le panneau puis ouvre l'embauche", () => {
  const { api, hired } = build();
  const turn = new El("div"), resp = new El("div");
  let closed = 0;
  api.renderChloeResult({ Status: "SUCCESS", SelectedWorkers: ["LEA"], FinalSynthesis: "ok", Sections: [section({}), section({ step: "T2", worker: "emma", workerName: "Emma" })],
    Overview: "ok", HireOffer: { workers: ["clara", "chloe", "seoya"] } }, turn, resp, () => closed++);
  const buttons = resp.find((e) => e.tagName === "button");
  assert.strictEqual(buttons.length, 2, "Clara et Seoya, pas Chloe");
  assert(buttons[0].innerHTML.includes("Embaucher") && buttons[0].innerHTML.includes("Clara"));
  buttons[1].click();
  assert.deepStrictEqual(hired, ["seoya"]);
  assert.strictEqual(closed, 1);
});

test("rien de ce qu'un Worker ou le client ecrit n'entre dans la page sans etre echappe", () => {
  const { api } = build();
  const evil = '<img src=x onerror=alert(1)><script>steal()</script>';
  const turn = new El("div"), resp = new El("div");
  api.renderChloeResult({
    Status: "PARTIAL_SUCCESS", SelectedWorkers: [evil], Overview: evil + "\n\n**gras**", FinalSynthesis: evil, HireOffer: { workers: [evil] },
    Sections: [section({ workerName: evil, worker: evil, step: evil, objective: evil, answer: "</div>" + evil, taskId: evil, statusLabel: evil, files: [{ filename: evil }] }),
      section({ step: "T2", worker: "emma", workerName: "Emma", status: "FAILED", note: evil, answer: null, statusLabel: evil })],
    Results: [], pendingActions: [],
  }, turn, resp, null);
  const all = html(resp) + html(turn);
  assert(!/<script/i.test(all), "aucune balise script");
  assert(!/<img src=x/i.test(all), "aucune balise img injectee");
  assert(!/onerror=alert/i.test(all.replace(/&lt;img src=x onerror=alert\(1\)&gt;/g, "")), "le gestionnaire d'evenement n'existe que sous forme de texte echappe");
  assert(all.includes("&lt;script&gt;steal()&lt;/script&gt;"), "le texte est visible, echappe");
});

test("une mission sans Worker (clarification, hors forfait) garde la ligne de statut lisible", () => {
  const { api } = build();
  const turn = new El("div"), resp = new El("div");
  api.renderChloeResult({ Status: "NO_WORKER_MATCHED", SelectedWorkers: [], FinalSynthesis: "Pouvez-vous reformuler ?", Sections: [], Results: [] }, turn, resp, null);
  assert(resp.innerHTML.includes("Clarification") && resp.innerHTML.includes("Pouvez-vous reformuler ?"));
  const r2 = new El("div");
  api.renderChloeResult({ Status: "WORKER_NOT_INCLUDED", SelectedWorkers: [], FinalSynthesis: "Cette demande relève de Clara.", HireOffer: { workers: ["clara"] }, Sections: [], Results: [] }, new El("div"), r2, null);
  assert(!r2.innerHTML.includes("WORKER_NOT_INCLUDED"), "pas de code technique affiche au client");
  assert(r2.find((e) => e.tagName === "button").length === 1);
});

test("l'attente : place dans la file quand le serveur est occupe, puis avancement Worker par Worker", () => {
  const { api } = build();
  const resp = new El("div"), text = new El("p");
  resp.loadingText = text;
  api.updateMissionProgress(resp, { status: "QUEUED", queuePosition: 3 });
  assert(text.textContent.includes("n°3"), text.textContent);
  api.updateMissionProgress(resp, { status: "QUEUED", queuePosition: 1 });
  assert(text.textContent.includes("démarre dès qu") && text.textContent.includes("se libère") && !text.textContent.includes("n°"));
  api.updateMissionProgress(resp, { status: "RUNNING", progress: { tasks: [{ worker: "lea", name: "Lea", status: "DONE" }, { worker: "emma", name: "Emma", status: "RUNNING" }, { worker: "lucas", name: "Lucas", status: "PENDING" }] } });
  assert(text.textContent.includes("Chloé coordonne") && text.textContent.includes("Lea ✓") && text.textContent.includes("Emma …") && text.textContent.includes("Lucas ·"), text.textContent);
  const single = new El("div"), singleText = new El("p");
  single.loadingText = singleText;
  api.updateMissionProgress(single, { status: "RUNNING", progress: { tasks: [{ worker: "lea", name: "Lea", status: "RUNNING" }] } });
  assert.strictEqual(singleText.textContent, "", "un seul Worker : le texte d'attente d'avant n'est pas remplace");
  api.updateMissionProgress(null, { status: "RUNNING" });
  api.updateMissionProgress(resp, null);
});

console.log(failures ? `\n${failures} ECHEC(S)` : "\nTOUT PASSE");
process.exit(failures ? 1 : 0);
