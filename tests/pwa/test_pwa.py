"""Tests hors reseau de l'application installable : validateur manifeste/icones, routes statiques
(pwa_static.py), syntaxe JS (node --check), service worker et logique d'installation sous Node, et
"test des tests" (un service worker volontairement casse doit FAIRE ECHOUER la suite).

    python tests/pwa/test_pwa.py        (necessite node pour les tests JS ; ils sont ignores sinon)

Le test avec le vrai serveur est a part : python tests/pwa/e2e_server.py"""
import io
import json
import re
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(REPO, "dashboard"))
sys.path.insert(0, HERE)
import pwa_static  # noqa: E402
import validate_pwa  # noqa: E402

NODE = shutil.which("node")
DASH = os.path.join(REPO, "dashboard")


def make_png(width, height, rgba=(201, 151, 58, 255), color_type=6, pixel=None):
    """PNG minimal (8 bits) pour fabriquer des icones defectueuses."""
    channels = {2: 3, 6: 4}[color_type]
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        for x in range(width):
            px = pixel(x, y) if pixel else rgba
            raw += bytes(px[:channels])

    def chunk(t, body):
        c = struct.pack(">I", len(body)) + t + body
        return c + struct.pack(">I", zlib.crc32(t + body) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw))) + chunk(b"IEND", b""))


def rd(path, binary=False):
    with open(path, "rb" if binary else "r", **({} if binary else {"encoding": "utf-8", "newline": ""})) as f:
        return f.read()


def wr(path, data):
    mode = "wb" if isinstance(data, bytes) else "w"
    with open(path, mode, **({} if isinstance(data, bytes) else {"encoding": "utf-8", "newline": ""})) as f:
        f.write(data)


class FakeHandler:
    def __init__(self, headers=None):
        self.headers = headers or {}
        self.status = None
        self.sent = {}
        self.wfile = io.BytesIO()

    def send_response(self, code):
        self.status = code

    def send_header(self, k, v):
        self.sent[k] = v

    def end_headers(self):
        pass


class ValidatorOnRepo(unittest.TestCase):
    def test_every_check_passes_on_the_repo(self):
        results = validate_pwa.run(REPO)
        failed = [(n, d) for n, ok, d in results if not ok]
        self.assertEqual(failed, [])
        self.assertGreater(len(results), 60)


class ValidatorCatchesDefects(unittest.TestCase):
    """Le validateur doit REELLEMENT detecter les defauts (sinon il ne prouve rien)."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="bkpwa-")
        shutil.copytree(DASH, os.path.join(self.tmp, "dashboard"), ignore=shutil.ignore_patterns("__pycache__", ".gate"))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def edit_manifest(self, fn):
        p = os.path.join(self.tmp, "dashboard", "manifest.json")
        m = json.loads(rd(p))
        fn(m)
        wr(p, json.dumps(m))

    def failing(self):
        return [n for n, ok, _ in validate_pwa.run(self.tmp) if not ok]

    def test_baseline_copy_is_clean(self):
        self.assertEqual(self.failing(), [])

    def test_icon_declared_size_not_matching_real_size(self):
        self.edit_manifest(lambda m: m["icons"][0].update(sizes="256x256"))
        self.assertTrue(any("taille reelle = taille declaree" in n for n in self.failing()), self.failing())

    def test_missing_icon_file(self):
        self.edit_manifest(lambda m: m["icons"].append({"src": "/icons/nope.png", "sizes": "144x144", "type": "image/png", "purpose": "any"}))
        self.assertTrue(any("nope.png" in n and "fichier present" in n for n in self.failing()))

    def test_any_maskable_combined_purpose(self):
        self.edit_manifest(lambda m: m["icons"][1].update(purpose="any maskable"))
        self.assertTrue(any("any maskable" in n for n in self.failing()))

    def test_maskable_icon_with_transparent_corners(self):
        png = make_png(512, 512, pixel=lambda x, y: (201, 151, 58, 0 if (x < 40 and y < 40) else 255))
        wr(os.path.join(self.tmp, "dashboard", "icons", "icon-maskable-512.png"), png)
        self.assertTrue(any("sans aucune transparence" in n for n in self.failing()))

    def test_maskable_mark_outside_safe_zone(self):
        png = make_png(512, 512, pixel=lambda x, y: (255, 255, 255, 255) if (x < 60 and y < 60) else (201, 151, 58, 255))
        wr(os.path.join(self.tmp, "dashboard", "icons", "icon-maskable-512.png"), png)
        self.assertTrue(any("zone de securite" in n for n in self.failing()))

    def test_apple_touch_icon_with_transparency(self):
        png = make_png(180, 180, pixel=lambda x, y: (201, 151, 58, 0 if (x < 10 and y < 10) else 255))
        wr(os.path.join(self.tmp, "dashboard", "icons", "apple-touch-icon.png"), png)
        self.assertTrue(any("sans transparence" in n and "apple-touch-icon" in n for n in self.failing()))

    def test_apple_touch_icon_wrong_size(self):
        wr(os.path.join(self.tmp, "dashboard", "icons", "apple-touch-icon.png"), make_png(152, 152, color_type=2))
        self.assertTrue(any("180x180" in n for n in self.failing()))

    def test_svg_apple_touch_icon_rejected(self):
        p = os.path.join(self.tmp, "dashboard", "index.html")
        s = rd(p).replace('<link rel="apple-touch-icon" href="/icons/apple-touch-icon.png">',
                                                                 '<link rel="apple-touch-icon" href="/icons/apple-touch-icon.png"><link rel="apple-touch-icon" href="/favicon.svg">')
        wr(p, s)
        self.assertTrue(any("toujours en PNG" in n for n in self.failing()))

    def test_portrait_lock_rejected(self):
        self.edit_manifest(lambda m: m.update(orientation="portrait-primary"))
        self.assertTrue(any("orientation" in n for n in self.failing()))

    def test_theme_color_must_match_meta(self):
        self.edit_manifest(lambda m: m.update(theme_color="#14151a"))
        self.assertTrue(any("theme-color" in n for n in self.failing()))

    def test_background_color_must_match_site(self):
        self.edit_manifest(lambda m: m.update(background_color="#14151a"))
        self.assertTrue(any("background_color" in n for n in self.failing()))

    def test_shortcut_outside_scope(self):
        self.edit_manifest(lambda m: m["shortcuts"][0].update(url="https://evil.example/x"))
        self.assertTrue(any("dans le scope" in n and "raccourci" in n for n in self.failing()))

    def test_offline_page_with_external_resource(self):
        p = os.path.join(self.tmp, "dashboard", "offline.html")
        s = rd(p).replace("</head>", '<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=X"></head>')
        wr(p, s)
        self.assertTrue(any("ressource externe" in n for n in self.failing()))

    def test_untranslated_visible_text(self):
        p = os.path.join(self.tmp, "dashboard", "offline.html")
        s = rd(p).replace("</main>", "<p>Une phrase sans traduction.</p></main>")
        wr(p, s)
        self.assertTrue(any("traduction anglaise" in n and "offline.html" in n for n in self.failing()))

    def test_precache_file_missing(self):
        p = os.path.join(self.tmp, "dashboard", "service-worker.js")
        s = rd(p).replace('"/i18n-en-pwa.js",', '"/i18n-en-pwa.js",\n  "/inexistant.js",')
        wr(p, s)
        self.assertTrue(any("/inexistant.js" in n for n in self.failing()))


class PwaStaticRoutes(unittest.TestCase):
    def serve(self, path, headers=None):
        h = FakeHandler(headers)
        handled = pwa_static.serve(h, path, DASH)
        return handled, h

    def test_manifest_content_type(self):
        handled, h = self.serve("/manifest.json")
        self.assertTrue(handled)
        self.assertEqual(h.status, 200)
        self.assertEqual(h.sent["Content-Type"], "application/manifest+json; charset=utf-8")
        self.assertEqual(json.loads(h.wfile.getvalue())["id"], "/?pwa=1")
        self.assertEqual(int(h.sent["Content-Length"]), len(h.wfile.getvalue()))

    def test_service_worker_headers(self):
        _, h = self.serve("/service-worker.js")
        self.assertEqual(h.status, 200)
        self.assertTrue(h.sent["Content-Type"].startswith("text/javascript"))
        self.assertEqual(h.sent["Service-Worker-Allowed"], "/")
        cc = h.sent["Cache-Control"]
        self.assertIn("no-cache", cc)
        self.assertIn("max-age=0", cc)
        self.assertIn("must-revalidate", cc)
        self.assertNotIn("immutable", cc)
        self.assertEqual(h.sent["X-Content-Type-Options"], "nosniff")

    def test_etag_and_304(self):
        _, h1 = self.serve("/service-worker.js")
        etag = h1.sent["ETag"]
        handled, h2 = self.serve("/service-worker.js", {"If-None-Match": etag})
        self.assertTrue(handled)
        self.assertEqual(h2.status, 304)
        self.assertEqual(h2.wfile.getvalue(), b"")
        _, h3 = self.serve("/service-worker.js", {"If-None-Match": '"autre"'})
        self.assertEqual(h3.status, 200)

    def test_static_files_and_types(self):
        expect = {"/offline.html": "text/html", "/pwa-install.js": "text/javascript", "/pwa-install.css": "text/css",
                  "/i18n-en-pwa.js": "text/javascript", "/suppression-compte.html": "text/html"}
        for path, ctype in expect.items():
            handled, h = self.serve(path)
            self.assertTrue(handled, path)
            self.assertEqual(h.status, 200, path)
            self.assertTrue(h.sent["Content-Type"].startswith(ctype), (path, h.sent["Content-Type"]))
            self.assertIn("no-cache", h.sent["Cache-Control"], path)

    def test_icons(self):
        for name in ("icon-192.png", "icon-512.png", "icon-maskable-512.png", "apple-touch-icon.png"):
            handled, h = self.serve("/icons/" + name)
            self.assertTrue(handled)
            self.assertEqual((h.status, h.sent["Content-Type"]), (200, "image/png"), name)
            self.assertEqual(h.wfile.getvalue()[:8], b"\x89PNG\r\n\x1a\n")

    def test_unknown_or_hostile_icon_paths_are_not_files(self):
        for path in ("/icons/nope.png", "/icons/../server.py", "/icons/..%2fserver.py", "/icons/a/b.png", "/icons/.hidden.png",
                     "/icons/icon-192.png/", "/icons/ICON-192.PNG", "/icons/icon-192.png.exe", "/icons/"):
            handled, h = self.serve(path)
            if handled:
                self.assertEqual(h.status, 404, path)
                self.assertNotIn(b"import", h.wfile.getvalue())

    def test_not_a_pwa_path(self):
        for path in ("/", "/app.js", "/api/workers", "/manifest.json/x", "/service-worker.js.map", "/offline"):
            self.assertFalse(pwa_static.handles(path), path)

    def test_assetlinks_absent_is_404_present_is_200(self):
        tmp = tempfile.mkdtemp(prefix="bkpwa-al-")
        try:
            h = FakeHandler()
            self.assertTrue(pwa_static.serve(h, "/.well-known/assetlinks.json", tmp))
            self.assertEqual(h.status, 404)
            os.makedirs(os.path.join(tmp, "well-known"))
            doc = [{"relation": ["delegate_permission/common.handle_all_urls"], "target": {"namespace": "android_app", "package_name": "com.example.app", "sha256_cert_fingerprints": ["AA:BB"]}}]
            wr(os.path.join(tmp, "well-known", "assetlinks.json"), json.dumps(doc))
            h = FakeHandler()
            self.assertTrue(pwa_static.serve(h, "/.well-known/assetlinks.json", tmp))
            self.assertEqual(h.status, 200)
            self.assertTrue(h.sent["Content-Type"].startswith("application/json"))
            self.assertEqual(json.loads(h.wfile.getvalue()), doc)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_apple_app_site_association_absent_is_404_present_is_200(self):
        tmp = tempfile.mkdtemp(prefix="bkpwa-aasa-")
        try:
            h = FakeHandler()
            self.assertTrue(pwa_static.serve(h, "/.well-known/apple-app-site-association", tmp))
            self.assertEqual(h.status, 404)
            os.makedirs(os.path.join(tmp, "well-known"))
            doc = {"applinks": {"details": [{"appIDs": ["TEAMID.com.example.app"], "components": [{"/": "/oauth/*"}]}]}}
            wr(os.path.join(tmp, "well-known", "apple-app-site-association"), json.dumps(doc))
            h = FakeHandler()
            self.assertTrue(pwa_static.serve(h, "/.well-known/apple-app-site-association", tmp))
            self.assertEqual(h.status, 200)
            self.assertTrue(h.sent["Content-Type"].startswith("application/json"))
            self.assertEqual(json.loads(h.wfile.getvalue()), doc)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_store_proof_files_if_present_hold_real_values_not_placeholders(self):
        """Les fichiers de preuve des stores sont facultatifs tant que les apps n'existent pas ; une fois
        ajoutes ils doivent contenir de VRAIES valeurs (jamais le modele de la documentation)."""
        fp = re.compile(r"^([0-9A-F]{2}:){31}[0-9A-F]{2}$")
        path = os.path.join(DASH, "well-known", "assetlinks.json")
        if os.path.exists(path):
            doc = json.loads(rd(path))
            self.assertTrue(doc)
            for st in doc:
                self.assertEqual(st["relation"], ["delegate_permission/common.handle_all_urls"])
                self.assertEqual(st["target"]["namespace"], "android_app")
                self.assertRegex(st["target"]["package_name"], r"^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$")
                self.assertTrue(st["target"]["sha256_cert_fingerprints"])
                for f in st["target"]["sha256_cert_fingerprints"]:
                    self.assertRegex(f, fp, "empreinte SHA-256 invalide ou modele non remplace")
        path = os.path.join(DASH, "well-known", "apple-app-site-association")
        if os.path.exists(path):
            doc = json.loads(rd(path))
            ids = [a for d in doc["applinks"]["details"] for a in d["appIDs"]]
            self.assertTrue(ids)
            for a in ids:
                self.assertRegex(a, r"^[A-Z0-9]{10}\.[A-Za-z0-9.-]+$", "identifiant d'equipe Apple invalide ou modele non remplace")


class StoreAssets(unittest.TestCase):
    STORE = os.path.join(REPO, "docs", "store-assets")

    def info(self, *parts, decode=True):
        return validate_pwa.png_info(rd(os.path.join(*parts), binary=True), decode=decode)

    def test_app_store_icon_is_1024_without_transparency(self):
        i = self.info(self.STORE, "ios-app-icon-1024.png", decode=False)
        self.assertEqual((i["width"], i["height"]), (1024, 1024))
        self.assertFalse(i["has_alpha"], "l'App Store refuse une icone avec transparence")

    def test_play_icon_is_512_square_fully_opaque(self):
        i = self.info(self.STORE, "play-store-icon-512.png")
        self.assertEqual((i["width"], i["height"]), (512, 512))
        self.assertTrue(validate_pwa.opaque(i))

    def test_apple_touch_icon_is_180_without_transparency(self):
        i = self.info(DASH, "icons", "apple-touch-icon.png")
        self.assertEqual((i["width"], i["height"]), (180, 180))
        self.assertTrue(validate_pwa.opaque(i))


class MobileScaffold(unittest.TestCase):
    """mobile/capacitor : configuration relue (la coque n'est pas compilee ici : pas de Mac)."""
    CAP = os.path.join(REPO, "mobile", "capacitor")

    def cfg(self):
        return json.loads(rd(os.path.join(self.CAP, "capacitor.config.json")))

    def test_config_is_valid_and_points_at_the_site(self):
        c = self.cfg()
        self.assertEqual(c["server"]["url"], "https://bk-ai-workers.com/?pwa=1")
        self.assertEqual(c["server"]["allowNavigation"], ["bk-ai-workers.com"])
        self.assertEqual(c["webDir"], "www")
        self.assertRegex(c["appId"], r"^[a-z][a-z0-9]*(\.[a-z][a-z0-9]*)+$")
        self.assertTrue(os.path.isfile(os.path.join(self.CAP, c["webDir"], "index.html")), "Capacitor exige un index.html dans webDir")
        self.assertTrue(os.path.isfile(os.path.join(self.CAP, c["webDir"], c["server"]["errorPath"])))

    def test_user_agent_marker_matches_pwa_install_js(self):
        marker = re.search(r'STORE_UA_MARKER\s*=\s*"([A-Za-z0-9]+)"', rd(os.path.join(DASH, "pwa-install.js"))).group(1)
        self.assertTrue(self.cfg()["appendUserAgent"].startswith(marker + "/"), self.cfg()["appendUserAgent"])

    def test_start_url_matches_manifest(self):
        m = json.loads(rd(os.path.join(DASH, "manifest.json")))
        self.assertEqual(self.cfg()["server"]["url"], "https://bk-ai-workers.com" + m["start_url"])

    def test_bundled_pages_use_no_external_resource_but_the_site(self):
        for name in ("index.html", "offline.html"):
            html = rd(os.path.join(self.CAP, "www", name))
            urls = set(re.findall(r"""(?:src|href)=["'](https?:[^"']+)""", html))
            self.assertEqual(urls, set(), name)
            for u in re.findall(r"https?://[^\s\"')]+", html):
                self.assertTrue(u.startswith("https://bk-ai-workers.com"), (name, u))

    def test_package_json_is_valid_and_private(self):
        p = json.loads(rd(os.path.join(self.CAP, "package.json")))
        self.assertTrue(p["private"])
        for dep in ("@capacitor/core", "@capacitor/ios"):
            self.assertIn(dep, p["dependencies"])
        self.assertIn("@capacitor/cli", p["devDependencies"])


@unittest.skipUnless(NODE, "node introuvable")
class NodeChecks(unittest.TestCase):
    def run_node(self, *args, env=None):
        e = dict(os.environ)
        e.pop("BK_TEST_BASE_URL", None)
        e.update(env or {})
        return subprocess.run([NODE, *args], cwd=REPO, capture_output=True, text=True, env=e, timeout=120, encoding="utf-8", errors="replace")

    def test_node_check_syntax(self):
        files = ["dashboard/service-worker.js", "dashboard/pwa-install.js", "dashboard/i18n-en-pwa.js", "dashboard/app.js",
                 "tests/pwa/test_service_worker.js", "tests/pwa/test_pwa_install.js"]
        for f in files:
            r = self.run_node("--check", f)
            self.assertEqual(r.returncode, 0, f + "\n" + r.stderr)

    def test_inline_scripts_of_the_standalone_pages_parse(self):
        pages = [os.path.join(DASH, "offline.html"), os.path.join(DASH, "suppression-compte.html"),
                 os.path.join(REPO, "mobile", "capacitor", "www", "index.html"), os.path.join(REPO, "mobile", "capacitor", "www", "offline.html")]
        for page in pages:
            html = rd(page)
            for i, src in enumerate(re.findall(r"<script>(.*?)</script>", html, re.S)):
                tmp = os.path.join(tempfile.mkdtemp(prefix="bkpwa-js-"), "inline.js")
                wr(tmp, src)
                r = self.run_node("--check", tmp)
                shutil.rmtree(os.path.dirname(tmp), ignore_errors=True)
                self.assertEqual(r.returncode, 0, f"{page} script #{i}\n{r.stderr}")

    def test_service_worker_suite(self):
        r = self.run_node("tests/pwa/test_service_worker.js")
        self.assertEqual(r.returncode, 0, r.stdout[-3000:] + r.stderr)
        self.assertIn("controles passes", r.stdout)
        self.assertNotIn("FAIL", r.stdout)

    def test_install_logic_suite(self):
        r = self.run_node("tests/pwa/test_pwa_install.js")
        self.assertEqual(r.returncode, 0, r.stdout[-3000:] + r.stderr)

    def test_the_sw_suite_fails_on_broken_service_workers(self):
        """Test des tests : chaque variante cassee doit etre refusee par test_service_worker.js."""
        src = rd(os.path.join(DASH, "service-worker.js")).replace("\r\n", "\n")
        mutants = {
            "intercepte /api/": ('["/api/", "/oauth/"', '["/oauth/"'),
            "cache-d'abord sur les statiques": ("async function handleStatic(request) {\n  try {",
                                                "async function handleStatic(request) {\n  const hit = await caches.match(request);\n  if (hit) return hit;\n  try {"),
            "met les pages en cache": ("    return response;\n  } catch (e) {\n    return offlineResponse(200);",
                                       "    caches.open(CACHE_NAME).then((c) => c.put(request, response.clone()));\n    return response;\n  } catch (e) {\n    return offlineResponse(200);"),
            "ignore no-store/private": ('if (cacheControl.includes("no-store") || cacheControl.includes("private")) return false;', ""),
            "intercepte les POST": ('request.method !== "GET" || url.origin', "url.origin"),
            "installe sans page de secours": ('await Promise.all(PRECACHE_REQUIRED.map((u) => cache.add(new Request(u, { cache: "reload" }))));',
                                              'await Promise.allSettled(PRECACHE_REQUIRED.map((u) => cache.add(new Request(u, { cache: "reload" }))));'),
            "ne nettoie pas les anciens caches": ("names.filter((n) => n.startsWith(CACHE_PREFIX) && n !== CACHE_NAME)", "[]"),
            "stocke les 5xx de navigation": ("response.status === 502 || response.status === 503 || response.status === 504", "false"),
            "ignore l'en-tete Authorization": ('request.headers.has("Authorization")', "false"),
        }
        tmp = tempfile.mkdtemp(prefix="bkpwa-mut-")
        try:
            for name, (old, new) in mutants.items():
                self.assertIn(old, src, name)
                path = os.path.join(tmp, "sw.js")
                wr(path, src.replace(old, new))
                r = self.run_node("tests/pwa/test_service_worker.js", env={"BK_SW_FILE": path})
                self.assertNotEqual(r.returncode, 0, f"la suite n'a PAS detecte : {name}")
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
