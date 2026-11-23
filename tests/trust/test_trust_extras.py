# -*- coding: utf-8 -*-
"""Garde-fous complementaires des pages de confiance (suite de test_trust_pages.py) :

  1. aucune phrase publique ne contredit la page Securite (« pas meme nous », « y compris par l'equipe ») ;
  2. INVENTAIRE DES HOTES : tout hote externe cite dans le code d'execution est classe (sous-traitant declare sur la
     page Securite, outil du client, ou lien/espace de noms sans appel). Un nouvel hote non classe fait echouer le test :
     il faut alors l'ajouter a la liste des sous-traitants de dashboard/trust_pages.py (et au DPA) ou le classer ici ;
  3. la page Statut ne montre jamais un etat perime : si /api/status est injoignable, le bandeau passe a « inconnu »
     (script execute pour de vrai avec Node et un faux DOM) ;
  4. reponse HEAD (sondes externes) : en-tetes seulement ;
  5. pied de page de la politique de confidentialite.

Lancer : python tests/trust/test_trust_extras.py      (ou pytest). Sans reseau, sans serveur.
"""
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(REPO, "dashboard"))
sys.path.insert(0, HERE)
import trust_pages  # noqa: E402
import check_certification_claims as ccc  # noqa: E402

HAS_NODE = shutil.which("node") is not None


def read(rel):
    with open(os.path.join(REPO, rel), encoding="utf-8-sig", newline=None) as f:
        return f.read()


class NoContradictionTests(unittest.TestCase):
    """La page Securite dit qu'une personne ayant acces au serveur pourrait lire les identifiants d'outils :
    aucune autre page ne doit promettre le contraire."""
    FORBIDDEN = ("pas même nous", "not even us", "y compris par l'équipe", "including to the BK-AI-WORKERS team",
                 "ne peut les lire", "jamais vus en clair", "never seen in clear text")
    PUBLIC = ("dashboard/index.html", "dashboard/confidentialite.html", "dashboard/seo_pages.py", "dashboard/app.js",
              "dashboard/i18n-en.js", "dashboard/i18n-en-app.js", "dashboard/phone_agent.py")

    def test_no_public_page_promises_that_nobody_can_read_credentials(self):
        for rel in self.PUBLIC:
            text = read(rel).lower()
            for phrase in self.FORBIDDEN:
                self.assertNotIn(phrase.lower(), text, f"{rel} contient une promesse contredite par la page Securite : {phrase!r}")
        legal = read("dashboard/i18n-en-legal.js")
        for phrase in ("including to the BK-AI-WORKERS team", "not even us"):
            self.assertNotIn(phrase, legal)

    def test_credential_sentence_is_translated_for_both_variants(self):
        en = ccc.load_translations(os.path.join(REPO, "dashboard", "i18n-en-legal.js"))
        for page in ("dashboard/index.html", "dashboard/confidentialite.html"):
            m = re.search(r"<p>(Les identifiants de connexion à vos outils[^<]*)</p>", read(page))
            self.assertTrue(m, page)
            self.assertIn(m.group(1), en, f"{page} : phrase sans traduction anglaise")
            self.assertIn("could therefore technically read them", en[m.group(1)])

    def test_privacy_names_conditional_ai_and_web_search_providers_in_both_variants(self):
        en = ccc.load_translations(os.path.join(REPO, "dashboard", "i18n-en-legal.js"))
        for page in ("dashboard/index.html", "dashboard/confidentialite.html"):
            m = re.search(r"<p>(Selon le moteur configuré pour votre mission.*?missions\.)</p>", read(page))
            self.assertTrue(m, f"{page} : détail des moteurs IA/recherche absent")
            self.assertIn("Infomaniak AI Services (Suisse)", m.group(1))
            self.assertIn("SearXNG", m.group(1))
            self.assertIn(m.group(1), en, f"{page} : section sans traduction anglaise")

    def test_privacy_page_footer_links_to_security_and_status(self):
        page = read("dashboard/confidentialite.html")
        self.assertIn('<a href="/securite.html">Sécurité et confiance</a>', page)
        self.assertIn('<a href="/status.html">Statut du service</a>', page)
        en = ccc.load_translations(os.path.join(REPO, "dashboard", "i18n-en-legal.js"))
        self.assertEqual(en["Sécurité et confiance"], "Security and trust")
        self.assertEqual(en["Statut du service"], "Service status")


# --------------------------------------------------------------------------- inventaire des hotes
CLIENT_TOOL = "client-tool"        # outil que le CLIENT connecte lui-meme (ligne « Outils tiers que vous connectez »)
NO_CALL = "no-call"                # espace de noms, exemple, lien de documentation : aucun appel du serveur
HOSTS = {
    "bk-ai-workers.com": "own",
    # sous-traitants declares (identifiant de preuve de la page Securite)
    "api.anthropic.com": "sp-anthropic",
    "api.openai.com": "sp-openai",
    "api.infomaniak.com": "sp-swiss-engine",
    "api.mistral.ai": "sp-byok",       # exemple d'adresse du formulaire « ma propre cle d'IA » (dashboard/index.html)
    "api.stripe.com": "stripe-hosted",
    "api.twilio.com": "sp-twilio", "console.twilio.com": "sp-twilio",
    "graph.facebook.com": "sp-meta", "wa.me": "sp-meta", "developers.facebook.com": "sp-meta", "business.facebook.com": "sp-meta",
    "cdnjs.cloudflare.com": "sp-cdnjs",
    "cdn.jsdelivr.net": "sp-jsdelivr",
    "api.frankfurter.dev": "sp-fx",
    "fonts.googleapis.com": "sp-fonts", "fonts.gstatic.com": "sp-fonts",
    "www.googleapis.com": "sp-google", "oauth2.googleapis.com": "sp-google", "accounts.google.com": "sp-google",
    "openidconnect.googleapis.com": "sp-google", "gmail.googleapis.com": "sp-google", "googleads.googleapis.com": "sp-google",
    "myaccount.google.com": "sp-google", "developers.google.com": "sp-google",
    "login.microsoftonline.com": "sp-microsoft", "graph.microsoft.com": "sp-microsoft",
    # outils tiers que le client connecte
    "app.asana.com": CLIENT_TOOL, "www.linkedin.com": CLIENT_TOOL, "api.linkedin.com": CLIENT_TOOL,
    "www.dropbox.com": CLIENT_TOOL, "api.dropboxapi.com": CLIENT_TOOL, "slack.com": CLIENT_TOOL, "api.slack.com": CLIENT_TOOL,
    "hooks.slack.com": CLIENT_TOOL, "auth.monday.com": CLIENT_TOOL, "monday.com": CLIENT_TOOL, "api.monday.com": CLIENT_TOOL,
    "app.intercom.com": CLIENT_TOOL, "api.intercom.io": CLIENT_TOOL, "app.hubspot.com": CLIENT_TOOL, "api.hubapi.com": CLIENT_TOOL,
    "www.zendesk.com": CLIENT_TOOL, "www.figma.com": CLIENT_TOOL, "api.figma.com": CLIENT_TOOL,
    "www.bamboohr.com": CLIENT_TOOL, "api.bamboohr.com": CLIENT_TOOL, "wordpress.org": CLIENT_TOOL, "woocommerce.com": CLIENT_TOOL,
    "webflow.com": CLIENT_TOOL, "api.webflow.com": CLIENT_TOOL, "trello.com": CLIENT_TOOL, "api.trello.com": CLIENT_TOOL,
    "quickbooks.api.intuit.com": CLIENT_TOOL, "oauth.platform.intuit.com": CLIENT_TOOL, "open.tiktokapis.com": CLIENT_TOOL,
    "developers.tiktok.com": CLIENT_TOOL, "login.salesforce.com": CLIENT_TOOL, "identity.xero.com": CLIENT_TOOL,
    "api.xero.com": CLIENT_TOOL, "hooks.zapier.com": CLIENT_TOOL, "developer.x.com": CLIENT_TOOL, "api.twitter.com": CLIENT_TOOL,
    "dashboard.uptimerobot.com": CLIENT_TOOL, "api.uptimerobot.com": CLIENT_TOOL, "app.pipedrive.com": CLIENT_TOOL,
    "api.pipedrive.com": CLIENT_TOOL, "admin.shopify.com": CLIENT_TOOL, "api-m.paypal.com": CLIENT_TOOL,
    # outil du proprietaire (production de videos), jamais appele pour un client : voir docs/SECURITY-OVERVIEW.md
    "api.d-id.com": "owner-tool",
    # espaces de noms et exemples
    "json-schema.org": NO_CALL, "www.sitemaps.org": NO_CALL, "schema.org": NO_CALL, "www.MonSite.com": NO_CALL,
    # exemple de champ de fiche d'installation (workers/alex/install-profile.json) : texte d'aide, jamais appele
    "www.atelier-martin.example": NO_CALL,
    # espace de noms XML des fichiers Office (dashboard/file_preview.py) : identifiant dans un document, jamais appele
    "schemas.openxmlformats.org": NO_CALL,
    # references officielles CITEES par les recettes de projet (core/projects/RECIPE-SOURCES.json) : adresses affichees dans les livrables, jamais appelees par le code
    # (une lecture eventuelle passe par la recherche / lecture web du moteur d'IA, deja declare comme sous-traitant)
    "www.fedlex.admin.ch": NO_CALL, "www.edpb.europa.eu": NO_CALL, "gdpr-info.eu": NO_CALL, "support.google.com": NO_CALL,
    "transparency.meta.com": NO_CALL, "www.facebook.com": NO_CALL,
    # atelier de sites (dashboard/site_factory.py) : espace de noms SVG/HTML et domaine d'exemple des sites generes, jamais appeles
    "www.w3.org": NO_CALL, "votre-domaine.example": NO_CALL,
}
SCAN_DIRS = ("dashboard", "core", "workers", "chloe", "orchestrator")
SCAN_EXT = (".py", ".ps1", ".js", ".html", ".json")
SKIP_PARTS = ("/_archive/", "/tests/", "/node_modules/", "/runtime/", "/memory/runtime/", "/data/")


def external_hosts():
    found = {}
    pat = re.compile(r"https?://([a-zA-Z0-9._-]+\.[a-zA-Z]{2,})")
    for d in SCAN_DIRS:
        for dirpath, dirnames, filenames in os.walk(os.path.join(REPO, d)):
            norm = dirpath.replace("\\", "/") + "/"
            if any(p in norm for p in SKIP_PARTS):
                continue
            for name in filenames:
                if not name.endswith(SCAN_EXT) or name.startswith("i18n-en-trust"):
                    continue
                path = os.path.join(dirpath, name)
                try:
                    text = open(path, encoding="utf-8-sig", errors="replace").read()
                except OSError:
                    continue
                for host in pat.findall(text):
                    found.setdefault(host, os.path.relpath(path, REPO).replace("\\", "/"))
    return found


class HostInventoryTests(unittest.TestCase):
    def test_every_external_host_in_the_code_is_classified(self):
        unknown = {h: f for h, f in external_hosts().items() if h not in HOSTS}
        self.assertEqual(unknown, {}, "hote externe non classe : l'ajouter a la liste des sous-traitants de dashboard/trust_pages.py "
                                      "(page Securite + DPA) ou le classer dans tests/trust/test_trust_extras.py")

    def test_declared_subprocessors_point_to_claims_that_exist(self):
        ids = {row[4] for row in trust_pages.SUBPROCESSORS}
        for host, kind in HOSTS.items():
            if kind.startswith("sp-") or kind == "stripe-hosted":
                self.assertIn(kind, ids, f"{host} : sous-traitant absent de la page Securite ({kind})")

    def test_client_tools_row_exists(self):
        self.assertIn("sp-tools", {row[4] for row in trust_pages.SUBPROCESSORS})

    def test_the_classification_has_no_dead_entries(self):
        seen = external_hosts()
        dead = sorted(h for h, kind in HOSTS.items() if h not in seen and h != "bk-ai-workers.com" and kind != NO_CALL)
        self.assertEqual(dead, [], "hotes classes mais absents du code : retirer de la liste ou verifier le scan")


# --------------------------------------------------------------------------- page Statut : jamais d'etat perime
DOM_HARNESS = r"""
const vm = require("vm");
const fs = require("fs");
const input = JSON.parse(fs.readFileSync(0, "utf8"));
function mk(tag) {
  const e = { tag, children: [], className: "", attrs: {}, style: {}, title: "", _t: "" };
  e.appendChild = c => { e.children.push(c); return c; };
  e.setAttribute = (k, v) => { e.attrs[k] = v; };
  Object.defineProperty(e, "textContent", { get() { return e._t; }, set(v) { e._t = String(v); if (v === "") e.children = []; } });
  return e;
}
const root = mk("div");
const dataEl = { textContent: JSON.stringify(input.embedded) };
const handlers = {};
const document = {
  getElementById: id => (id === "status-root" ? root : dataEl),
  createElement: mk,
  createTextNode: t => ({ tag: "#text", children: [], _t: t, className: "" }),
  addEventListener: (n, f) => { handlers[n] = f; },
};
const window = { BK_LANG: () => input.lang };
const fetchFn = () => (input.fetch === "fail"
  ? Promise.reject(new Error("offline"))
  : Promise.resolve({ ok: true, json: () => Promise.resolve(input.fetched) }));
vm.runInNewContext(input.script, { window, document, fetch: fetchFn, setInterval: () => 0, console, Date, Number, JSON });
setTimeout(() => {
  const flat = [];
  (function walk(n) { flat.push({ cls: n.className || "", text: n._t || "" }); (n.children || []).forEach(walk); })(root);
  process.stdout.write(JSON.stringify(flat));
}, 30);
"""


def run_status_script(embedded, fetch, fetched=None, lang="fr"):
    proc = subprocess.run(["node", "-e", DOM_HARNESS], input=json.dumps({"script": trust_pages._STATUS_JS, "embedded": embedded, "fetch": fetch,
                                                                          "fetched": fetched, "lang": lang}),
                          capture_output=True, text=True, encoding="utf-8", timeout=60)
    if proc.returncode != 0:
        raise AssertionError(proc.stderr[:800])
    return json.loads(proc.stdout)


def payload(status, ai="ok"):
    return {"generatedAtUtc": "2026-10-07T10:00:00Z", "status": status,
            "components": [{"id": "app", "state": "ok"}, {"id": "data", "state": "ok"}, {"id": "ai", "state": ai}],
            "measuredSinceUtc": "2026-10-07T08:00:00Z",
            "uptime": {"percent": 100.0, "measuredMinutes": 120, "degradedMinutes": 0, "windowDays": 90},
            "days": [], "incidents": [], "sampleIntervalSeconds": 60}


@unittest.skipUnless(HAS_NODE, "node absent")
class StatusPageStaleTests(unittest.TestCase):
    def banner(self, flat):
        return next(n for n in flat if n["cls"].startswith("st-banner"))

    def test_unreachable_api_never_shows_the_embedded_state_as_current(self):
        flat = run_status_script(payload("operational"), "fail")
        b = self.banner(flat)
        self.assertIn("unknown", b["cls"])
        self.assertNotIn("operational", b["cls"])
        self.assertIn("Mesure indisponible", b["text"])
        values = [n for n in flat if n["cls"].startswith("v ")]
        self.assertEqual(len(values), 3)
        self.assertTrue(all(v["cls"] == "v unknown" for v in values), values)
        self.assertTrue(any("l'état actuel est inconnu" in n["text"] for n in flat))

    def test_unreachable_api_in_english(self):
        flat = run_status_script(payload("operational"), "fail", lang="en")
        self.assertEqual(self.banner(flat)["text"], "Measurement unavailable for the moment")
        self.assertTrue(any("current state is unknown" in n["text"] for n in flat))

    def test_a_successful_refresh_replaces_the_embedded_state_at_once(self):
        flat = run_status_script(payload("operational"), "ok", fetched=payload("degraded", ai="down"))
        b = self.banner(flat)
        self.assertIn("degraded", b["cls"])
        self.assertTrue(any(n["text"] == "Injoignable" for n in flat))

    def test_unknown_state_shows_measurement_unavailable_in_the_banner(self):
        flat = run_status_script(payload("unknown"), "ok", fetched=payload("unknown"))
        self.assertIn("Mesure indisponible", self.banner(flat)["text"])


# --------------------------------------------------------------------------- HEAD
class HeadOnlyWriterTests(unittest.TestCase):
    def test_only_the_headers_pass_through(self):
        real = io.BytesIO()
        w = trust_pages._HeadOnlyWriter(real)
        w.write(b"HTTP/1.0 200 OK\r\nContent-Length: 11\r\n")
        w.write(b"\r\n")
        w.write(b"hello world")
        w.write(b"more")
        self.assertEqual(real.getvalue(), b"HTTP/1.0 200 OK\r\nContent-Length: 11\r\n\r\n")

    def test_headers_written_in_one_chunk_with_a_body_glued_to_them(self):
        real = io.BytesIO()
        w = trust_pages._HeadOnlyWriter(real)
        w.write(b"HTTP/1.0 200 OK\r\nX: y\r\n\r\nBODY")
        self.assertEqual(real.getvalue(), b"HTTP/1.0 200 OK\r\nX: y\r\n\r\n")

    def test_head_is_limited_to_the_routes_of_this_module(self):
        self.assertIn("/api/health", trust_pages.TrustService.HEAD_PATHS)
        for p in ("/api/admin/status/incidents", "/api/workers", "/api/account/export", "/i18n-en-trust.js"):
            self.assertNotIn(p, trust_pages.TrustService.HEAD_PATHS)

    def test_server_py_has_the_head_hook(self):
        src = read("dashboard/server.py")
        self.assertEqual(src.count("TRUST.handle_head(self,"), 1)
        self.assertIn("def do_HEAD(self):", src)


if __name__ == "__main__":
    unittest.main(verbosity=2)
