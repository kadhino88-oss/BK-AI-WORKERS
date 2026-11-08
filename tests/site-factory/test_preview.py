# -*- coding: utf-8 -*-
"""Aperçu privé (dashboard/site_preview.py) : en-têtes exacts sur CHAQUE réponse (CSP sandbox sans allow-same-origin), 404 identiques
(jeton inconnu, expiré, révoqué, chemin piégé), corpus de chemins hostiles, liens symboliques, plafonds, débit, cloisonnement entre clients,
bandeau, aucun cookie lu ni posé, et dormance quand BK_PROJECTS=0.

    python tests/site-factory/test_preview.py"""
import io
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fixtures as fx  # noqa: E402
import site_preview as sp  # noqa: E402

CLIENT_A = "CLI-CUST-AAAAAAAA"
CLIENT_B = "CLI-CUST-BBBBBBBB"
PID_A = "PRJ-" + "A" * 32
PID_B = "PRJ-" + "B" * 32
EXPECTED_CSP = ("sandbox allow-scripts allow-popups allow-popups-to-escape-sandbox; default-src 'none'; img-src 'self' data:; "
                "style-src 'self' 'unsafe-inline'; font-src 'self' data:; script-src 'self'; media-src 'self'; connect-src 'none'; frame-src 'none'; "
                "object-src 'none'; form-action 'none'; base-uri 'none'; frame-ancestors 'self'")


class FakeHandler:
    """Imite BaseHTTPRequestHandler : statut, en-têtes, corps ; note toute lecture d'en-tête (cookies)."""

    def __init__(self, path, cookie="session=SECRET"):
        self.path = path
        self.status = None
        self.headers_out = []
        self.wfile = io.BytesIO()
        self.read_headers = []
        outer = self

        class H(dict):
            def get(self, k, d=None):
                outer.read_headers.append(k.lower())
                return dict.get(self, k, d)

            def __getitem__(self, k):
                outer.read_headers.append(k.lower())
                return dict.__getitem__(self, k)

        self.headers = H({"Cookie": cookie})

    def send_response(self, code, message=None):
        self.status = code

    def send_header(self, k, v):
        self.headers_out.append((k, v))

    def end_headers(self):
        pass

    def header(self, name):
        vals = [v for k, v in self.headers_out if k.lower() == name.lower()]
        return vals[0] if vals else None

    @property
    def body(self):
        return self.wfile.getvalue()


class PreviewTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="bk-prev-")
        self.addCleanup(shutil.rmtree, self.root, True)
        self.clock = [1_800_000_000.0]
        self.on = [True]
        self.pv = sp.SitePreview(self.root, enabled=lambda: self.on[0], now=lambda: self.clock[0], banner=True, base_url="")
        for cid, pid in ((CLIENT_A, PID_A), (CLIENT_B, PID_B)):
            ws = os.path.join(self.root, "runtime", "projects", cid, pid, "workspace")
            os.makedirs(ws)
            fx.make_good_site(ws)
        self.dist_a = os.path.join(self.root, "runtime", "projects", CLIENT_A, PID_A, "workspace", "site", "dist")
        self.tok = self.pv.create(CLIENT_A, PID_A)["token"]

    def get(self, path, **kw):
        h = FakeHandler(path, **kw)
        handled = self.pv.handle_get(h, path.split("?")[0])
        return handled, h

    def assert_security_headers(self, h):
        self.assertEqual(h.header("Content-Security-Policy"), EXPECTED_CSP)
        self.assertIn("sandbox", h.header("Content-Security-Policy"))
        self.assertNotIn("allow-same-origin", h.header("Content-Security-Policy"))
        self.assertEqual(h.header("X-Content-Type-Options"), "nosniff")
        self.assertEqual(h.header("X-Robots-Tag"), "noindex, nofollow, noarchive")
        self.assertEqual(h.header("Referrer-Policy"), "no-referrer")
        self.assertEqual(h.header("Cache-Control"), "private, no-store")
        self.assertEqual(h.header("Cross-Origin-Opener-Policy"), "same-origin")
        self.assertIsNone(h.header("Set-Cookie"))
        self.assertIsNone(h.header("Access-Control-Allow-Origin"))
        self.assertIsNone(h.header("Cross-Origin-Resource-Policy"))
        self.assertNotIn("cookie", h.read_headers)

    def test_serves_pages_with_exact_headers_and_banner(self):
        handled, h = self.get(f"/preview/{self.tok}/")
        self.assertTrue(handled)
        self.assertEqual(h.status, 200)
        self.assert_security_headers(h)
        self.assertEqual(h.header("Content-Type"), "text/html; charset=utf-8")
        self.assertIn("Aperçu privé BK-AI-WORKERS — non publié".encode("utf-8"), h.body)
        self.assertIn(b"Retrouver le plaisir de bouger", h.body)
        for path, ctype in (("en/about/", "text/html; charset=utf-8"), ("assets/style.css", "text/css; charset=utf-8"),
                            ("assets/img/og.png", "image/png"), ("assets/favicon.svg", "image/svg+xml"), ("sitemap.xml", "application/xml; charset=utf-8"),
                            ("robots.txt", "text/plain; charset=utf-8")):
            _x, h = self.get(f"/preview/{self.tok}/{path}")
            self.assertEqual(h.status, 200, path)
            self.assertEqual(h.header("Content-Type"), ctype, path)
            self.assert_security_headers(h)
        _x, h = self.get(f"/preview/{self.tok}")
        self.assertEqual(h.status, 302)
        self.assertEqual(h.header("Location"), f"/preview/{self.tok}/")
        self.assert_security_headers(h)

    def test_unknown_expired_revoked_and_invalid_give_the_same_404(self):
        bodies = []
        _x, h = self.get(f"/preview/{'Z' * 32}/")
        bodies.append((h.status, h.body, h.header("Content-Type")))
        self.assert_security_headers(h)
        _x, h = self.get(f"/preview/{self.tok}/inexistant.html")
        bodies.append((h.status, h.body, h.header("Content-Type")))
        _x, h = self.get("/preview/court/")
        bodies.append((h.status, h.body, h.header("Content-Type")))
        self.clock[0] += 73 * 3600
        _x, h = self.get(f"/preview/{self.tok}/")
        bodies.append((h.status, h.body, h.header("Content-Type")))
        self.clock[0] -= 73 * 3600
        tok2 = self.pv.create(CLIENT_A, PID_A)["token"]
        _x, h = self.get(f"/preview/{self.tok}/")                 # l'ancien lien est révoqué par la création d'un nouveau
        bodies.append((h.status, h.body, h.header("Content-Type")))
        self.assertEqual(self.get(f"/preview/{tok2}/")[1].status, 200)
        self.pv.revoke(CLIENT_A, PID_A)
        _x, h = self.get(f"/preview/{tok2}/")
        bodies.append((h.status, h.body, h.header("Content-Type")))
        self.assertEqual(len(set(bodies)), 1, bodies)
        self.assertEqual(bodies[0][0], 404)

    def test_hostile_path_corpus_is_refused(self):
        secret = os.path.join(self.root, "runtime", "projects", CLIENT_A, PID_A, "state.json")
        with open(secret, "w", encoding="utf-8") as f:
            f.write('{"secret": "ne-doit-pas-sortir"}')
        with open(os.path.join(self.dist_a, ".env.txt"), "w") as f:
            f.write("SECRET")
        corpus = ["../state.json", "..%2fstate.json", "%2e%2e/state.json", "%2e%2e%2fstate.json", "%252e%252e/state.json", "..%5cstate.json",
                  "assets/..%2f..%2fstate.json", "assets\\..\\..\\state.json", "%00index.html", "index.html%00.png", ".env.txt", "assets/.hidden.css",
                  "/etc/passwd", "//etc/passwd", "C:/Windows/win.ini", "assets//style.css", "./index.html", "assets/./style.css",
                  "index.html.bak", "site.json", "../../workspace/site/site.json", "assets/", "en", "index.HTML/../state.json",
                  "%c0%ae%c0%ae/state.json"]
        for p in corpus:
            _x, h = self.get(f"/preview/{self.tok}/{p}")
            self.assertIn(h.status, (404,), p)
            self.assertNotIn(b"ne-doit-pas-sortir", h.body, p)
            self.assertNotIn(b"SECRET", h.body, p)
            self.assert_security_headers(h)
        # « assets/style.css?x=… » : la requête est ignorée, le fichier demandé reste style.css (200) — pas une évasion
        _x, h = self.get(f"/preview/{self.tok}/assets/style.css?x=../../state.json")
        self.assertEqual(h.status, 200)
        self.assertIn(b"--primary", h.body)

    def test_resolve_request_rules(self):
        r = self.pv.resolve_request
        t = "A" * 32
        self.assertEqual(r(f"/preview/{t}/"), (t, ["index.html"]))
        self.assertEqual(r(f"/preview/{t}/en/about/"), (t, ["en", "about", "index.html"]))
        self.assertEqual(r(f"/preview/{t}/caf%C3%A9.css"), None)        # segment hors règle (accent) : refusé
        self.assertIsNone(r(f"/preview/{t}/a%252fb.css"))
        self.assertIsNone(r(f"/preview/{t}/x.php"))
        self.assertIsNone(r(f"/preview/{t}/x.html.exe"))
        self.assertEqual(r(f"/preview/{t}"), (t, None))

    @unittest.skipIf(os.name == "nt" and not hasattr(os, "symlink"), "liens symboliques indisponibles")
    def test_symlinks_are_never_followed(self):
        target = os.path.join(self.root, "runtime", "projects", CLIENT_B, PID_B, "workspace", "site", "dist", "index.html")
        link = os.path.join(self.dist_a, "lien.html")
        dlink = os.path.join(self.dist_a, "autre")
        try:
            os.symlink(target, link)
            os.symlink(os.path.dirname(target), dlink, target_is_directory=True)
        except (OSError, NotImplementedError):
            self.skipTest("création de lien symbolique refusée par le système")
        for p in ("lien.html", "autre/index.html", "autre/"):
            _x, h = self.get(f"/preview/{self.tok}/{p}")
            self.assertEqual(h.status, 404, p)

    def test_token_is_scoped_to_its_own_client_and_project(self):
        tok_b = self.pv.create(CLIENT_B, PID_B)["token"]
        _x, ha = self.get(f"/preview/{self.tok}/")
        _x, hb = self.get(f"/preview/{tok_b}/")
        self.assertEqual((ha.status, hb.status), (200, 200))
        self.assertNotEqual(ha.body, b"")
        # le jeton de A ne donne jamais accès au dossier de B, même en forgeant le chemin
        for p in (f"../../../{CLIENT_B}/{PID_B}/workspace/site/dist/index.html", f"..%2f..%2f..%2f{CLIENT_B}%2f{PID_B}%2fworkspace%2fsite%2fdist%2findex.html"):
            self.assertEqual(self.get(f"/preview/{self.tok}/{p}")[1].status, 404)
        # un enregistrement de jeton falsifié (identifiants invalides) ne sort jamais de runtime/projects
        forged = "F" * 32
        self.pv._save(forged, {"projectId": "../../..", "clientId": "../..", "createdUtc": "2027-01-01T00:00:00Z", "expiresUtc": "2099-01-01T00:00:00Z", "revoked": False})
        self.assertEqual(self.get(f"/preview/{forged}/")[1].status, 404)
        # révoquer côté A ne touche pas B ; info() ne voit que le projet demandé
        self.pv.revoke(CLIENT_A, PID_A)
        self.assertEqual(self.get(f"/preview/{tok_b}/")[1].status, 200)
        self.assertFalse(self.pv.info(CLIENT_A, PID_A)["active"])
        self.assertTrue(self.pv.info(CLIENT_B, PID_B)["active"])
        self.assertFalse(self.pv.info(CLIENT_A, PID_B)["active"])      # B's project seen by A: nothing

    def test_tokens_are_long_random_and_never_reused(self):
        toks = {self.pv.create(CLIENT_A, PID_A)["token"] for _ in range(20)}
        self.assertEqual(len(toks), 20)
        self.assertTrue(all(sp.TOKEN_RE.match(t) and len(t) == 32 for t in toks))

    def test_expiry_bounds_and_refresh(self):
        out = self.pv.create(CLIENT_A, PID_A, hours=10_000)
        self.assertEqual(sp._parse_iso(out["expiresUtc"]) - self.clock[0], 14 * 24 * 3600)
        out = self.pv.create(CLIENT_A, PID_A, hours=1)
        self.clock[0] += 1800
        new_exp = self.pv.refresh(PID_A)
        self.assertEqual(sp._parse_iso(new_exp) - self.clock[0], 72 * 3600)
        self.clock[0] += 13 * 24 * 3600
        self.pv.refresh(PID_A)
        self.clock[0] += 3 * 24 * 3600
        self.assertEqual(self.get(f"/preview/{out['token']}/")[1].status, 404)    # jamais au-delà de 14 jours après la création

    def test_size_caps(self):
        with open(os.path.join(self.dist_a, "assets", "grosse.png"), "wb") as f:
            f.write(b"\x89PNG" + b"0" * (5 * 1024 * 1024 + 10))
        self.assertEqual(self.get(f"/preview/{self.tok}/assets/grosse.png")[1].status, 404)
        os.remove(os.path.join(self.dist_a, "assets", "grosse.png"))
        for i in range(6):
            with open(os.path.join(self.dist_a, "assets", f"bloc{i}.png"), "wb") as f:
                f.write(b"\x89PNG" + b"0" * (4 * 1024 * 1024 + 500 * 1024))
        os.utime(os.path.join(self.dist_a, "..", "build.json"))
        self.pv._dist_cache.clear()
        self.assertEqual(self.get(f"/preview/{self.tok}/")[1].status, 404)            # dist/ > 25 Mo : rien n'est servi

    def test_rate_limit_per_token(self):
        codes = [self.get(f"/preview/{self.tok}/robots.txt")[1].status for _ in range(sp.RATE_PER_MIN + 3)]
        self.assertEqual(codes[:sp.RATE_PER_MIN], [200] * sp.RATE_PER_MIN)
        self.assertEqual(codes[-1], 429)
        self.clock[0] += 61
        self.assertEqual(self.get(f"/preview/{self.tok}/robots.txt")[1].status, 200)

    def test_dormant_when_projects_disabled_and_other_paths_untouched(self):
        self.on[0] = False
        handled, h = self.get(f"/preview/{self.tok}/")
        self.assertFalse(handled)
        self.assertIsNone(h.status)
        self.on[0] = True
        for p in ("/", "/index.html", "/api/projects", "/previews/x", "/preview-x"):
            handled, h = self.get(p)
            self.assertFalse(handled, p)

    def test_banner_can_be_disabled(self):
        pv = sp.SitePreview(self.root, enabled=lambda: True, now=lambda: self.clock[0], banner=False)
        h = FakeHandler(f"/preview/{self.tok}/")
        pv.handle_get(h, h.path)
        self.assertNotIn("Aperçu privé".encode("utf-8"), h.body)

    def test_purge_client_removes_its_tokens_only(self):
        tok_b = self.pv.create(CLIENT_B, PID_B)["token"]
        self.assertEqual(self.pv.purge_client(CLIENT_A), 1)
        self.assertEqual(self.get(f"/preview/{self.tok}/")[1].status, 404)
        self.assertEqual(self.get(f"/preview/{tok_b}/")[1].status, 200)

    def test_sweep_removes_old_dead_tokens_and_purge_project_removes_all_of_one_project(self):
        tok_b = self.pv.create(CLIENT_B, PID_B)["token"]
        self.pv.revoke(CLIENT_A, PID_A)
        self.assertEqual(self.pv.sweep(), 0, "un jeton qui vient d'expirer ou d'etre revoque est garde (delai de grace)")
        old = self.pv.now
        self.pv.now = lambda: old() + 20 * 86400
        try:
            self.assertEqual(self.pv.sweep(), 2, "apres le delai, jetons expires ou revoques supprimes")
        finally:
            self.pv.now = old
        tok_c = self.pv.create(CLIENT_A, PID_A)["token"]
        self.assertEqual(self.pv.purge_project(PID_A), 1)
        self.assertEqual(self.get(f"/preview/{tok_c}/")[1].status, 404)


if __name__ == "__main__":
    unittest.main(verbosity=2)
