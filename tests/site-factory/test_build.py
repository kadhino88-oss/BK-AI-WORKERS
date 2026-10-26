# -*- coding: utf-8 -*-
"""Fabrique de sites (dashboard/site_factory.py) : squelette, construction déterministe, liens relatifs, couleurs à contraste garanti, zip
reproductible, guide de mise en ligne sans valeur inventée, préparation des brouillons WordPress.

    python tests/site-factory/test_build.py"""
import hashlib
import io
import json
import os
import shutil
import sys
import unittest
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fixtures as fx  # noqa: E402
import site_css as css  # noqa: E402
import site_factory as sf  # noqa: E402


def tree_digest(d):
    h = hashlib.sha256()
    for dp, dn, fn in os.walk(d):
        dn.sort()
        for n in sorted(fn):
            p = os.path.join(dp, n)
            h.update(os.path.relpath(p, d).replace(os.sep, "/").encode() + b"\0")
            h.update(open(p, "rb").read())
    return h.hexdigest()


class BuildTests(unittest.TestCase):
    def setUp(self):
        self.ws = fx.make_good_site()
        self.addCleanup(fx.cleanup, self.ws)
        self.dist = os.path.join(self.ws, "site", "dist")

    def read(self, rel):
        return open(os.path.join(self.dist, *rel.split("/")), encoding="utf-8").read()

    def test_two_builds_give_identical_bytes(self):
        a = tree_digest(self.dist)
        sf.build(self.ws)
        self.assertEqual(a, tree_digest(self.dist))
        b1 = open(os.path.join(self.ws, "site", "build.json"), "rb").read()
        sf.build(self.ws)
        self.assertEqual(b1, open(os.path.join(self.ws, "site", "build.json"), "rb").read())

    def test_build_adds_the_head_tags_and_structure(self):
        html = self.read("en/about/index.html")
        for needle in ('<!doctype html>', '<html lang="en">', '<meta charset="utf-8">', 'name="viewport"', '<title>About the practice | Atelier Lumen</title>',
                       'rel="canonical" href="https://atelier-lumen.example/en/about/"', 'hreflang="fr" href="https://atelier-lumen.example/a-propos/"',
                       'hreflang="x-default"', 'property="og:image" content="https://atelier-lumen.example/assets/img/og.png"', 'name="twitter:card"',
                       'class="skip-link" href="#main"', '<main id="main">', 'aria-current="page"', 'class="site-footer"'):
            self.assertIn(needle, html)
        self.assertNotIn("{{", html)
        self.assertNotIn("<!--", html.split("<main", 1)[1])        # commentaires de travail jamais publiés

    def test_internal_links_become_relative_and_resolve(self):
        html = self.read("en/about/index.html")
        self.assertIn('href="../../assets/style.css"', html)
        self.assertIn('href="../../en/contact/"', html)
        self.assertNotIn('href="/', html)
        home = self.read("index.html")
        self.assertIn('href="./assets/style.css"', home)
        css_text = self.read("assets/style.css")
        self.assertIn("--on-primary", css_text)
        nf = self.read("404.html")
        self.assertIn('href="/assets/style.css"', nf)               # la 404 garde des liens racine (servie à toute profondeur)
        self.assertIn('name="robots" content="noindex"', nf)

    def test_generated_files_sitemap_robots_icons(self):
        sm = self.read("sitemap.xml")
        self.assertIn("<loc>https://atelier-lumen.example/</loc>", sm)
        self.assertIn("<loc>https://atelier-lumen.example/en/privacy/</loc>", sm)
        self.assertNotIn("404", sm)
        self.assertIn("Sitemap: https://atelier-lumen.example/sitemap.xml", self.read("robots.txt"))
        png = open(os.path.join(self.dist, "assets", "img", "og.png"), "rb").read()
        self.assertTrue(png.startswith(b"\x89PNG\r\n\x1a\n"))
        self.assertLess(len(png), 250 * 1024)
        self.assertIn("<svg", self.read("assets/favicon.svg"))

    def test_json_ld_uses_only_site_json_values(self):
        html = self.read("index.html")
        block = html.split('<script type="application/ld+json">', 1)[1].split("</script>", 1)[0]
        data = json.loads(block)
        self.assertEqual(data["name"], "Atelier Lumen")
        self.assertEqual(data["email"], "contact@atelier-lumen.example")
        self.assertNotIn("aggregateRating", block)

    def test_missing_facts_become_placeholders_never_inventions(self):
        ws = fx.make_good_site(build=False)
        self.addCleanup(fx.cleanup, ws)
        shutil.rmtree(os.path.join(ws, "site"))
        out = sf.scaffold(ws, {"profile": "vitrine", "languages": ["fr"], "brand": {"name": "Menuiserie Bois-Joli"}})
        self.assertIn("numéro de téléphone", out["needsFromClient"])
        self.assertIn("adresse du site (nom de domaine)", out["needsFromClient"])
        sf.build(ws)
        contact = open(os.path.join(ws, "site", "dist", "contact", "index.html"), encoding="utf-8").read()
        self.assertIn("[À COMPLÉTER : numéro de téléphone]", contact)
        self.assertIn("[À COMPLÉTER : adresse e-mail de contact]", contact)
        self.assertNotIn("tel:", contact)
        self.assertNotIn("@example", contact)
        legal = open(os.path.join(ws, "site", "dist", "mentions-legales", "index.html"), encoding="utf-8").read()
        self.assertIn("[À COMPLÉTER : numéro IDE de l'entreprise]", legal)
        self.assertIn("Menuiserie Bois-Joli", legal)          # raison sociale par défaut = nom donné par le client

    def test_scaffold_refuses_to_overwrite_without_force(self):
        with self.assertRaises(sf.SiteError) as cm:
            sf.scaffold(self.ws, {"profile": "landing"})
        self.assertEqual(cm.exception.code, "EXISTS")
        out = sf.scaffold(self.ws, {"profile": "landing", "languages": ["fr"], "force": True})
        self.assertEqual(out["profile"], "landing")
        self.assertFalse(os.path.isdir(os.path.join(self.ws, "site", "src", "pages", "en")))

    def test_palette_contrast_is_guaranteed_even_for_bad_brand_colours(self):
        for colors in ({"primary": "#ffff00", "accent": "#ffffcc"}, {"primary": "#777777", "bg": "#888888", "text": "#999999"},
                       {"primary": "#000000", "bg": "#0a0a0a", "text": "#111111"}, {}):
            block, v = sf.palette({"colors": colors})
            self.assertGreaterEqual(css.contrast(css.parse_color(v["text"]), css.parse_color(v["bg"])), 4.5, colors)
            self.assertGreaterEqual(css.contrast(css.parse_color(v["onPrimary"]), css.parse_color(v["primary"])), 4.5, colors)
            self.assertGreaterEqual(css.contrast(css.parse_color(v["link"]), css.parse_color(v["bg"])), 4.5, colors)

    def test_full_document_written_by_a_worker_is_reduced_to_its_body(self):
        fx.edit_src(self.ws, "fr", "a-propos", lambda t: t.split("\n", 1)[0] + "\n<!doctype html><html><head><title>x</title><script src=\"https://evil.example/x.js\"></script></head>"
                    "<body><section class=\"section\"><div class=\"container prose\"><h1>À propos d'Atelier Lumen</h1><p>Texte.</p></div></section></body></html>")
        info = sf.build(self.ws)
        html = self.read("a-propos/index.html")
        self.assertNotIn("evil.example", html)
        self.assertEqual(html.count("<html"), 1)
        self.assertTrue(any("document HTML complet" in w for w in info["warnings"]))

    def test_unknown_tokens_and_undeclared_pages_are_reported(self):
        fx.edit_src(self.ws, "fr", "services", lambda t: t + "\n<p>{{secret.token}}</p>")
        with open(os.path.join(self.ws, "site", "src", "pages", "fr", "orpheline.html"), "w", encoding="utf-8") as f:
            f.write("<p>x</p>")
        info = sf.build(self.ws)
        self.assertTrue(any("jeton(s) inconnu(s)" in w for w in info["warnings"]))
        self.assertTrue(any("orpheline.html" in w for w in info["warnings"]))
        self.assertNotIn("secret.token", self.read("services/index.html"))
        self.assertFalse(os.path.exists(os.path.join(self.dist, "orpheline")))

    def test_zip_is_reproducible_and_contains_dist_and_guide(self):
        a = sf.export_zip(self.ws)
        b = sf.export_zip(self.ws)
        self.assertEqual(hashlib.sha256(a).hexdigest(), hashlib.sha256(b).hexdigest())
        z = zipfile.ZipFile(io.BytesIO(a))
        names = z.namelist()
        self.assertEqual(names, sorted(names))
        self.assertIn("MISE-EN-LIGNE.md", names)
        self.assertIn("site/index.html", names)
        self.assertFalse(any(n.split("/")[-1].startswith(".") for n in names))
        self.assertTrue(all(i.date_time == sf.ZIP_DATE for i in z.infolist()))
        src = zipfile.ZipFile(io.BytesIO(sf.export_zip(self.ws, "source"))).namelist()
        self.assertIn("source/site.json", src)
        self.assertIn("source/src/pages/fr/index.html", src)

    def test_package_writes_deliverables(self):
        out = sf.package(self.ws)
        self.assertEqual(out["zip"], "deliverables/site-atelier-lumen.zip")
        self.assertTrue(os.path.getsize(os.path.join(self.ws, "deliverables", "site-atelier-lumen.zip")) > 1000)
        guide = open(os.path.join(self.ws, "deliverables", "MISE-EN-LIGNE.md"), encoding="utf-8").read()
        self.assertIn("Infomaniak", guide)
        self.assertIn("atelier-lumen.example", guide)

    def test_publish_guide_never_invents_dns_values(self):
        site = sf.load_site(self.ws)
        site["hosting"] = {"host": "", "domain": ""}
        site["baseUrl"] = ""
        g = sf.publish_guide(site)
        self.assertIn("[À COMPLÉTER : votre nom de domaine]", g)
        self.assertNotRegex(g, r"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b")      # aucune adresse IP inventée
        site["hosting"] = {"host": "netlify", "domain": "atelier-lumen.example"}
        g = sf.publish_guide(site)
        self.assertIn("Netlify", g)
        self.assertIn("[À COMPLÉTER : IP fournie par l'hébergeur]", g)
        self.assertNotRegex(g, r"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b")

    def test_wordpress_pages_are_drafts_with_root_links_and_bounded_size(self):
        pages = sf.wordpress_pages(self.ws)
        self.assertEqual({p["lang"] for p in pages}, {"fr"})
        home = next(p for p in pages if p["key"] == "home")
        self.assertEqual(home["slug"], "accueil")
        self.assertTrue(home["content"].startswith("<!-- wp:html -->"))
        self.assertIn('href="/contact/"', home["content"])
        for p in pages:
            self.assertEqual(p["fits"], p["bytes"] <= sf.WP_CONTENT_MAX)
        self.assertEqual(len(sf.wordpress_pages(self.ws, ["fr", "en"])), 12)

    def test_traversal_in_meta_path_is_ignored(self):
        fx.edit_src(self.ws, "fr", "services", lambda t: '<!--meta {"title":"Soins de physiothérapie | Atelier Lumen","path":"/../../etc/"} -->\n' + t.split("\n", 1)[1])
        sf.build(self.ws)
        self.assertTrue(os.path.isfile(os.path.join(self.dist, "services", "index.html")))
        self.assertFalse(os.path.exists(os.path.join(self.ws, "site", "etc")))


if __name__ == "__main__":
    unittest.main(verbosity=2)
