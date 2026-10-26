// Tests de l'interface « moteur d'IA » (dashboard/app.js) : etiquette sous la reponse, ligne pres de la zone de mission, detail des limites.
//   node tests/providers/test_engine_ui.js
// Les fonctions sont extraites du VRAI fichier et executees dans un contexte avec un faux document : aucune page, aucun reseau, aucun serveur.
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const src = fs.readFileSync(path.resolve(__dirname, "..", "..", "dashboard", "app.js"), "utf8").split("\r\n").join("\n");   // CRLF ou LF selon la machine

function extract(header) {
  const start = src.indexOf(header);
  assert(start >= 0, header + " introuvable dans dashboard/app.js");
  const end = src.indexOf("\n}\n", start);
  assert(end > start, "fin de " + header + " introuvable");
  return src.slice(start, end + 3);
}

function makeDocument() {
  const els = {};
  const get = (id) => (els[id] = els[id] || { id, hidden: false, textContent: "", innerHTML: "", attrs: {}, setAttribute(k, v) { this.attrs[k] = v; } });
  return { getElementById: get, els };
}

function load(fetchImpl) {
  const doc = makeDocument();
  const ctx = vm.createContext({ document: doc, fetchJson: fetchImpl, currentMissionLevel: () => "rapide", encodeURIComponent, String, Array, JSON });
  const code = [extract("function escapeHtml"), extract("function engineTagHtml"), extract("function engineLimitsHtml"), extract("async function loadEngineLine")].join("\n");
  vm.runInContext(code + "\nthis.__api = { escapeHtml, engineTagHtml, engineLimitsHtml, loadEngineLine };", ctx);
  return { api: ctx.__api, doc };
}

let failures = 0;
async function test(name, fn) {
  try { await fn(); console.log("  PASS  " + name); } catch (e) { failures++; console.log("  FAIL  " + name + "\n        " + (e && e.message)); }
}

(async () => {
  const { api } = load(async () => ({}));

  await test("etiquette d'un moteur qui a repondu : « Moteur : ... », sans classe de repli", () => {
    const h = api.engineTagHtml({ label: "Claude", failedOver: false });
    assert(h.includes("Moteur : Claude"), h);
    assert(!h.includes("is-failover"), h);
  });

  await test("un repli est dit comme tel et mis en evidence", () => {
    const h = api.engineTagHtml({ label: "Moteur local (Llama 3)", failedOver: true });
    assert(h.includes("Réponse du moteur de remplacement : Moteur local (Llama 3)"), h);
    assert(h.includes("is-failover"), h);
  });

  await test("sans moteur connu (aucun plan actif) : rien n'est affiche", () => {
    assert.strictEqual(api.engineTagHtml(null), "");
    assert.strictEqual(api.engineTagHtml({}), "");
    assert.strictEqual(api.engineTagHtml({ provider: "ollama" }), "");
  });

  await test("un libelle hostile est echappe (jamais de balise dans la page)", () => {
    const h = api.engineTagHtml({ label: '<img src=x onerror=alert(1)>"', failedOver: true });
    assert(!h.includes("<img"), h);
    assert(h.includes("&lt;img"), h);
  });

  await test("les limites sont listees en francais simple et echappees", () => {
    const h = api.engineLimitsHtml({ capabilities: { limitsFr: ["recherche web", "fichiers Office (Excel, Word, PowerPoint, PDF)"], webFetchNote: "Lecture de pages en https seulement.", languageNote: "<b>plus simple</b>" }, failoverNote: "Si indisponible : Claude." });
    assert(h.includes("Ne sait pas faire : recherche web, fichiers Office"), h);
    assert(h.includes("https seulement"), h);
    assert(!h.includes("<b>"), "balisage echappe : " + h);
    assert(h.includes("Si indisponible"), h);
  });

  await test("un moteur sans limite (Claude) n'affiche aucun detail", () => {
    assert.strictEqual(api.engineLimitsHtml({ capabilities: { limitsFr: [], webFetchNote: null, languageNote: null } }), "");
    assert.strictEqual(api.engineLimitsHtml({ capabilities: null }), "");
    assert.strictEqual(api.engineLimitsHtml(null), "");
  });

  await test("la ligne pres de la zone de mission montre le resume du serveur et le bouton « Ce que ce moteur sait faire »", async () => {
    const calls = [];
    const { api: a, doc } = load(async (url) => {
      calls.push(url);
      return { summary: "Moteur local (Llama 3) : réponses plus simples, pas de recherche web ni de fichiers Office", capabilities: { limitsFr: ["recherche web", "fichiers Office (Excel, Word, PowerPoint, PDF)"] } };
    });
    await a.loadEngineLine();
    assert.deepStrictEqual(calls, ["/api/engine?level=rapide"]);
    assert.strictEqual(doc.els["engine-line"].hidden, false);
    assert(doc.els["engine-line-text"].textContent.startsWith("Moteur local (Llama 3)"));
    assert.strictEqual(doc.els["engine-more-btn"].hidden, false);
    assert.strictEqual(doc.els["engine-details"].hidden, true, "le detail est replie au depart");
    doc.els["engine-more-btn"].onclick();
    assert.strictEqual(doc.els["engine-details"].hidden, false);
    assert.strictEqual(doc.els["engine-more-btn"].attrs["aria-expanded"], "true");
  });

  await test("Claude sans limite : la ligne dit « Moteur : Claude » et n'offre pas de detail", async () => {
    const { api: a, doc } = load(async () => ({ summary: "Moteur : Claude", capabilities: { limitsFr: [], webFetchNote: null, languageNote: null } }));
    await a.loadEngineLine();
    assert.strictEqual(doc.els["engine-line-text"].textContent, "Moteur : Claude");
    assert.strictEqual(doc.els["engine-more-btn"].hidden, true);
  });

  await test("serveur en erreur ou compte sans session : la ligne reste cachee (jamais un faux « Moteur : Claude »)", async () => {
    for (const reply of [{ error: "ACCOUNT_REQUIRED" }, null, {}]) {
      const { api: a, doc } = load(async () => reply);
      await a.loadEngineLine();
      assert.strictEqual(doc.els["engine-line"].hidden, true, JSON.stringify(reply));
    }
    const { api: b, doc: d2 } = load(async () => { throw new Error("réseau"); });
    await b.loadEngineLine();
    assert.strictEqual(d2.els["engine-line"].hidden, true);
  });

  console.log(failures ? "\n" + failures + " ECHEC(S)" : "\nTOUT PASSE");
  process.exit(failures ? 1 : 0);
})();
