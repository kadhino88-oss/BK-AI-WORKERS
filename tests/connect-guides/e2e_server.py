"""Bout en bout : le VRAI serveur sur une copie jetable, un VRAI compte client jetable, la VRAIE
route de connexion guidee, et de vrais appels vers les fournisseurs avec de FAUX identifiants
(ils doivent etre refuses proprement, et rien ne doit rester enregistre).
Lancer sous Linux / WSL (python3 + pwsh + acces Internet) : python3 tests/connect-guides/e2e_server.py"""
import base64
import http.cookiejar
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
PWSH = os.environ.get("BK_PWSH") or "pwsh"
failures = []


def check(name, cond, detail=""):
    print(("  PASS  " if cond else "  FAIL  ") + name + (f"  [{detail}]" if detail and not cond else ""))
    if not cond:
        failures.append(name)


class Client:
    def __init__(self, port):
        self.base = f"http://127.0.0.1:{port}"
        self.jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar))

    def call(self, method, path, body=None, timeout=90):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.base + path, data=data, method=method,
                                     headers={"Content-Type": "application/json", "Accept": "application/json"})
        t0 = time.time()
        try:
            with self.opener.open(req, timeout=timeout) as r:
                return r.status, json.loads(r.read().decode() or "{}"), time.time() - t0
        except urllib.error.HTTPError as e:
            raw = e.read().decode() or "{}"
            try:
                return e.code, json.loads(raw), time.time() - t0
            except ValueError:
                return e.code, {"raw": raw[:200]}, time.time() - t0


def main():
    root = tempfile.mkdtemp(prefix="bkcg-")
    server = None
    try:
        subprocess.run(["rsync", "-a", "--exclude=/.git", "--exclude=/runtime", "--exclude=/_archive", "--exclude=/memory/runtime",
                        "--exclude=/core/accounts/data", "--exclude=/core/connectors/client-credentials", REPO + "/", root + "/"], check=True)
        env = dict(os.environ, BK_ROOT=root, BK_PWSH=PWSH, BK_LISTEN_HOST="127.0.0.1",
                   BK_SECRET_CRED_ENCRYPTION_KEY=base64.b64encode(os.urandom(32)).decode())
        env.pop("BK_REQUIRE_GATE", None)
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]
        env["BK_PORT"] = str(port)
        server = subprocess.Popen([sys.executable, "-u", "dashboard/server.py"], cwd=root, env=env,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        for _ in range(60):
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{port}/manifest.json", timeout=1)
                break
            except OSError:
                time.sleep(0.5)

        cl = Client(port)
        email, pw = f"e2e-{os.urandom(4).hex()}@example.com", "Test-Passw0rd!" + os.urandom(3).hex()
        st, body, _ = cl.call("POST", "/api/account/signup", {"email": email, "password": pw, "companyName": "E2E Test"})
        check("compte client jetable créé", st == 200, (st, body))

        print("\n== catalogue vu par un client ==")
        st, cat, _ = cl.call("GET", "/api/connectors")
        rows = {c["connectorId"]: c for cs in cat["categories"].values() for c in cs}
        guided = [c for c in rows.values() if c.get("connectGuide")]
        check("24 outils proposent une connexion guidée", len(guided) == 24, len(guided))
        check("Asana : formulaire avec un champ jeton", rows["asana.controlled"]["connectGuide"]["fields"][0]["key"] == "token")
        blob = json.dumps(cat)
        check("aucune logique de test/composition exposée au navigateur", '"compose"' not in blob and '"test"' not in blob and "rawField" not in blob)
        no_way = [k for k, c in rows.items() if c["realIntegration"] and c["clientCanConfigure"] and not c.get("connectGuide") and not c.get("oauthProvider")]
        print("        outils réels sans connexion guidée ni OAuth :", sorted(no_way))

        print("\n== validation ==")
        st, r, _ = cl.call("POST", "/api/connectors/asana/credential", {"fields": {"token": "  "}})
        check("jeton vide refusé avec le nom du champ", st == 400 and r.get("error") == "INVALID_FIELD" and r.get("field") == "token", (st, r))
        for bad in ("localhost", "169.254.169.254", "10.0.0.1", "http://127.0.0.1:8787", "intranet.local"):
            st, r, _ = cl.call("POST", "/api/connectors/woocommerce/credential",
                               {"fields": {"site": bad, "consumer_key": "ck_x", "consumer_secret": "cs_x"}})
            check(f"WooCommerce : adresse interne « {bad} » refusée", st == 400 and r.get("field") == "site", (st, r))
        st, r, _ = cl.call("POST", "/api/connectors/zendesk/credential",
                           {"fields": {"subdomain": "evil.example.com", "email": "a@b.co", "token": "t"}})
        check("Zendesk : domaine étranger refusé", st == 400 and r.get("field") == "subdomain", (st, r))
        st, r, _ = cl.call("POST", "/api/connectors/slack/credential", {"fields": {"webhook": "https://evil.test/x"}})
        check("Slack : webhook hors hooks.slack.com refusé", st == 400 and r.get("field") == "webhook", (st, r))
        st, r, _ = cl.call("POST", "/api/connectors/asana/credential", {"value": "{\"x\":1}"})
        check("collage brut d'un secret toujours réservé au propriétaire", st == 403 and r.get("error") == "MANUAL_KEY_NOT_ALLOWED", (st, r))
        st, r, _ = cl.call("POST", "/api/connectors/salesforce/credential", {"fields": {"token": "x"}})
        check("outil sans guide : refus propre", st == 404 and r.get("error") == "NO_GUIDE", (st, r))

        print("\n== vrais fournisseurs, faux identifiants ==")
        cases = [
            ("asana", {"token": "faux-jeton-e2e-0000"}, ("auth",)),
            ("intercom", {"token": "faux-jeton-e2e-0000"}, ("auth",)),
            ("trello", {"key": "0" * 32, "token": "0" * 64}, ("auth", "permission", "other")),
            ("zendesk", {"subdomain": "bk-e2e-inexistant-" + os.urandom(3).hex(), "email": "a@b.co", "token": "zz"}, ("auth", "notfound")),
        ]
        for prov, fields, kinds in cases:
            st, r, dt = cl.call("POST", f"/api/connectors/{prov}/credential", {"fields": fields})
            ok = st == 200 and r.get("error") == "VERIFY_FAILED" and r.get("kind") in kinds and r.get("removed") is True and r.get("message")
            check(f"{prov} : faux identifiants refusés et effacés ({dt:.1f}s) -> {r.get('kind')}", ok, (st, r))
            st, cat, _ = cl.call("GET", "/api/connectors")
            row = next(c for cs in cat["categories"].values() for c in cs if c["credentialProvider"] == prov)
            check(f"{prov} : rien n'est resté enregistré ni activé", row["configuredByClient"] is False and row["activatedByClient"] is False, row)
            check(f"{prov} : le message ne contient pas le secret", all(v not in (r.get("message") or "") for v in fields.values()))

        print("\n== divers ==")
        st, r, _ = cl.call("POST", "/api/connectors/asana/test", {})
        check("test d'un outil non connecté -> 404", st == 404, (st, r))
        st, r, _ = cl.call("POST", "/api/connectors/salesforce/interest", {})
        check("« Me prévenir » enregistré", st == 200 and r.get("ok") is True, (st, r))
        check("fichier d'intérêt écrit côté serveur", os.path.isfile(os.path.join(root, "core", "connectors", "data", "connector-interest.json")))
        anon = Client(port)
        st, r, _ = anon.call("POST", "/api/connectors/asana/credential", {"fields": {"token": "x"}})
        check("sans compte : connexion refusée", st in (401, 403), (st, r))
        st, r, _ = cl.call("POST", "/api/account/delete", {"password": pw})
        check("compte jetable supprimé", st == 200, (st, r))
    finally:
        if server:
            server.terminate()
            try:
                out = server.communicate(timeout=5)[0]
            except subprocess.TimeoutExpired:
                server.kill()
                out = ""
            leaked = [ln for ln in (out or "").splitlines() if "faux-jeton" in ln]
            check("aucun secret dans les journaux du serveur", not leaked)
            if "Traceback" in (out or ""):
                check("aucune exception dans les journaux", False, (out or "")[-500:])
            if failures:
                print("---- journal du serveur ----")
                for ln in (out or "").splitlines()[-25:]:
                    print(ln)
        shutil.rmtree(root, ignore_errors=True)
    print("\nRESULT:", "OK" if not failures else f"{len(failures)} ECHEC(S): {failures}")
    sys.exit(1 if failures else 0)


main()
