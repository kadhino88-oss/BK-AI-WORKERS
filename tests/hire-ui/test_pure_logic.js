// Tests de la logique pure de l'assistant d'installation (dashboard/app.js, entre BK-PURE-BEGIN et BK-PURE-END) : aucun DOM, aucun reseau.
//   node tests/hire-ui/test_pure_logic.js
// Les fonctions sont extraites du vrai fichier et executees telles quelles dans un contexte vide : un renommage ou une regle cassee se voit ici.
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const REPO = path.resolve(__dirname, "..", "..");
const src = fs.readFileSync(path.join(REPO, "dashboard", "app.js"), "utf8");
const a = src.indexOf("// BK-PURE-BEGIN");
const b = src.indexOf("// BK-PURE-END");
assert(a > 0 && b > a, "bloc BK-PURE introuvable dans dashboard/app.js");
const names = ["IW_MODES", "IW_RISK", "IW_CHANNEL_LABELS", "IW_STEP_LABELS", "IW_STATUS_LABELS", "IW_FIELD_MAX", "iwModesFor", "iwDefaultMode", "iwInitialState",
  "iwEnabledDefs", "iwLiveChannelsOf", "iwChannelChips", "iwBuildPayload", "iwMissing", "iwToolsOf", "iwAutonomySummary", "iwFriendlyError", "iwParseErrors"];
const ctx = vm.createContext({});
vm.runInContext(src.slice(a, b) + "\nthis.__api = {" + names.join(",") + "};", ctx);
const api = ctx.__api;

let failures = 0;
function test(name, fn) {
  try { fn(); console.log("  PASS  " + name); } catch (e) { failures++; console.log("  FAIL  " + name + "\n        " + (e && e.message)); }
}
const json = (x) => JSON.parse(JSON.stringify(x));      // sort du contexte vm : objets comparables par assert.deepStrictEqual

const profile = {
  channelSupport: { email: "planned", phone: "planned", whatsapp: "no", web: "available", schedule: "available" },
  services: [
    {
      id: "prospection", label: "Prospection", channels: ["web", "schedule", "email", "phone"],
      knowledgeFields: [{ key: "site_web", label: "Site", required: true }, { key: "zone", label: "Zone", required: true }, { key: "ton", label: "Ton", required: false }],
      autonomyRules: [
        { category: "lecture", label: "Lire", risk: "low", defaultMode: "auto" },
        { category: "brouillon", label: "Brouillon", risk: "low", defaultMode: "draft" },
        { category: "envoi", label: "Envoyer", risk: "high", defaultMode: "off" },
        { category: "crm", label: "Ecrire dans le CRM", risk: "medium", defaultMode: "ask" },
        { category: "incoherent", label: "Profil incoherent", risk: "high", defaultMode: "auto" },
      ],
      requiredConnectors: ["hubspot.controlled"], requiredAnyOf: [["gmail.controlled", "outlook_mail.controlled"]], optionalConnectors: ["calendar.controlled"],
    },
    { id: "prevision", label: "Prevision", channels: ["web"], knowledgeFields: [{ key: "objectif", label: "Objectif", required: false }], autonomyRules: [], requiredConnectors: [], requiredAnyOf: [], optionalConnectors: [] },
  ],
};
const live = ["web", "schedule"];

test("autonome n'est propose que pour une action de risque faible", () => {
  const ids = (risk) => json(api.iwModesFor({ risk }).map((m) => m.id));
  assert.deepStrictEqual(ids("low"), ["off", "ask", "draft", "auto"]);
  assert.deepStrictEqual(ids("medium"), ["off", "ask", "draft"]);
  assert.deepStrictEqual(ids("high"), ["off", "ask", "draft"]);
  assert.deepStrictEqual(ids(undefined), ["off", "ask", "draft"]);
  assert.deepStrictEqual(ids("LOW"), ["off", "ask", "draft"], "pas de tolerance sur la casse : le serveur compare avec 'low'");
});

test("le mode par defaut d'un profil incoherent (auto sur risque eleve) n'est jamais auto", () => {
  assert.strictEqual(api.iwDefaultMode({ risk: "high", defaultMode: "auto" }), "ask");
  assert.strictEqual(api.iwDefaultMode({ risk: "low", defaultMode: "auto" }), "auto");
  assert.strictEqual(api.iwDefaultMode({ risk: "low", defaultMode: "nimporte" }), "ask");
});

test("etat initial : aucun service coche, reglages par defaut, rien d'invente", () => {
  const s = json(api.iwInitialState(profile, null));
  assert.strictEqual(s.services.prospection.enabled, false);
  assert.deepStrictEqual(s.services.prospection.autonomy, { lecture: "auto", brouillon: "draft", envoi: "off", crm: "ask", incoherent: "ask" });
  assert.deepStrictEqual(s.services.prospection.knowledge, { site_web: "", zone: "", ton: "" });
  assert.strictEqual(s.notes, "");
});

test("etat initial depuis une fiche enregistree : texte repris, mode 'auto' illegal remplace", () => {
  const saved = { notes: "a savoir", services: { prospection: { enabled: true, level: "equilibre", knowledge: { site_web: "https://x.example", inconnu: "zzz" }, autonomy: { lecture: "off", envoi: "auto" } } } };
  const s = json(api.iwInitialState(profile, saved));
  assert.strictEqual(s.services.prospection.enabled, true);
  assert.strictEqual(s.services.prospection.knowledge.site_web, "https://x.example");
  assert.strictEqual("inconnu" in s.services.prospection.knowledge, false);
  assert.strictEqual(s.services.prospection.autonomy.lecture, "off");
  assert.strictEqual(s.services.prospection.autonomy.envoi, "off", "auto sur envoi (risque eleve) n'est pas repris");
  assert.strictEqual(s.services.prospection.level, "equilibre");
  assert.strictEqual(s.notes, "a savoir");
});

test("charge utile : seuls les services coches ou renseignes, canaux reellement disponibles, jamais auto hors risque faible", () => {
  const st = api.iwInitialState(profile, null);
  st.services.prospection.enabled = true;
  st.services.prospection.knowledge.site_web = "  https://x.example  ";
  st.services.prospection.autonomy.envoi = "auto";           // saisie illegale (ne peut venir que d'un etat corrompu)
  st.notes = " consignes ";
  const p = json(api.iwBuildPayload("alex", profile, st, live));
  assert.strictEqual(p.workerId, "alex");
  assert.deepStrictEqual(Object.keys(p.services), ["prospection"], "le service non coche et vide n'est pas envoye");
  const s = p.services.prospection;
  assert.strictEqual(s.enabled, true);
  assert.deepStrictEqual(s.knowledge, { site_web: "https://x.example" }, "texte rogne, champs vides omis");
  assert.deepStrictEqual(s.channels, ["web", "schedule"], "e-mail et telephone (prevus) ne sont jamais envoyes");
  assert.strictEqual(s.autonomy.envoi, "off");
  assert.strictEqual(s.autonomy.lecture, "auto");
  assert.strictEqual(p.notes, "consignes");
  assert.strictEqual("level" in s, false, "aucun niveau n'est impose sans choix explicite");
});

test("charge utile : un service decoche mais renseigne est conserve (rien n'est perdu)", () => {
  const st = api.iwInitialState(profile, null);
  st.services.prevision.knowledge.objectif = "CA +10 %";
  const p = json(api.iwBuildPayload("alex", profile, st, live));
  assert.strictEqual(p.services.prevision.enabled, false);
  assert.strictEqual(p.services.prevision.knowledge.objectif, "CA +10 %");
});

test("canaux : le profil ne montre jamais un canal exclu ('no'), les canaux prevus sont 'bientot'", () => {
  const chips = json(api.iwChannelChips(profile.services[0], profile, live));
  const by = Object.fromEntries(chips.map((c) => [c.id, c]));
  assert.strictEqual(by.web.soon, false);
  assert.strictEqual(by.schedule.soon, false);
  assert.strictEqual(by.email.soon, true);
  assert.strictEqual(by.phone.soon, true);
  const noWa = json(api.iwChannelChips({ channels: ["whatsapp", "web"] }, profile, live));
  assert.deepStrictEqual(noWa.map((c) => c.id), ["web"], "whatsapp = 'no' dans le profil : jamais affiche");
  // 'available' dans le profil mais absent de liveChannels (le serveur fait foi) : presente comme « bientot »
  const notLive = json(api.iwChannelChips({ channels: ["web"] }, profile, []));
  assert.strictEqual(notLive[0].soon, true);
});

test("ce qui manque pour activer : service, champs obligatoires, outils obligatoires", () => {
  const st = api.iwInitialState(profile, null);
  assert.deepStrictEqual(json(api.iwMissing(profile, st, {})).map((m) => m.kind), ["service"]);
  st.services.prospection.enabled = true;
  let m = json(api.iwMissing(profile, st, { "hubspot.controlled": true, "gmail.controlled": true, "outlook_mail.controlled": false }));
  assert.deepStrictEqual(m.map((x) => x.what), ["Site", "Zone"]);
  st.services.prospection.knowledge.site_web = "x";
  st.services.prospection.knowledge.zone = "y";
  assert.deepStrictEqual(json(api.iwMissing(profile, st, { "hubspot.controlled": true, "gmail.controlled": true })), []);
  m = json(api.iwMissing(profile, st, { "hubspot.controlled": false, "gmail.controlled": false, "outlook_mail.controlled": false }));
  assert.strictEqual(m.length, 2);
  assert.deepStrictEqual(m[0].tools, ["hubspot.controlled"]);
  assert.strictEqual(m[0].any, false);
  assert.strictEqual(m[1].any, true);
  assert.deepStrictEqual(m[1].tools, ["gmail.controlled", "outlook_mail.controlled"]);
});

test("compte proprietaire (statut des outils inconnu : null) : aucun controle d'outil, comme le serveur", () => {
  const st = api.iwInitialState(profile, null);
  st.services.prospection.enabled = true;
  st.services.prospection.knowledge.site_web = "x";
  st.services.prospection.knowledge.zone = "y";
  assert.deepStrictEqual(json(api.iwMissing(profile, st, { "hubspot.controlled": null, "gmail.controlled": null })), []);
  assert.deepStrictEqual(json(api.iwMissing(profile, st, null)), []);
});

test("outils d'un service : obligatoires, au choix, facultatifs", () => {
  const t = json(api.iwToolsOf(profile.services[0]));
  assert.deepStrictEqual(t.required, ["hubspot.controlled"]);
  assert.deepStrictEqual(t.anyOf, [["gmail.controlled", "outlook_mail.controlled"]]);
  assert.deepStrictEqual(t.optional, ["calendar.controlled"]);
});

test("resume de l'autonomie des services coches", () => {
  const st = api.iwInitialState(profile, null);
  assert.deepStrictEqual(json(api.iwAutonomySummary(profile, st)), { off: 0, ask: 0, draft: 0, auto: 0 }, "aucun service coche");
  st.services.prospection.enabled = true;
  assert.deepStrictEqual(json(api.iwAutonomySummary(profile, st)), { off: 1, ask: 2, draft: 1, auto: 1 });
});

test("erreurs du serveur : rangees par champ avec l'etape ou les corriger, texte en francais clair", () => {
  const errs = [
    "prospection.site_web : 2000 caracteres maximum",
    "prospection.zone : ne saisissez jamais de mot de passe, cle ou numero de carte",
    "prospection.envoi : l'autonomie complete n'est pas autorisee pour cette action (validation du client obligatoire)",
    "notes : 2000 caracteres maximum",
    "prevision : configuration invalide",
    "corps invalide",
  ];
  const r = json(api.iwParseErrors(errs, profile));
  assert.deepStrictEqual(r.fields["prospection.site_web"], ["2000 caractères au maximum."]);
  assert(/mot de passe/.test(r.fields["prospection.zone"][0]) && /IBAN/.test(r.fields["prospection.zone"][0]));
  assert(/validation reste obligatoire/.test(r.fields["prospection.envoi"][0]));
  assert.deepStrictEqual(r.fields.notes, ["2000 caractères au maximum."]);
  const step = Object.fromEntries(r.items.map((i) => [i.key || "general", i.step]));
  assert.strictEqual(step["prospection.site_web"], 1, "champ de la fiche -> etape 2 (index 1)");
  assert.strictEqual(step["prospection.envoi"], 2, "regle d'autonomie -> etape 3 (index 2)");
  assert.strictEqual(step.notes, 1);
  assert.strictEqual(step.prevision, 0);
  assert.deepStrictEqual(r.general, ["Corps invalide"]);
  assert.strictEqual(r.items.find((i) => i.key === "prospection.site_web").field, "Site", "le resume nomme le champ");
});

test("erreurs : un message inconnu ou un service inexistant n'est jamais perdu", () => {
  const r = json(api.iwParseErrors(["service inconnu pour ce Worker : fantome", "autre chose"], profile));
  assert.strictEqual(r.general.length, 2);
  assert.strictEqual(api.iwParseErrors([], profile).items.length, 0);
});

console.log(failures ? `\n${failures} ECHEC(S)` : "\nTOUT PASSE");
process.exit(failures ? 1 : 0);
