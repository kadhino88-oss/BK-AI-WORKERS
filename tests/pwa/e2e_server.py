"""Bout en bout : le VRAI serveur (dashboard/server.py) demarre sur une copie jetable du depot, sur un
port libre choisi par le systeme (jamais un port fixe, jamais les vraies donnees), puis de vraies requetes
HTTP verifient tout ce qui rend l'application installable :

  - manifeste servi en application/manifest+json, chaque icone servie avec sa taille declaree ;
  - service worker : type JS, jamais de cache long, Service-Worker-Allowed, ETag/304 ;
  - page hors connexion + ses dependances, page "supprimer mon compte", invitation a installer ;
  - /.well-known/assetlinks.json : 404 tant que le fichier n'existe pas, JSON des qu'il existe ;
  - chemins hostiles sous /icons/ : jamais de fichier du serveur ;
  - les anciennes routes (/, /app.js, /style.css, /api/workers...) fonctionnent toujours ;
  - le service worker REEL, execute sous Node contre ce serveur (tests/pwa/test_service_worker.js).

Lancer (Windows, Linux ou WSL, Python 3 + node) : python tests/pwa/e2e_server.py"""
import http.client
import json
import os
import shutil
import subprocess
import sys
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
import validate_pwa  # noqa: E402
from testserver import TestServer  # noqa: E402

failures = []


def check(name, cond, detail=""):
    print(("  PASS  " if cond else "  FAIL  ") + name + (f"  [{detail}]" if detail and not cond else ""))
    if not cond:
        failures.append(name)


def get(port, path, headers=None):
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, dict(r.headers), r.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()


def raw_get(port, path):
    """Chemin envoye tel quel (urllib normalise les '..')."""
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=20)
    conn.request("GET", path)
    r = conn.getresponse()
    body = r.read()
    conn.close()
    return r.status, body


def main():
    srv = TestServer(REPO)
    try:
        srv.start()
        port, copy = srv.port, srv.copy
        print(f"serveur de test sur 127.0.0.1:{port} (copie jetable {copy})")

        print("manifeste et icones")
        st, h, body = get(port, "/manifest.json")
        check("/manifest.json 200", st == 200, st)
        check("Content-Type = application/manifest+json", h.get("Content-Type", "").split(";")[0] == "application/manifest+json", h.get("Content-Type"))
        check("manifeste revalide (no-cache), jamais de cache long", "no-cache" in h.get("Cache-Control", "") and "max-age=0" in h.get("Cache-Control", ""), h.get("Cache-Control"))
        manifest = json.loads(body)
        with open(os.path.join(REPO, "dashboard", "manifest.json"), "rb") as f:
            check("le manifeste servi = le fichier du depot", json.loads(f.read()) == manifest)
        for ic in manifest["icons"]:
            st, h, data = get(port, ic["src"])
            info = validate_pwa.png_info(data) if st == 200 else {}
            check(f"{ic['src']}: 200 image/png, {ic['sizes']} reels", st == 200 and h.get("Content-Type") == "image/png" and f"{info.get('width')}x{info.get('height')}" == ic["sizes"], (st, h.get("Content-Type"), info.get("width")))
            if ic.get("purpose") == "maskable":
                check(f"{ic['src']}: sans transparence", validate_pwa.opaque(info))
        st, h, data = get(port, "/icons/apple-touch-icon.png")
        info = validate_pwa.png_info(data)
        check("/icons/apple-touch-icon.png: 180x180 sans transparence", st == 200 and (info["width"], info["height"]) == (180, 180) and validate_pwa.opaque(info))
        for sc in manifest["shortcuts"]:
            st, h, data = get(port, sc["url"])
            check(f"raccourci {sc['name']}: {sc['url']} ouvre l'application (200 HTML)", st == 200 and b"pwa-install.js" in data and h.get("Content-Type", "").startswith("text/html"), st)

        print("service worker")
        st, h, body = get(port, "/service-worker.js")
        check("/service-worker.js 200 en JavaScript", st == 200 and "javascript" in h.get("Content-Type", ""), h.get("Content-Type"))
        cc = h.get("Cache-Control", "")
        check("service worker: pas de cache long (no-cache, max-age=0, must-revalidate)", "no-cache" in cc and "max-age=0" in cc and "must-revalidate" in cc, cc)
        check("service worker: Service-Worker-Allowed: /", h.get("Service-Worker-Allowed") == "/", h.get("Service-Worker-Allowed"))
        check("service worker: nosniff", h.get("X-Content-Type-Options") == "nosniff")
        etag = h.get("ETag")
        st2, h2, b2 = get(port, "/service-worker.js", {"If-None-Match": etag})
        check("service worker: 304 si inchange (ETag)", st2 == 304 and b2 == b"", st2)
        with open(os.path.join(REPO, "dashboard", "service-worker.js"), "rb") as f:
            check("le service worker servi = le fichier du depot", f.read() == body)

        print("pages et dependances")
        st, h, body = get(port, "/offline.html")
        check("/offline.html 200 HTML, FR", st == 200 and h.get("Content-Type", "").startswith("text/html") and "Vous êtes hors connexion".encode() in body, st)
        for p, t in (("/i18n.js", "javascript"), ("/i18n-en-pwa.js", "javascript"), ("/pwa-install.js", "javascript"), ("/pwa-install.css", "text/css"), ("/favicon.svg", "svg")):
            st, h, _ = get(port, p)
            check(f"{p}: 200 {t}", st == 200 and t in h.get("Content-Type", ""), (st, h.get("Content-Type")))
        st, h, body = get(port, "/suppression-compte.html")
        check("/suppression-compte.html 200 (page publique, sans compte)", st == 200 and "Supprimer mon compte".encode() in body)
        st, h, body = get(port, "/")
        check("/ : manifeste, apple-touch-icon PNG, invitation a installer branches", st == 200 and b'rel="manifest"' in body and b"/icons/apple-touch-icon.png" in body and b"/pwa-install.js" in body and b"footer-install-app" in body)
        check("/ : plus aucune apple-touch-icon SVG", b'rel="apple-touch-icon" href="/favicon.svg"' not in body)

        print("preuve de propriete Android")
        st, h, body = get(port, "/.well-known/assetlinks.json")
        check("assetlinks.json: 404 tant que le fichier n'existe pas (jamais de fausse empreinte)", st == 404, st)
        doc = [{"relation": ["delegate_permission/common.handle_all_urls"], "target": {"namespace": "android_app", "package_name": "com.example.test", "sha256_cert_fingerprints": ["00:11"]}}]
        os.makedirs(os.path.join(copy, "dashboard", "well-known"), exist_ok=True)
        with open(os.path.join(copy, "dashboard", "well-known", "assetlinks.json"), "w", encoding="utf-8") as f:
            json.dump(doc, f)
        st, h, body = get(port, "/.well-known/assetlinks.json")
        check("assetlinks.json: 200 application/json des que le fichier existe, sans redirection", st == 200 and h.get("Content-Type", "").startswith("application/json") and json.loads(body) == doc, (st, h.get("Content-Type")))

        st, h, body = get(port, "/.well-known/apple-app-site-association")
        check("apple-app-site-association: 404 tant que le fichier n'existe pas", st == 404, st)
        aasa = {"applinks": {"details": [{"appIDs": ["TEAMID.com.example.test"], "components": [{"/": "/oauth/*"}]}]}}
        with open(os.path.join(copy, "dashboard", "well-known", "apple-app-site-association"), "w", encoding="utf-8") as f:
            json.dump(aasa, f)
        st, h, body = get(port, "/.well-known/apple-app-site-association")
        check("apple-app-site-association: 200 application/json des que le fichier existe", st == 200 and h.get("Content-Type", "").startswith("application/json") and json.loads(body) == aasa, (st, h.get("Content-Type")))

        print("chemins hostiles")
        for p in ("/icons/nope.png", "/icons/../server.py", "/icons/..%2fserver.py", "/icons/%2e%2e/server.py", "/icons/a/../../server.py", "/icons/.png", "/icons/", "/icons/icon-192.png%00.txt"):
            st, body = raw_get(port, p)
            check(f"{p}: jamais un fichier du serveur", st in (404, 400) and b"import " not in body and b"BaseHTTPRequestHandler" not in body, (st, body[:60]))

        print("anciennes routes toujours en place")
        for p, t in (("/app.js", "javascript"), ("/style.css", "text/css"), ("/api/workers", "application/json"), ("/robots.txt", "text/plain"), ("/confidentialite.html", "text/html")):
            st, h, _ = get(port, p)
            check(f"{p}: 200 {t}", st == 200 and t in h.get("Content-Type", ""), (st, h.get("Content-Type")))
        st, h, body = get(port, "/api/workers")
        check("/api/workers: pas d'en-tete de cache ajoute par erreur (donnees dynamiques)", "max-age" not in h.get("Cache-Control", "").replace("max-age=0", ""), h.get("Cache-Control"))

        print("service worker reel (Node) contre ce serveur")
        node = shutil.which("node")
        if not node:
            check("node disponible", False, "installer Node.js")
        else:
            r = subprocess.run([node, os.path.join(REPO, "tests", "pwa", "test_service_worker.js")], env=dict(os.environ, BK_TEST_BASE_URL=f"http://127.0.0.1:{port}"),
                               capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=180)
            tail = [ln for ln in r.stdout.splitlines() if "FAIL" in ln or "controles passes" in ln]
            check("test_service_worker.js contre le vrai serveur", r.returncode == 0, "\n".join(tail) + r.stderr[-500:])
            print("      " + (tail[-1].strip() if tail else ""))
    finally:
        srv.cleanup()
    print()
    if failures:
        print(f"{len(failures)} ECHEC(S) : " + "; ".join(failures))
        sys.exit(1)
    print("Tous les controles de bout en bout passent.")


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    main()
