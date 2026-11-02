# -*- coding: utf-8 -*-
"""Contrôles automatiques de l'atelier (dashboard/site_checks.py) : le bon site passe sans aucun constat ; un site « piégé » avec UN défaut par
règle fait remonter cette règle (taux de détection >= 90 %) ; aucun défaut grave ne laisse passer le contrôle (0 faux PASS) ; 60 pages en moins
de 10 s ; les liens externes ne sont jamais suivis.

    python tests/site-factory/test_checks.py"""
import json
import os
import re
import shutil
import socket
import sys
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fixtures as fx  # noqa: E402
import project_checks  # noqa: E402
import site_checks  # noqa: E402
import site_factory as sf  # noqa: E402

BIG_PNG_KB = 300


def run(ws, **check):
    res = project_checks.Res()
    site_checks.run_checks(ws, dict({"profile": "vitrine"}, **check), res)
    ok = not any(f["severity"] == "error" for f in res.findings)
    return ok, res.findings


def sub(pattern, repl, count=1):
    return lambda t: re.sub(pattern, repl, t, count=count, flags=re.IGNORECASE | re.DOTALL)


def insert_main(snippet):
    return sub(r"(<main id=\"main\">)", r"\1" + snippet.replace("\\", "\\\\"))


# (règle attendue, grave ?, fonction qui sème le défaut dans le bon site construit)
def _big_png(ws):
    path = os.path.join(ws, "site", "dist", "assets", "img", "lourde.png")
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + os.urandom(BIG_PNG_KB * 1024))
    fx.edit_dist(ws, "index.html", insert_main('<img src="assets/img/lourde.png" alt="Salle de soins" width="800" height="600" loading="lazy">'))


def _huge_page(ws):
    fx.edit_dist(ws, "services/index.html", insert_main("<p>" + ("Texte de soin détaillé. " * 6000) + "</p>"))


def _huge_dist(ws):
    path = os.path.join(ws, "site", "dist", "assets", "archive.txt")
    with open(path, "wb") as f:
        f.write(b"x" * (11 * 1024 * 1024))


def _storage_js(ws):
    with open(os.path.join(ws, "site", "dist", "assets", "app.js"), "w", encoding="utf-8") as f:
        f.write("localStorage.setItem('visite', '1');\n")
    fx.edit_dist(ws, "index.html", sub(r"</head>", '<script src="assets/app.js" defer></script></head>'))


def _eval_js(ws):
    with open(os.path.join(ws, "site", "dist", "assets", "app.js"), "w", encoding="utf-8") as f:
        f.write("eval('1+1');\n")
    fx.edit_dist(ws, "index.html", sub(r"</head>", '<script src="assets/app.js" defer></script></head>'))


def _orphan(ws):
    src = open(os.path.join(ws, "site", "dist", "a-propos", "index.html"), encoding="utf-8").read()
    os.makedirs(os.path.join(ws, "site", "dist", "cachee"), exist_ok=True)
    page = src.replace("À propos du cabinet | Atelier Lumen", "Page cachée du cabinet | Atelier Lumen Lausanne").replace("../", "../")
    with open(os.path.join(ws, "site", "dist", "cachee", "index.html"), "w", encoding="utf-8") as f:
        f.write(page)


def _no_dist(ws):
    shutil.rmtree(os.path.join(ws, "site", "dist"))


def _stale(ws):
    fx.edit_src(ws, "fr", "services", lambda t: t.replace("Nous adaptons", "Nous ajustons"))


def _contrast(ws):
    fx.edit_dist(ws, "assets/style.css", sub(r"--text: #[0-9a-f]{6};", "--text: #d4d4d4;"))


def _focus(ws):
    fx.edit_dist(ws, "assets/style.css", lambda t: re.sub(r":focus-visible\s*\{[^}]*\}", "", t) + "\na:focus { outline: none; }\n")


def _reduced(ws):
    fx.edit_dist(ws, "assets/style.css", lambda t: re.sub(r"@media \(prefers-reduced-motion: reduce\) \{.*?\n\}\n", "", t, flags=re.DOTALL))


DEFECTS = [
    ("html.parse", True, lambda ws: fx.edit_dist(ws, "index.html", insert_main("<div><span>texte</div>"))),
    ("html.doctype", True, lambda ws: fx.edit_dist(ws, "index.html", sub(r"<!doctype html>\n", ""))),
    ("html.lang", True, lambda ws: fx.edit_dist(ws, "index.html", sub(r'<html lang="fr">', "<html>"))),
    ("html.charset", True, lambda ws: fx.edit_dist(ws, "index.html", sub(r'<meta charset="utf-8">\n', ""))),
    ("html.viewport", True, lambda ws: fx.edit_dist(ws, "index.html", sub(r'<meta name="viewport"[^>]*>\n', ""))),
    ("meta.title", True, lambda ws: fx.edit_dist(ws, "index.html", sub(r"<title>.*?</title>", "<title>Accueil</title>"))),
    ("meta.description", True, lambda ws: fx.edit_dist(ws, "index.html", sub(r'<meta name="description"[^>]*>\n', ""))),
    ("meta.canonical", True, lambda ws: fx.edit_dist(ws, "index.html", sub(r'<link rel="canonical"[^>]*>\n', ""))),
    ("meta.og", True, lambda ws: fx.edit_dist(ws, "index.html", sub(r'<meta property="og:image"[^>]*>\n', ""))),
    ("meta.twitter", True, lambda ws: fx.edit_dist(ws, "index.html", sub(r'<meta name="twitter:card"[^>]*>\n', ""))),
    ("meta.favicon", False, lambda ws: fx.edit_dist(ws, "index.html", sub(r'<link rel="icon"[^>]*>\n', ""))),
    ("links.internal", True, lambda ws: fx.edit_dist(ws, "index.html", insert_main('<p><a href="inexistante/">Nos tarifs détaillés</a></p>'))),
    ("links.anchor", True, lambda ws: fx.edit_dist(ws, "index.html", insert_main('<p><a href="#section-absente">Aller aux horaires</a></p>'))),
    ("links.external", False, lambda ws: fx.edit_dist(ws, "index.html", insert_main('<p><a href="https://autre-site.example/" target="_blank">Plan d\'accès</a></p>'))),
    ("links.contact", True, lambda ws: fx.edit_dist(ws, "index.html", insert_main('<p><a href="mailto:pas-une-adresse">Écrire au cabinet</a></p>'))),
    ("img.alt", True, lambda ws: fx.edit_dist(ws, "index.html", insert_main('<img src="assets/img/og.png" width="120" height="63">'))),
    ("img.dims", False, lambda ws: fx.edit_dist(ws, "index.html", insert_main('<img src="assets/img/og.png" alt="Visuel du cabinet" loading="lazy">'))),
    ("img.size", True, _big_png),
    ("img.lazy", False, lambda ws: fx.edit_dist(ws, "index.html", insert_main('<img src="assets/img/og.png" alt="Accueil du cabinet" width="12" height="6">'
                                                                              '<img src="assets/img/og.png" alt="Salle d\'attente" width="12" height="6">'))),
    ("a11y.h1", True, lambda ws: fx.edit_dist(ws, "index.html", insert_main("<h1>Second titre principal</h1>"))),
    ("a11y.heading_order", False, lambda ws: fx.edit_dist(ws, "a-propos/index.html", sub(r"<h2>Notre méthode</h2>", "<h4>Notre méthode</h4>"))),
    ("a11y.landmarks", True, lambda ws: fx.edit_dist(ws, "index.html", lambda t: t.replace('<main id="main">', '<div id="main">').replace("</main>", "</div>"))),
    ("a11y.form_labels", True, lambda ws: fx.edit_dist(ws, "contact/index.html", sub(r'<label for="nom">Nom</label>', ""))),
    ("a11y.link_text", False, lambda ws: fx.edit_dist(ws, "index.html", insert_main('<p><a href="services/">cliquez ici</a></p>'))),
    ("a11y.button_name", True, lambda ws: fx.edit_dist(ws, "index.html", insert_main('<button type="button"></button>'))),
    ("a11y.contrast", True, _contrast),
    ("a11y.focus", True, _focus),
    ("a11y.skip_link", False, lambda ws: fx.edit_dist(ws, "index.html", sub(r'<a class="skip-link"[^>]*>.*?</a>\n', ""))),
    ("a11y.reduced_motion", False, _reduced),
    ("perf.page_weight", True, _huge_page),
    ("perf.total", True, _huge_dist),
    ("privacy.trackers", True, lambda ws: fx.edit_dist(ws, "index.html", sub(r"</head>", '<script async src="https://www.googletagmanager.com/gtag/js?id=G-TEST"></script></head>'))),
    ("privacy.external", True, lambda ws: fx.edit_dist(ws, "index.html", sub(r"</head>", '<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter"></head>'))),
    ("privacy.storage", True, _storage_js),
    ("privacy.network", True, _eval_js),
    ("privacy.forms", False, lambda ws: fx.edit_dist(ws, "contact/index.html", sub(r'action="mailto:[^"]*"', 'action="https://formulaires.example/envoi"'))),
    ("i18n.parity", True, lambda ws: shutil.rmtree(os.path.join(ws, "site", "dist", "en", "about"))),
    ("i18n.hreflang", True, lambda ws: fx.edit_dist(ws, "services/index.html", sub(r'<link rel="alternate" hreflang="en"[^>]*>\n', ""))),
    ("i18n.lang", True, lambda ws: fx.edit_dist(ws, "en/services/index.html", sub(r'<html lang="en">', '<html lang="fr">'))),
    ("seo.sitemap", True, lambda ws: os.remove(os.path.join(ws, "site", "dist", "sitemap.xml"))),
    ("seo.orphans", True, _orphan),
    ("seo.titles_unique", True, lambda ws: fx.edit_dist(ws, "services/index.html", sub(r"<title>.*?</title>", "<title>À propos du cabinet | Atelier Lumen</title>"))),
    ("seo.jsonld", True, lambda ws: fx.edit_dist(ws, "index.html", sub(r"</head>", '<script type="application/ld+json">{"@context":"https://schema.org","@type":"Organization","name":"Atelier Lumen","foundingDate":"1987","telephone":"+41 21 999 88 77"}</script></head>'))),
    ("content.placeholders", False, lambda ws: fx.edit_dist(ws, "index.html", insert_main("<p>[À COMPLÉTER : couleur préférée du directeur]</p>"))),
    ("content.filler", True, lambda ws: fx.edit_dist(ws, "index.html", insert_main("<p>Lorem ipsum dolor sit amet.</p>"))),
    ("content.filler", True, lambda ws: fx.edit_dist(ws, "index.html", insert_main("<p>[À RÉDIGER : texte de la section]</p>"))),
    ("content.fake_contact", True, lambda ws: fx.edit_dist(ws, "index.html", insert_main('<p>Écrivez à <a href="mailto:info@example.com">info@example.com</a></p>'))),
    ("claims.unverified", True, lambda ws: fx.edit_dist(ws, "index.html", insert_main("<p>Plus de 500 patients satisfaits nous font confiance.</p>"))),
    ("claims.unverified", True, lambda ws: fx.edit_dist(ws, "index.html", insert_main("<p>Noté 4,9/5 par nos patients.</p>"))),
    ("claims.unverified", True, lambda ws: fx.edit_dist(ws, "index.html", insert_main("<p>Cabinet certifié ISO 9001.</p>"))),
    ("claims.unverified", True, lambda ws: fx.edit_dist(ws, "index.html", insert_main("<blockquote>Une équipe formidable, je recommande ! — Marie</blockquote>"))),
    ("claims.unverified", True, lambda ws: fx.edit_dist(ws, "index.html", sub(r"</head>", '<script type="application/ld+json">{"@context":"https://schema.org","@type":"Organization","name":"Atelier Lumen","aggregateRating":{"@type":"AggregateRating","ratingValue":"4.9"}}</script></head>'))),
    ("abuse.credential_form", True, lambda ws: fx.edit_dist(ws, "contact/index.html", insert_main('<form action="mailto:contact@atelier-lumen.example"><label for="mdp">Mot de passe</label><input id="mdp" name="mdp" type="password"></form>'))),
    ("build.missing", True, _no_dist),
    ("build.stale", True, _stale),
]


class CheckerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.base = fx.make_good_site()

    @classmethod
    def tearDownClass(cls):
        fx.cleanup(cls.base)

    def copy(self):
        ws = self.base + "-c" + str(len(os.listdir(os.path.dirname(self.base))) % 100000) + os.urandom(3).hex()
        shutil.copytree(self.base, ws)
        self.addCleanup(fx.cleanup, ws)
        return ws

    def test_good_site_has_no_finding_at_all(self):
        ok, findings = run(self.base)
        self.assertTrue(ok)
        self.assertEqual([f for f in findings if f["severity"] in ("error", "warn")], [], findings)

    def test_each_seeded_defect_is_detected_and_no_hard_defect_passes(self):
        detected, missed, false_pass = 0, [], []
        for rule, hard, seed in DEFECTS:
            ws = self.copy()
            seed(ws)
            ok, findings = run(ws)
            rules = {f["rule"] for f in findings if f["severity"] in ("error", "warn")}
            if rule in rules:
                detected += 1
            else:
                missed.append((rule, sorted(rules)[:6]))
            if hard and ok:
                false_pass.append(rule)
        rate = detected / len(DEFECTS)
        print(f"\n  détection : {detected}/{len(DEFECTS)} défauts semés ({rate:.0%}) ; manqués : {missed}")
        self.assertGreaterEqual(rate, 0.90, missed)
        self.assertEqual(false_pass, [], "un défaut grave a laissé passer le contrôle")
        self.assertEqual(missed, [], "l'objectif est 100 % sur la fixture ; 90 % est le seuil du contrat")

    def test_security_rules_always_run_even_when_not_requested(self):
        ws = self.copy()
        fx.edit_dist(ws, "index.html", insert_main("<p>Plus de 500 clients satisfaits.</p>"))
        ok, findings = run(ws, must=["links"])
        self.assertFalse(ok)
        self.assertIn("claims.unverified", {f["rule"] for f in findings})

    def test_claims_declared_by_the_client_are_accepted(self):
        ws = self.copy()
        fx.edit_dist(ws, "index.html", insert_main("<p>Cabinet certifié par l'association suisse de physiothérapie.</p>"))
        self.assertFalse(run(ws)[0])
        fx.edit_site_json(ws, lambda s: s.update(claimsProvidedByClient=["certifications"]))
        sf.build(ws)       # la fixture garde dist/ à jour avec src/ (sinon build.stale)
        fx.edit_dist(ws, "index.html", insert_main("<p>Cabinet certifié par l'association suisse de physiothérapie.</p>"))
        ok, findings = run(ws)
        self.assertNotIn("claims.unverified", {f["rule"] for f in findings if f["severity"] == "error"}, findings)

    def test_skeleton_fails_until_the_worker_writes_the_text(self):
        ws = self.copy()
        shutil.rmtree(os.path.join(ws, "site"))
        sf.scaffold(ws, {"profile": "vitrine", "languages": ["fr"], "brand": {"name": "Atelier Lumen"}})
        sf.build(ws)
        ok, findings = run(ws)
        self.assertFalse(ok)
        rules = {f["rule"] for f in findings if f["severity"] == "error"}
        self.assertIn("content.filler", rules)            # [À RÉDIGER] restant
        self.assertIn("meta.description", rules)
        # rien d'inventé : aucune affirmation, aucune coordonnée factice dans le squelette
        self.assertNotIn("claims.unverified", rules)
        self.assertNotIn("content.fake_contact", rules)
        self.assertNotIn("privacy.trackers", rules)
        self.assertNotIn("a11y.contrast", rules)

    def test_external_links_are_listed_never_fetched(self):
        ws = self.copy()
        fx.edit_dist(ws, "index.html", insert_main('<p><a href="https://plan.example/acces" rel="noopener noreferrer">Plan d\'accès</a></p>'))
        real = socket.socket.connect
        calls = []

        def spy(self_, *a, **k):
            calls.append(a)
            return real(self_, *a, **k)

        socket.socket.connect = spy
        try:
            ok, findings = run(ws)
        finally:
            socket.socket.connect = real
        self.assertEqual(calls, [])
        self.assertTrue(ok, findings)
        self.assertTrue(any(f["rule"] == "links.external" and f["severity"] == "info" and "plan.example" in f["detail"] for f in findings))

    def test_sixty_pages_are_checked_in_under_ten_seconds(self):
        ws = self.copy()
        shutil.rmtree(os.path.join(ws, "site"))
        pages = [{"key": f"p{i}", "slug": f"page-{i}", "title": f"Page {i}", "sections": ["page-title", "text"]} for i in range(27)]
        sf.scaffold(ws, {"profile": "vitrine", "languages": ["fr", "en"], "brand": {"name": "Atelier Lumen"}, "pages": pages})
        sf.build(ws)
        n = len([1 for _d, _s, fs in os.walk(os.path.join(ws, "site", "dist")) for f in fs if f.endswith(".html")])
        self.assertGreaterEqual(n, 60)
        t = time.time()
        run(ws)
        took = time.time() - t
        print(f"\n  {n} pages contrôlées en {took:.2f} s")
        self.assertLess(took, 10.0)

    def test_check_result_is_registered_as_engine_check_type(self):
        self.assertIn("site_check", project_checks.CHECKS)
        out_dir = os.path.join(self.base + "-chk")
        self.addCleanup(fx.cleanup, out_dir)
        res = project_checks.run_check(project_checks.CheckCtx(self.base), {"type": "site_check", "profile": "vitrine"}, out_dir=out_dir)
        self.assertTrue(res["ok"], res["findings"][:5])
        self.assertRegex(res["id"], r"^CHK-[0-9a-f]{8}$")
        self.assertTrue(os.path.isfile(os.path.join(out_dir, res["id"] + ".json")))
        self.assertTrue(any(i["path"].startswith("site/dist/") for i in res["inputs"]))


if __name__ == "__main__":
    unittest.main(verbosity=2)
