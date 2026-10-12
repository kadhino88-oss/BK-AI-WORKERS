// Utilise par test_payload_contract.py : pour chacun des profils workers/<id>/install-profile.json, construit avec la VRAIE logique de l'assistant
// (dashboard/app.js, bloc BK-PURE) les charges utiles qu'il enverrait, et ce qu'il croit manquer pour activer. Ecrit un JSON sur la sortie standard.
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const REPO = path.resolve(__dirname, "..", "..");
const src = fs.readFileSync(path.join(REPO, "dashboard", "app.js"), "utf8");
const a = src.indexOf("// BK-PURE-BEGIN");
const b = src.indexOf("// BK-PURE-END");
const ctx = vm.createContext({});
vm.runInContext(src.slice(a, b) + "\nthis.__api = { iwInitialState, iwBuildPayload, iwMissing, iwEnabledDefs, iwLiveChannelsOf, iwModesFor };", ctx);
const api = ctx.__api;
const json = (x) => JSON.parse(JSON.stringify(x));

const out = {};
for (const dir of fs.readdirSync(path.join(REPO, "workers")).sort()) {
  const file = path.join(REPO, "workers", dir, "install-profile.json");
  if (!fs.existsSync(file)) continue;
  const profile = JSON.parse(fs.readFileSync(file, "utf8").replace(/^﻿/, ""));
  const live = Object.keys(profile.channelSupport || {}).filter((c) => profile.channelSupport[c] === "available");   // ce que le serveur renvoie dans liveChannels
  const allConnectors = new Set();
  profile.services.forEach((d) => [...(d.requiredConnectors || []), ...(d.optionalConnectors || []), ...[].concat(...(d.requiredAnyOf || []))].forEach((c) => allConnectors.add(c)));
  const none = Object.fromEntries([...allConnectors].map((c) => [c, false]));

  // 1. tous les services coches, tous les champs remplis
  const full = api.iwInitialState(profile, null);
  profile.services.forEach((d) => {
    full.services[d.id].enabled = true;
    (d.knowledgeFields || []).forEach((f) => { full.services[d.id].knowledge[f.key] = "Texte de test pour " + f.key; });
  });
  // 2. tous les services coches, aucun champ rempli
  const empty = api.iwInitialState(profile, null);
  profile.services.forEach((d) => { empty.services[d.id].enabled = true; });
  // 3. rien de coche
  const nothing = api.iwInitialState(profile, null);

  out[dir] = {
    live,
    full: json(api.iwBuildPayload(dir, profile, full, live)),
    empty: json(api.iwBuildPayload(dir, profile, empty, live)),
    nothing: json(api.iwBuildPayload(dir, profile, nothing, live)),
    missing: {
      fullNull: api.iwMissing(profile, full, null).length,
      fullNone: api.iwMissing(profile, full, none).length,
      emptyNull: api.iwMissing(profile, empty, null).length,
      emptyNone: api.iwMissing(profile, empty, none).length,
      nothingNull: api.iwMissing(profile, nothing, null).length,
    },
  };
}
process.stdout.write(JSON.stringify(out));
