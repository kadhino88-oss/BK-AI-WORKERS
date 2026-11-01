# -*- coding: utf-8 -*-
"""Pages publiques de Workers (/workers/<id>.html) : contenu reel, structure, donnees de referencement, routes, plan du site.

    python tests/seo/test_worker_pages.py

Rien n'est invente : chaque texte vient de workers/<id>/install-profile.json, identity.json ou de la grille de prix ; le test le verifie.
"""
import html as import_html
import http.client
import importlib
import json
import os
import re
import sys
import threading
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
os.environ.setdefault("BK_ROOT", REPO)
sys.path.insert(0, os.path.join(REPO, "dashboard"))
os.environ["BK_PUBLIC_URL"] = "https://bk-ai-workers.com"
import server  # noqa: E402
import seo_pages  # noqa: E402


def profile_of(wid):
    with open(os.path.join(REPO, "workers", wid, "install-profile.json"), encoding="utf-8-sig") as f:
        return json.load(f)


IDS = server.get_worker_ids()
EVERYONE = [server.build_worker_summary(w) for w in IDS]


def render(wid):
    me = next(w for w in EVERYONE if w["id"] == wid)
    return seo_pages.render_worker_page(me, profile_of(wid), EVERYONE)


def ld_graph(html):
    blocks = re.findall(r'<script type="application/ld\+json">(.*?)</script>', html, re.S)
    assert len(blocks) == 1, "un seul bloc JSON-LD attendu"
    return json.loads(blocks[0])["@graph"]


class Pages(unittest.TestCase):
    def test_there_is_one_page_per_catalogue_worker(self):
        self.assertEqual(len(IDS), 17)

    def test_every_page_has_the_expected_structure(self):
        for wid in IDS:
            with self.subTest(worker=wid):
                html = render(wid)
                p = profile_of(wid)
                self.assertEqual(html.count("<h1>"), 1)
                title = re.search(r"<title>(.*?)</title>", html).group(1)
                self.assertLessEqual(len(title), 80, title)
                desc = re.search(r'<meta name="description" content="(.*?)">', html).group(1)
                self.assertTrue(50 <= len(desc) <= 220, f"{len(desc)} : {desc}")
                self.assertIn(f'<link rel="canonical" href="https://bk-ai-workers.com/workers/{wid}.html">', html)
                self.assertIn(f'property="og:image" content="https://bk-ai-workers.com/portraits/{wid}.', html)
                self.assertIn(p["tagline"].replace("&", "&amp;"), html)
                for svc in p["services"]:
                    self.assertIn(svc["label"].replace("&", "&amp;"), html, "chaque service de la fiche est affiche")
                self.assertIn('href="/tarifs.html"', html)
                self.assertIn('href="/workers.html"', html)
                # liens vers les 16 autres pages (maillage interne)
                for other in IDS:
                    if other != wid:
                        self.assertIn(f'href="/workers/{other}.html"', html)

    def test_page_only_states_what_the_profile_says(self):
        for wid in IDS:
            with self.subTest(worker=wid):
                html = render(wid)
                text = re.sub(r"<[^>]+>", " ", re.search(r"<main>.*</main>", html, re.S).group(0)).lower()
                for banned in ("illimité", "4,9", "★", "+1000", "30 000", "aggregaterating"):
                    self.assertNotIn(banned, text, f"{wid} : « {banned} » n'a aucune source")
                for item in profile_of(wid)["plannedCapabilities"][:6]:
                    self.assertIn(item[:40], import_html.unescape(html), "le prevu est montre comme prevu")
                self.assertIn("Prévu, pas encore disponible", html)

    def test_json_ld_matches_the_visible_page(self):
        for wid in IDS:
            with self.subTest(worker=wid):
                html = render(wid)
                graph = {g["@type"]: g for g in ld_graph(html)}
                self.assertEqual(set(graph), {"WebPage", "BreadcrumbList", "FAQPage"})
                self.assertEqual([i["position"] for i in graph["BreadcrumbList"]["itemListElement"]], [1, 2, 3])
                self.assertGreaterEqual(len(graph["FAQPage"]["mainEntity"]), 4)
                import html as H
                visible = H.unescape(re.sub(r"<[^>]+>", " ", html))
                visible = re.sub(r"\s+", " ", visible)
                for q in graph["FAQPage"]["mainEntity"]:
                    self.assertIn(q["name"], visible)
                    self.assertIn(re.sub(r"\s+", " ", q["acceptedAnswer"]["text"]), visible, "la reponse du JSON-LD est celle affichee")
                self.assertNotIn("aggregateRating", html)
                self.assertNotIn('"Review"', html)

    def test_prices_come_from_the_price_list(self):
        solo = next(p for p in seo_pages.PRICING_PLANS if p["id"] == "solo")
        essai = next(p for p in seo_pages.PRICING_PLANS if p["id"] == "essai")
        html = render("alex")
        self.assertIn(f"{solo['price']} CHF par mois, {solo['credits']} crédits", html)
        self.assertIn(f"{essai['credits']} crédits, sans carte bancaire", html)

    def test_text_from_a_profile_cannot_inject_markup(self):
        me = dict(EVERYONE[0], name='<img src=x onerror=alert(1)>', role='a</h1><script>alert(1)</script>')
        prof = dict(profile_of(EVERYONE[0]["id"]), tagline='"><script>alert(2)</script></script>')
        html = seo_pages.render_worker_page(me, prof, EVERYONE)
        self.assertNotIn("<script>alert", html)
        self.assertNotIn("<img src=x", html)
        self.assertEqual(len(re.findall(r'<script type="application/ld\+json">', html)), 1)
        json.loads(re.search(r'<script type="application/ld\+json">(.*?)</script>', html, re.S).group(1))

    def test_page_without_profile_still_renders(self):
        me = EVERYONE[0]
        html = seo_pages.render_worker_page(me, None, EVERYONE)
        self.assertIn("<h1>", html)
        self.assertNotIn("None", re.sub(r"<[^>]+>", " ", html))

    def test_workers_list_links_every_card(self):
        html = seo_pages.render_workers_page(EVERYONE)
        for wid in IDS:
            self.assertIn(f'href="/workers/{wid}.html"', html)


class Routes(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.httpd = server.ThreadingHTTPServer(("127.0.0.1", 0), server.Handler)
        threading.Thread(target=cls.httpd.serve_forever, daemon=True).start()
        cls.port = cls.httpd.server_address[1]

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.httpd.server_close()

    def get(self, path):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=15)
        c.request("GET", path)
        r = c.getresponse()
        return r.status, dict((k.lower(), v) for k, v in r.getheaders()), r.read().decode("utf-8", "replace")

    def test_each_worker_page_is_served_as_html(self):
        for wid in IDS:
            status, headers, body = self.get(f"/workers/{wid}.html")
            self.assertEqual(status, 200, wid)
            self.assertIn("text/html", headers["content-type"])
            self.assertIn("<h1>", body)
            self.assertEqual(headers.get("x-content-type-options"), "nosniff")

    def test_unknown_or_hostile_paths_are_404(self):
        for path in ("/workers/atlas.html", "/workers/inconnu.html", "/workers/.html", "/workers/../server.py.html",
                     "/workers/%2e%2e/index.html", "/workers/alex.html/x", "/workers/ALEX.html"):
            status, _, _ = self.get(path)
            self.assertIn(status, (404, 400), path)

    def test_sitemap_lists_the_worker_pages(self):
        status, _, body = self.get("/sitemap.xml")
        self.assertEqual(status, 200)
        for wid in IDS:
            self.assertIn(f"/workers/{wid}.html</loc>", body)
        self.assertEqual(body.count("<loc>"), len(set(re.findall(r"<loc>(.*?)</loc>", body))), "aucune adresse en double")


if __name__ == "__main__":
    unittest.main()
