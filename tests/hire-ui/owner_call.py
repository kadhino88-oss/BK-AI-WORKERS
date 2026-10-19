# -*- coding: utf-8 -*-
"""Appels de l'API PROPRIETAIRE sur le serveur jetable de tests/hire-ui/dev_server.py (le mot de passe de la porte est lu dans le fichier
de secrets, jamais affiche).

    python tests/hire-ui/owner_call.py --secrets-file F grant CLI-CUST-XXXXXXXX solo alex
    python tests/hire-ui/owner_call.py --secrets-file F grant CLI-CUST-XXXXXXXX trio alex nora sam
    python tests/hire-ui/owner_call.py --secrets-file F get /api/admin/overview
"""
import argparse
import http.cookiejar
import json
import sys
import urllib.error
import urllib.request


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--secrets-file", required=True)
    ap.add_argument("action", choices=["grant", "get"])
    ap.add_argument("args", nargs="+")
    a = ap.parse_args()
    with open(a.secrets_file, encoding="utf-8") as f:
        secrets = json.load(f)
    base = secrets["url"]
    assert base.startswith("http://127.0.0.1:"), "serveur local uniquement"
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPCookieProcessor(jar))

    def call(method, path, body=None):
        req = urllib.request.Request(base + path, data=json.dumps(body).encode() if body is not None else None, method=method,
                                     headers={"Content-Type": "application/json", "X-Forwarded-For": "198.51.100.99"})
        try:
            with opener.open(req, timeout=30) as r:
                return r.status, json.loads(r.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read().decode("utf-8") or "{}")

    st, out = call("POST", "/api/gate/login", {"password": secrets["gatePassword"]})
    assert st == 200, "connexion proprietaire refusee"
    if a.action == "grant":
        client_id, plan, workers = a.args[0], a.args[1], a.args[2:]
        st, out = call("POST", "/api/admin/grant-workers", {"clientId": client_id, "planId": plan, "workers": workers})
    else:
        st, out = call("GET", a.args[0])
    print(st, json.dumps(out, ensure_ascii=False)[:3000])
    return 0 if st == 200 else 1


if __name__ == "__main__":
    sys.exit(main())
