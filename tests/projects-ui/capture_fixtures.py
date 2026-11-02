# -*- coding: utf-8 -*-
"""Capture des reponses REELLES de l'API des projets (serveur de tests/projects-ui/live_server.py) en fixtures JSON.

    python tests/projects-ui/capture_fixtures.py <live.json>

Ecrit tests/projects-ui/fixtures/real-<etat>-{detail,progress,approvals,messages}.json, list.json, usage.json : l'interface est ensuite testee
contre ce que le moteur envoie VRAIMENT (test_contract.js), pas contre une forme imaginee. Identifiants de compte retires.
"""
import http.cookiejar
import json
import os
import re
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "fixtures")


def scrub(text):
    text = re.sub(r"CLI-[A-Z]+-[0-9A-F]{8}", "CLI-TEST-00000000", text)
    return re.sub(r"[a-z0-9._-]+@mail-test\.example", "client@example.test", text)


def main():
    info = json.load(open(sys.argv[1], encoding="utf-8"))
    base = info["base"]
    jar = http.cookiejar.CookieJar()
    op = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPCookieProcessor(jar))

    def call(path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(base + path, data=data, headers={"Content-Type": "application/json", "X-Forwarded-For": "198.51.100.21"})
        try:
            with op.open(req, timeout=60) as r:
                return json.loads(r.read().decode("utf-8"))
        except Exception as e:  # noqa: BLE001
            return {"_error": str(e)}

    call("/api/account/login", {"email": info["team"]["email"], "password": info["team"]["password"]})
    os.makedirs(OUT, exist_ok=True)

    def save(name, obj):
        with open(os.path.join(OUT, name), "w", encoding="utf-8") as f:
            f.write(scrub(json.dumps(obj, ensure_ascii=False, indent=1)))

    for state, pid in info["team"]["projects"].items():
        if not pid:
            continue
        for kind, path in (("detail", ""), ("progress", "/progress?since=0"), ("approvals", "/approvals?limit=200"), ("messages", "/messages"), ("deliverables", "/deliverables")):
            save(f"real-{state}-{kind}.json", call(f"/api/projects/{pid}{path}"))
    save("list.json", call("/api/projects?limit=50"))
    save("usage.json", call("/api/usage"))
    print("fixtures ecrites dans", OUT)


if __name__ == "__main__":
    main()
