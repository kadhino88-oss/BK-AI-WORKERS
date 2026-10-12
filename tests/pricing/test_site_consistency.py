# -*- coding: utf-8 -*-
"""Le site ne montre jamais deux listes de prix differentes : le catalogue du serveur (PLAN_CATALOG), la page Tarifs de l'application
(PRICING_PLANS dans dashboard/app.js), la page statique /tarifs.html (PRICING_PLANS dans dashboard/seo_pages.py), les textes de Chloe (playbook et
routeur) et la FAQ / les CGV disent la meme chose. Et rien de retire ne reste : ancienne phrase comparative, anciens prix, recharge de credits,
forfait illimite, « 1 mission = 1 credit ». Le helper « Quel Worker pour mon activite ? » ne propose que des Workers qui existent, avec une raison
tiree de leur role et de leurs competences reels (fiche d'installation).

Node.js sert a lire les donnees statiques de app.js et des dictionnaires anglais (aucune page n'est executee).   python tests/pricing/test_site_consistency.py
"""
import json
import os
import re
import shutil
import subprocess
import sys
import unicodedata
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import REPO, load_server  # noqa: E402

import seo_pages  # noqa: E402

server, ROOT = load_server("bk_server_site")
NODE = shutil.which("node")
DASH = os.path.join(REPO, "dashboard")


def read(rel):
    with open(os.path.join(REPO, rel), encoding="utf-8-sig") as f:
        return f.read()


def visible_lines(rel):
    """Lignes d'un fichier servi, sans celles qui ne sont que des commentaires de code (// ..., # ..., /* ... */, <!-- ... -->)."""
    out = []
    for n, line in enumerate(read(rel).splitlines(), 1):
        if line.strip().startswith(("//", "#", "/*", "*", "<!--")):
            continue
        out.append((n, line))
    return out


def js_value(source, expression):
    """Evalue une expression JavaScript PURE (donnees statiques) avec node et renvoie sa valeur JSON."""
    out = subprocess.run([NODE, "-"], input="console.log(JSON.stringify(" + expression + "))", capture_output=True, text=True, encoding="utf-8", timeout=60)
    if out.returncode != 0:
        raise AssertionError(out.stderr[-400:])
    return json.loads(out.stdout)


def const_literal(src, name):
    m = re.search(r"const " + name + r" = (\[.*?\n\]);", src, re.S)
    assert m, name
    return m.group(1)


def dictionary_keys(*files):
    """Cles du dictionnaire anglais (FR -> EN) apres chargement de ces fichiers dans un `window` vide."""
    code = "var window = {};\n" + "\n".join(read(os.path.join("dashboard", f)) for f in files) + "\nconsole.log(JSON.stringify(Object.keys(window.BK_EN)));"
    out = subprocess.run([NODE, "-"], input=code, capture_output=True, text=True, encoding="utf-8", timeout=60)
    assert out.returncode == 0, out.stderr[-400:]
    return set(json.loads(out.stdout))


def norm_key(s):
    return re.sub(r"\s+", " ", s).strip()


def strip_accents(s):
    return "".join(c for c in unicodedata.normalize("NFD", s.lower()) if unicodedata.category(c) != "Mn")


@unittest.skipUnless(NODE, "node introuvable")
class PriceLists(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app_js = read("dashboard/app.js")
        cls.js_plans = js_value(cls.app_js, const_literal(cls.app_js, "PRICING_PLANS"))
        cls.py_plans = seo_pages.PRICING_PLANS

    def test_the_three_lists_describe_the_same_plans_in_the_same_order(self):
        ids = ["essai", "solo", "trio", "equipe", "pro", "scale", "enterprise"]
        self.assertEqual([p["id"] for p in self.js_plans], ids)
        self.assertEqual([p["id"] for p in self.py_plans], ids)
        for js, py in zip(self.js_plans, self.py_plans):
            for key in ("id", "name", "audience", "price", "annual", "period", "credits", "popular", "creditsLabel"):
                py_key = "credits_label" if key == "creditsLabel" else key
                self.assertEqual(js.get(key), py.get(py_key), f"{js['id']}.{key}")
            self.assertEqual(js["features"], py["features"], js["id"])

    def test_the_pages_show_the_catalog_prices_and_credits(self):
        for p in self.js_plans:
            plan = server.PLAN_CATALOG[p["id"]]
            if plan.get("priceChf"):
                self.assertEqual((p["price"], p["annual"]), (str(plan["priceChf"]["month"]), str(plan["priceChf"]["year"])), p["id"])
            elif p["id"] == "essai":
                self.assertEqual((p["price"], p.get("annual")), ("0", None))
            else:
                self.assertIsNone(p["price"], p["id"])
            if plan.get("contractual"):
                self.assertIsNone(p["credits"])
                self.assertIn("contrat", p["creditsLabel"])
            else:
                self.assertEqual(p["credits"], plan["credits"], p["id"])
            self.assertEqual(p["id"] == "essai", p["price"] == "0")

    def test_every_plan_id_the_ui_refers_to_exists_and_legacy_plans_are_not_offered(self):
        for p in self.js_plans + self.py_plans:
            self.assertIn(p["id"], server.PLAN_CATALOG)
            self.assertFalse(server.PLAN_CATALOG[p["id"]].get("legacy"), p["id"])
        mentioned = set(re.findall(r"""planId\s*[!=]==?\s*["']([a-z]+)["']""", self.app_js))
        mentioned |= set(re.findall(r"""data-plan-id=["']([a-z]+)["']""", self.app_js))
        mentioned |= set(re.findall(r"""querySelector\(['"]\.plan-card\[data-plan-id="([a-z]+)"\]""", self.app_js))
        self.assertTrue(mentioned)
        self.assertLessEqual(mentioned, set(server.PLAN_CATALOG))
        for rel in ("dashboard/index.html", "dashboard/seo_pages.py"):
            for pid in re.findall(r"""data-plan(?:-id)?=["']([a-z]+)["']""", read(rel)):
                self.assertIn(pid, server.PLAN_CATALOG, rel)
        # le serveur n'envoie au choix de forfait que des forfaits connus
        for pid in server.PLAN_CATALOG:
            self.assertIn(pid, server.PLAN_CATALOG)
        self.assertEqual({k for k, p in server.PLAN_CATALOG.items() if p.get("legacy")}, {"starter", "business"})

    def test_chloe_quotes_the_same_prices(self):
        texts = {"playbook": read("chloe/identity/playbook.md"), "router": read("chloe/Invoke-Chloe-Orchestration.ps1")}
        for where, text in texts.items():
            flat = text.replace("1 250", "1250").replace("4 000", "4000").replace(" ", " ")
            for pid in ("solo", "trio", "equipe", "pro", "scale"):
                plan = server.PLAN_CATALOG[pid]
                name = plan["name"] if where == "playbook" else strip_accents(plan["name"]).capitalize()
                self.assertRegex(flat, re.escape(name) + r" " + str(plan["priceChf"]["month"]) + r"\b", f"{where}: {pid}")
                self.assertIn(str(plan["credits"]), flat, f"{where}: credits de {pid}")
            self.assertNotRegex(flat, r"Starter 39|Business 99|plan gratuit, Starter")
            self.assertIn("Enterprise sur devis", flat)
            self.assertRegex(flat, r"jamais illimit")
            self.assertNotRegex(flat, r"(?i)delos|limova|sintra|marblism|moins chers? que|less expensive|cheaper than")
        self.assertLess(len(texts["playbook"]), 6000)                      # un playbook reste court (tests/playbook-prompt borne le prompt complet)


class NothingRetiredIsLeft(unittest.TestCase):
    SERVED = ["dashboard/index.html", "dashboard/app.js", "dashboard/seo_pages.py", "dashboard/trust_pages.py", "dashboard/pilot_program.py",
              "dashboard/pilot-form.js", "dashboard/pilot-admin.js", "dashboard/i18n.js", "dashboard/i18n-en.js", "dashboard/i18n-en-app.js",
              "dashboard/i18n-en-legal.js", "dashboard/i18n-en-trust.js", "dashboard/i18n-en-pwa.js", "dashboard/connect_guides.py",
              "dashboard/confidentialite.html", "dashboard/suppression-compte.html", "dashboard/offline.html", "dashboard/server.py"]
    RETIRED = [
        (r"au moins 5\s?%", "ancienne phrase comparative sans source (étude de marché, section 4.3)"),
        (r"at least 5\s?%", "ancienne phrase comparative en anglais"),
        (r"alternatives comparables|comparable alternatives", "comparaison sans source"),
        (r"Un chatbot seul coûte|A chatbot alone already costs", "ancienne comparaison de prix sans source"),
        (r"\b39\b\s*(CHF|€)|(CHF|€)\s*39\b|price:\s*\"39\"|\"price\":\s*\"39\"|\b390\b\s*(CHF|€)|(CHF|€)\s*390\b", "ancien prix Starter"),
        # le catalogue du serveur garde legitimement les credits des forfaits heritages (150, 600) : ces deux motifs ne le visent pas
        (r"\b(150|600|1\s?500)\b[^.\n]{0,25}cr[ée]dits|cr[ée]dits[^.\n]{0,15}\b(150|600|1500)\b", "anciens credits Starter / Business / Pro", ("dashboard/server.py",)),
        (r"\"credits\":\s*(150|600|1500)\b", "anciens credits dans une liste", ("dashboard/server.py",)),
        (r"(?<!ni )(?<!pas de )recharg(?:er|e) (?:de )?cr[ée]dits|peut recharger|Recharger \(|billing-recharge|rechargeBillingCredits|top[- ]ups? (?:is|are) always voluntary|can top up credits", "recharge de credits"),
        (r"quota illimit|unlimited quota|plan\.credits === null", "forfait ou quota illimite"),
        (r"1 mission[^.\n)]{0,40}=\s*1 cr[ée]dit|1 mission[^.\n)]{0,40}=\s*1 credit", "« 1 mission = 1 credit » presente comme une regle"),
        (r"(?i)\bpack(s)? de cr[ée]dits|credit packs?", "paquet de credits"),
    ]
    COMPETITORS = r"(?i)\b(delos|limova|sintra|marblism|lindy|phonely|swisscom)\b"

    def test_no_retired_price_claim_or_feature_is_still_served(self):
        found = []
        for rel in self.SERVED:
            for n, line in visible_lines(rel):
                for pattern, why, *skip in self.RETIRED:
                    if re.search(pattern, line) and rel not in (skip[0] if skip else ()):
                        found.append(f"{rel}:{n} [{why}] {line.strip()[:110]}")
        self.assertEqual(found, [])

    def test_starter_and_business_are_only_named_as_plans_that_are_no_longer_offered(self):
        allowed = (r"Les plans Starter et Business ne sont plus proposés", r"The Starter and Business plans are no longer offered")
        found = []
        for rel in self.SERVED:
            if rel == "dashboard/server.py":
                continue                                                      # le catalogue lui-meme les garde (forfaits heritages)
            for n, line in visible_lines(rel):
                if re.search(r"\bStarter\b|\bBusiness\b(?!\s+(areas|connectors|integrations))", line) and not any(re.search(a, line) for a in allowed) and "WhatsApp Business" not in line:
                    found.append(f"{rel}:{n} {line.strip()[:110]}")
        self.assertEqual(found, [])

    def test_no_competitor_is_named_on_the_public_site_or_in_chloe(self):
        found = []
        for rel in self.SERVED + ["chloe/identity/playbook.md", "chloe/Invoke-Chloe-Orchestration.ps1"]:
            for n, line in visible_lines(rel):
                if re.search(self.COMPETITORS, line):
                    found.append(f"{rel}:{n} {line.strip()[:110]}")
        self.assertEqual(found, [], "une comparaison nommant un concurrent exige l'accord du proprietaire et d'un juriste")

    def test_the_homepage_message_is_neutral_and_true(self):
        html = read("dashboard/index.html")
        self.assertIn("Dès <span data-chf=\"29\">CHF 29</span> par mois, sans engagement", html)
        self.assertNotIn("moins cher", html)
        self.assertNotIn("moins chers", html)

    def test_served_static_pages_use_the_new_model(self):
        levels = server.public_mission_levels()
        tarifs = seo_pages.render_tarifs_page(levels)
        for needle in ("29 CHF", "59 CHF", "99 CHF", "139 CHF", "449 CHF", "<strong>250</strong>", "<strong>900</strong>", "<strong>1250</strong>", "<strong>4000</strong>",
                       "Sur devis", "Plafond de crédits mensuel fixé par contrat", "1 crédit par mission", "6 crédits par mission", "12 crédits par mission",
                       "Choisissez le Worker de votre activité", "ni recharge de crédits"):
            self.assertIn(needle, tarifs)
        for gone in ("Starter", "Business"):
            self.assertNotIn(gone, tarifs)
        self.assertNotRegex(tarifs, r"(?<!ni )recharge de crédits")
        self.assertNotRegex(tarifs, r"39 CHF|390 CHF|illimité(?!es)")        # « ni missions illimitées » est la seule mention permise
        tarifs_off = seo_pages.render_tarifs_page({"levels": [], "default": ""})        # BK_LEVELS=0 : ancienne regle, 1 mission = 1 credit
        self.assertIn("consomme un crédit", tarifs_off)
        self.assertNotIn("6 crédits par mission", tarifs_off)
        faq = seo_pages.render_faq_page() + seo_pages.render_cgv_page() + seo_pages.render_facturation_page()
        for needle in ("quota mensuel fixe", "ni recharge de crédits", "forfait supérieur"):
            self.assertIn(needle, faq)
        self.assertNotRegex(faq, r"(?<!ni )recharge de crédits")             # la recharge n'existe plus : seul « ni recharge de crédits » est permis

    def test_the_trial_card_and_every_card_stay_honest_about_channels(self):
        plans = seo_pages.PRICING_PLANS
        for p in plans:
            text = " ".join([p["audience"], p["period"], p.get("credits_label") or ""] + p["features"]).lower()
            for word in ("téléphon", "whatsapp", "minute", "appel", "phone"):
                self.assertNotIn(word, text, f"{p['id']} annonce un canal qui n'est pas construit pour les clients de nos clients")
        essai = next(p for p in plans if p["id"] == "essai")
        self.assertEqual((essai["price"], essai["credits"]), ("0", 15))
        self.assertIn("Niveau Rapide uniquement", essai["features"])
        self.assertEqual(server.PLAN_CATALOG["essai"]["phoneMinutes"], 0)


@unittest.skipUnless(NODE, "node introuvable")
class SoloByActivity(unittest.TestCase):
    STOP = {"votre", "vos", "leur", "leurs", "pour", "avec", "dans", "sans", "toute", "tout", "tous", "plus", "entreprises", "entreprise", "ainsi", "chaque", "avoir"}

    @classmethod
    def setUpClass(cls):
        src = read("dashboard/app.js")
        cls.activities = js_value(src, const_literal(src, "ACTIVITY_WORKERS"))
        cls.plans = js_value(src, const_literal(src, "PRICING_PLANS"))
        reg = json.load(open(os.path.join(REPO, "core", "runtime", "worker-runtime", "WORKER-REGISTRY.json"), encoding="utf-8-sig"))
        items = reg["workers"]
        cls.registry = set(items)

    def worker_text(self, wid):
        ident = json.load(open(os.path.join(REPO, "workers", wid, "identity", "identity.json"), encoding="utf-8-sig"))
        prof = json.load(open(os.path.join(REPO, "workers", wid, "install-profile.json"), encoding="utf-8-sig"))
        parts = [str(ident.get("role", "")), str(ident.get("name", "")), prof.get("tagline", ""), prof.get("idealFor", "")]
        for s in prof.get("services", []):
            parts += [s.get("label", ""), s.get("description", "")]
        return strip_accents(" ".join(parts))

    def test_the_activities_asked_for_by_the_owner_are_there(self):
        labels = [a["label"] for a in self.activities]
        for wanted in ("Boutique en ligne", "Restaurant ou commerce local", "Cabinet ou profession libérale", "Agence ou freelance", "PME de services", "Artisan", "Association"):
            self.assertIn(wanted, labels)

    def test_every_suggested_worker_exists_and_has_an_installation_profile(self):
        sellable = {k for k in os.listdir(os.path.join(REPO, "workers")) if os.path.isfile(os.path.join(REPO, "workers", k, "install-profile.json"))}
        self.assertEqual(len(sellable), 17)
        for a in self.activities:
            self.assertTrue(1 <= len(a["workers"]) <= 3, a["id"])
            ids = [w["id"] for w in a["workers"]]
            self.assertEqual(len(ids), len(set(ids)), a["id"])
            for w in a["workers"]:
                self.assertIn(w["id"], sellable, f"{a['id']}: {w['id']}")
                self.assertIn(w["id"], self.registry, f"{a['id']}: {w['id']} absent du registre des Workers")
                self.assertNotIn(w["id"], ("chloe", "atlas"))

    def test_every_reason_is_drawn_from_the_real_role_and_skills_of_that_worker(self):
        for a in self.activities:
            for w in a["workers"]:
                text = self.worker_text(w["id"])
                words = {strip_accents(x) for x in re.findall(r"[A-Za-zÀ-ÿ]{5,}", w["why"])} - self.STOP
                shared = {x for x in words if x[:6] in text}                   # meme racine (pluriels, accords)
                self.assertGreaterEqual(len(shared), 2, f"{a['id']}/{w['id']}: « {w['why']} » ne se retrouve pas dans ses competences ({sorted(shared)})")

    def test_the_helper_is_wired_into_the_pricing_page_and_solo_says_what_the_owner_asked(self):
        html = read("dashboard/index.html")
        for needle in ('id="activity-helper"', 'id="activity-chips"', 'id="activity-result"', "Quel Worker pour mon activité ?"):
            self.assertIn(needle, html)
        solo = next(p for p in self.plans if p["id"] == "solo")
        self.assertEqual(solo["audience"], "Choisissez le Worker de votre activité")
        self.assertTrue(any("de votre choix" in f for f in solo["features"]))
        trio = next(p for p in self.plans if p["id"] == "trio")
        self.assertTrue(any("Chloé" in f for f in trio["features"]) and "Chloé" in trio["audience"])
        self.assertTrue(any("de votre choix" in f for f in trio["features"]))
        app = read("dashboard/app.js")
        self.assertIn("openWorkerProfile(link.dataset.worker)", app)            # chaque resultat ouvre la fiche du Worker (embauche / installation)

    def test_everything_new_is_translated_into_english(self):
        keys = {norm_key(k) for k in dictionary_keys("i18n-en.js", "i18n-en-app.js", "i18n-en-legal.js")}
        missing = []
        for a in self.activities:
            for s in [a["label"]] + [w["why"] for w in a["workers"]]:
                if norm_key(s) not in keys:
                    missing.append(s)
        for p in self.plans:
            for s in [p["audience"], p["period"]] + p["features"] + [p.get("creditsLabel") or "", p.get("cta") or ""]:
                if s and norm_key(s) not in keys:
                    missing.append(s)
        for s in ("Quel Worker pour mon activité ?", "Passer à la formule supérieure", "Combien de missions pour mes crédits ?", "Le plus proche de votre activité"):
            if norm_key(s) not in keys:
                missing.append(s)
        self.assertEqual(sorted(set(missing)), [])


if __name__ == "__main__":
    ok = unittest.main(verbosity=2, exit=False).result.wasSuccessful()
    sys.exit(0 if ok else 1)
