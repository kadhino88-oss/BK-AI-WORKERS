# -*- coding: utf-8 -*-
"""En-tetes de securite poses sur TOUTE reponse du vrai Handler (dashboard/server.py), sans doublon :
nosniff, X-Frame-Options, Referrer-Policy, et HSTS seulement quand l'adresse publique est en https.

    python tests/trust/test_security_headers.py
"""
import http.client
import os
import sys
import threading
import unittest
import importlib

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
os.environ.setdefault("BK_ROOT", REPO)
sys.path.insert(0, os.path.join(REPO, "dashboard"))


def load_server(public_url):
    os.environ["BK_PUBLIC_URL"] = public_url
    sys.modules.pop("server", None)
    return importlib.import_module("server")


class SecurityHeaders(unittest.TestCase):
    def fetch(self, public_url, path):
        server = load_server(public_url)
        httpd = server.ThreadingHTTPServer(("127.0.0.1", 0), server.Handler)
        t = threading.Thread(target=httpd.serve_forever, daemon=True)
        t.start()
        try:
            c = http.client.HTTPConnection("127.0.0.1", httpd.server_address[1], timeout=10)
            c.request("GET", path)
            r = c.getresponse()
            r.read()
            names = [k.lower() for k, _ in r.getheaders()]
            return r.status, {k.lower(): v for k, v in r.getheaders()}, names
        finally:
            httpd.shutdown()
            httpd.server_close()

    def test_https_deployment_sends_all_headers_once(self):
        for path in ("/", "/style.css", "/api/does-not-exist"):
            status, h, names = self.fetch("https://example.test", path)
            self.assertEqual(h.get("x-content-type-options"), "nosniff", path)
            self.assertEqual(h.get("x-frame-options"), "SAMEORIGIN", path)
            self.assertEqual(h.get("referrer-policy"), "strict-origin-when-cross-origin", path)
            self.assertEqual(h.get("strict-transport-security"), "max-age=31536000", path)
            for n in ("x-content-type-options", "x-frame-options", "referrer-policy", "strict-transport-security"):
                self.assertEqual(names.count(n), 1, f"{path}: {n} en double")

    def test_http_deployment_has_no_hsts(self):
        status, h, names = self.fetch("http://127.0.0.1:8787", "/style.css")
        self.assertNotIn("strict-transport-security", h)
        self.assertEqual(h.get("x-content-type-options"), "nosniff")


if __name__ == "__main__":
    unittest.main()
