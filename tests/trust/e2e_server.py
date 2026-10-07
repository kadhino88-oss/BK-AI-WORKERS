# -*- coding: utf-8 -*-
"""Bout en bout : le VRAI dashboard/server.py est demarre sur une COPIE jetable du depot (dossier temporaire,
port libre choisi par le systeme, jamais un port fixe, jamais les vraies donnees), puis interroge en HTTP :
pages Securite et Statut, /api/health, /api/status, security.txt, sitemap, journal d'incidents du proprietaire,
mesure reelle (echantillons toutes les secondes pour le test), detection d'un fichier d'etat casse, et le script
deploy/healthcheck.sh (avec un faux "ancien conteneur" qui n'a pas /api/health).

Lancer : python tests/trust/e2e_server.py        (Windows ou Linux/WSL ; python 3 uniquement, aucun acces Internet requis)
         python tests/trust/e2e_server.py --long  (attend aussi une minute pleine pour verifier le pourcentage mesure)
"""
import glob
import hashlib
import http.cookiejar
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
LONG = "--long" in sys.argv
failures = []
GATE_PASSWORD = "e2e-gate-" + os.urandom(6).hex()          # mot de passe de test, jetable
SKIP_DIRS_TOP = {".git", ".claude", "_archive", "runtime", "node_modules", "__pycache__"}


def check(name, cond, detail=""):
    print(("  PASS  " if cond else "  FAIL  ") + name + (f"  [{detail}]" if detail and not cond else ""))
    if not cond:
        failures.append(name)


def ignore(directory, names):
    rel = os.path.relpath(directory, REPO).replace("\\", "/")
    skip = {n for n in names if n == "__pycache__" or (rel == "." and n in SKIP_DIRS_TOP)}
    if rel == "memory":
        skip.add("runtime")
    if rel == "core/accounts":
        skip.add("data")
    if rel == "core/connectors":
        skip.add("client-credentials")
    if rel == "dashboard":
        skip.add(".gate")
    return skip


class Client:
    def __init__(self, port):
        self.base = f"http://127.0.0.1:{port}"
        self.jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPCookieProcessor(self.jar))

    def call(self, method, path, body=None, timeout=15):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.base + path, data=data, method=method, headers={"Content-Type": "application/json"})
        try:
            with self.opener.open(req, timeout=timeout) as r:
                return r.status, dict(r.headers), r.read().decode("utf-8")
        except urllib.error.HTTPError as e:
            return e.code, dict(e.headers), e.read().decode("utf-8")

    def json(self, method, path, body=None):
        status, headers, text = self.call(method, path, body)
        try:
            return status, json.loads(text)
        except ValueError:
            return status, {"raw": text[:200]}


def gate_hash(password):
    salt = os.urandom(16)
    h = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, 200000, dklen=32)
    return f"{salt.hex()}:{h.hex()}:200000"


def wait_for(fn, timeout=20, step=0.5):
    end = time.time() + timeout
    while time.time() < end:
        try:
            value = fn()
            if value:
                return value
        except Exception:
            pass
        time.sleep(step)
    return None


def main():
    root = tempfile.mkdtemp(prefix="bktrust-")
    server = None
    try:
        shutil.copytree(REPO, os.path.join(root, "app"), ignore=ignore)
        app = os.path.join(root, "app")
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]
        env = dict(os.environ, BK_ROOT=app, BK_PORT=str(port), BK_LISTEN_HOST="127.0.0.1", BK_GATE_HASH=gate_hash(GATE_PASSWORD),
                   BK_STATUS_INTERVAL_SECONDS="1", BK_PUBLIC_URL=f"http://127.0.0.1:{port}")
        for k in ("BK_REQUIRE_GATE", "BK_STATUS_DIR", "BK_STATUS_DISABLE", "BK_SECRET_ANTHROPIC"):
            env.pop(k, None)
        server = subprocess.Popen([sys.executable, "-u", os.path.join(app, "dashboard", "server.py")], cwd=app, env=env,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace")
        c = Client(port)
        ready = wait_for(lambda: c.call("GET", "/api/health")[0] == 200, timeout=40)
        check("le serveur demarre sur un port libre et /api/health repond 200", bool(ready))
        if not ready:
            raise SystemExit("serveur non demarre")

        print("\n== sondes et pages publiques (sans compte, sans mot de passe) ==")
        status, headers, text = c.call("GET", "/api/health")
        check("/api/health -> {\"ok\": true} sans cache", json.loads(text) == {"ok": True} and headers.get("Cache-Control") == "no-store", text)
        status, headers, text = c.call("GET", "/securite.html")
        check("/securite.html -> 200 HTML", status == 200 and "text/html" in headers.get("Content-Type", ""), status)
        for needle in ("Aucun rapport SOC 2", "Aucune certification ISO/IEC 27001", "Identifié, non commencé", "contact@bk-entreprise.com",
                       "OVHcloud (France)", "AES-256-GCM", 'href="/status.html"', 'id="signaler"'):
            check(f"page Securite contient « {needle} »", needle in text)
        check("page Securite : aucune affirmation de certification positive", not re.search(r"(?i)certifi[ée]+s?\s+(iso|soc)|soc\s*2\s+type\s+(ii|2)\s+(report|rapport)\s+(disponible|available)", text))
        status, _, text = c.call("GET", "/securite")
        check("/securite (sans .html) -> 200", status == 200)
        status, headers, text = c.call("GET", "/status.html")
        check("/status.html -> 200 HTML avec l'etat embarque", status == 200 and 'id="status-data"' in text and 'id="status-root"' in text)
        status, headers, js = c.call("GET", "/i18n-en-trust.js")
        check("/i18n-en-trust.js -> JavaScript", status == 200 and "javascript" in headers.get("Content-Type", "") and "Security and trust" in js, status)
        status, headers, txt = c.call("GET", "/.well-known/security.txt")
        check("/.well-known/security.txt -> text/plain", status == 200 and headers.get("Content-Type", "").startswith("text/plain"), headers.get("Content-Type"))
        check("security.txt : Contact deja publie, Expires, Canonical", "Contact: mailto:contact@bk-entreprise.com" in txt and "Expires: " in txt
              and f"Canonical: http://127.0.0.1:{port}/.well-known/security.txt" in txt, txt)
        status, _, sm = c.call("GET", "/sitemap.xml")
        check("sitemap.xml liste /securite.html et /status.html", "/securite.html</loc>" in sm and "/status.html</loc>" in sm)
        for page in ("/faq.html", "/cgv.html", "/mentions-legales.html"):
            status, _, text = c.call("GET", page)
            check(f"pied de page de {page} lie Securite et Statut", '<a href="/securite.html">' in text and '<a href="/status.html">' in text)
        status, _, home = c.call("GET", "/")
        check("page d'accueil : liens Securite et Statut dans le pied de page", '<a href="/securite.html">' in home and '<a href="/status.html">' in home)
        status, _, text = c.call("GET", "/api/workers")
        check("/api/workers (ancienne sonde) fonctionne toujours", status == 200 and '"workers"' in text)

        print("\n== avant le premier echantillon : jamais d'historique invente ==")
        st, early = c.json("GET", "/api/status")
        check("/api/status : statut inconnu, aucun jour, pas de date de debut",
              st == 200 and early.get("status") == "unknown" and early.get("days") == [] and early.get("measuredSinceUtc") is None
              and early["uptime"]["percent"] is None, early)

        print("\n== mesure reelle (echantillon toutes les secondes pour ce test) ==")
        live = wait_for(lambda: (lambda j: j if j.get("status") == "operational" and j.get("measuredSinceUtc") else None)(c.json("GET", "/api/status")[1]), timeout=30)
        check("apres le premier echantillon : statut 'operational' et date de debut de mesure", bool(live), live)
        if live:
            check("les 3 composants sont 'ok'", {x["id"]: x["state"] for x in live["components"]} == {"app": "ok", "data": "ok", "ai": live["components"][2]["state"]}
                  and live["components"][0]["state"] == "ok" and live["components"][1]["state"] == "ok", live["components"])
            check("avant la fin de la 1re minute : aucun jour affiche (rien d'invente), pourcentage absent", live["days"] == [] and live["uptime"]["percent"] is None, live["days"])
            blob = json.dumps(live)
            check("charge utile publique sans detail interne (chemin, hote, port, fichier)",
                  not any(x in blob for x in (app, "127.0.0.1", "anthropic", "accounts.json", "Traceback", str(port), "memory/runtime", "CLI-")), blob[:300])
        day_files = glob.glob(os.path.join(app, "memory", "runtime", "status", "days", "*.json"))
        check("l'agregat du jour est ecrit dans le dossier de donnees d'execution", len(day_files) == 1 and
              os.path.isfile(os.path.join(app, "memory", "runtime", "status", "meta.json")), day_files)
        if day_files:
            raw = json.load(open(day_files[0], encoding="utf-8"))
            check("agregat quotidien : 1440 minutes, au moins un echantillon", len(raw["minutes"]) == 1440 and raw["samples"] >= 1, raw["samples"])
        status, _, page = c.call("GET", "/status.html")
        data = json.loads(re.search(r'id="status-data">(.*?)</script>', page, re.S).group(1))
        check("/status.html embarque la meme etat mesure", data["status"] == "operational" and data["measuredSinceUtc"] == live["measuredSinceUtc"])

        print("\n== un fichier d'etat du moteur a moitie ecrit (cas du 2026-09-28) ==")
        states = sorted(glob.glob(os.path.join(app, "core", "**", "state", "*.json"), recursive=True))
        victim = states[0]
        original = open(victim, "rb").read()
        with open(victim, "wb") as f:
            f.write(original[: max(2, len(original) // 2)] + b'\n{"x":')
        down = wait_for(lambda: (lambda j: j if j.get("status") == "outage" else None)(c.json("GET", "/api/status")[1]), timeout=25)
        check("fichier d'etat casse -> statut 'outage', composant donnees 'down'", bool(down) and {x["id"]: x["state"] for x in down["components"]}["data"] == "down", down)
        if down:
            check("le message d'erreur et le nom du fichier ne fuient pas", os.path.basename(victim) not in json.dumps(down))
        with open(victim, "wb") as f:
            f.write(original)
        back = wait_for(lambda: (lambda j: j if j.get("status") == "operational" else None)(c.json("GET", "/api/status")[1]), timeout=25)
        check("fichier repare -> retour a 'operational'", bool(back))

        print("\n== journal d'incidents : reserve au proprietaire ==")
        st, body = c.json("POST", "/api/admin/status/incident", {"action": "add", "title": "Test public"})
        check("sans mot de passe : refuse (401)", st == 401, (st, body))
        st, body = c.json("GET", "/api/admin/status/incidents")
        check("lecture du journal brut sans mot de passe : refusee (401)", st == 401, (st, body))
        st, body = c.json("POST", "/api/gate/login", {"password": GATE_PASSWORD})
        check("connexion proprietaire avec le mot de passe de test", st == 200 and body.get("ok"), (st, body))
        st, body = c.json("POST", "/api/admin/status/incident", {"action": "add", "title": "Lenteur sur les missions <b>test</b>", "impact": "minor", "text": "Nous enquêtons."})
        check("proprietaire : ajout d'un incident", st == 200 and body["incident"]["status"] == "investigating", (st, body))
        iid = body["incident"]["id"]
        st, pub = c.json("GET", "/api/status")
        check("l'incident apparait dans la charge utile publique", [i["id"] for i in pub["incidents"]] == [iid] and pub["incidents"][0]["updates"][0]["text"] == "Nous enquêtons.", pub["incidents"])
        st, body = c.json("POST", "/api/admin/status/incident", {"action": "resolve", "id": iid, "text": "Retour à la normale."})
        check("proprietaire : resolution avec mise a jour", st == 200 and body["incident"]["status"] == "resolved" and len(body["incident"]["updates"]) == 2, (st, body))
        status, _, page = c.call("GET", "/status.html")
        check("l'incident est echappe dans la page (aucun HTML injecte)", "<b>test</b>" not in page and "\\u003cb>test" in page)
        inc_file = os.path.join(app, "memory", "runtime", "status", "incidents.json")
        check("le journal est un JSON simple, modifiable a la main", os.path.isfile(inc_file) and json.load(open(inc_file, encoding="utf-8"))["incidents"][0]["id"] == iid)
        st, body = c.json("POST", "/api/admin/status/incident", {"action": "explode"})
        check("action inconnue -> 400", st == 400, (st, body))
        st, body = c.json("POST", "/api/admin/status/incident", {"action": "delete", "id": iid})
        check("suppression", st == 200 and c.json("GET", "/api/status")[1]["incidents"] == [])

        print("\n== deploy/healthcheck.sh : marche avec et sans /api/health ==")
        sh = os.path.join(root, "healthcheck.sh")
        text = open(os.path.join(app, "deploy", "healthcheck.sh"), "rb").read().replace(b"\r\n", b"\n")
        open(sh, "wb").write(text)
        bash = shutil.which("bash")
        if not bash or (os.name == "nt" and "system32" in bash.lower()):
            bash = None
            for cand in (r"C:\Program Files\Git\bin\bash.exe", r"C:\Program Files\Git\usr\bin\bash.exe"):
                if os.path.isfile(cand):
                    bash = cand
        if not bash:
            print("  (bash introuvable : test du script ignore)")
        else:
            def run_hc(extra_env, tag):
                state, log = os.path.join(root, f"fails-{tag}"), os.path.join(root, f"hc-{tag}.log")
                e = dict(os.environ, BK_HEALTH_BASE=f"http://127.0.0.1:{port}", BK_HEALTH_STATE=state, BK_HEALTH_LOG=log,
                         BK_PROJECT_DIR=os.path.join(root, "nowhere"), **extra_env)
                p = subprocess.run([bash, sh.replace("\\", "/") if os.name != "nt" else sh], env=e, capture_output=True, text=True, timeout=60)
                return p.returncode, os.path.exists(state), (open(state).read().strip() if os.path.exists(state) else "")
            rc, has_state, _ = run_hc({}, "nominal")
            check("nominal : /api/health repond -> sain, aucun compteur d'echec", rc == 0 and not has_state)
            rc, has_state, _ = run_hc({"BK_HEALTH_URL": f"http://127.0.0.1:{port}/api/health-absent-comme-un-ancien-conteneur"}, "old")
            check("ancien conteneur (404 sur la sonde legere) : repli sur /api/workers -> toujours sain", rc == 0 and not has_state)
            rc, has_state, n = run_hc({"BK_HEALTH_URL": f"http://127.0.0.1:{port}/nope", "BK_HEALTH_FALLBACK_URL": f"http://127.0.0.1:{port}/nope2"}, "down")
            check("les deux adresses en echec -> 1er echec compte (pas de redemarrage au 1er)", has_state and n == "1", (rc, n))

        if LONG:
            print("\n== pourcentage mesure (attend une minute pleine) ==")
            def pct():
                j = c.json("GET", "/api/status")[1]
                return j if j["uptime"]["percent"] is not None else None
            full = wait_for(pct, timeout=130, step=3)
            check("apres une minute pleine : un pourcentage mesure apparait", bool(full), full)
            if full:
                check("le pourcentage ne couvre que la periode mesuree (quelques minutes, pas 1440)", 1 <= full["uptime"]["measuredMinutes"] < 10, full["uptime"])
                d = full["days"][0]
                check("1 seul jour, marque partiel, avec la minute de panne (fichier casse) comptee indisponible",
                      len(full["days"]) == 1 and d["partial"] and d["unavailableMinutes"] >= 1 and full["uptime"]["percent"] < 100 and d["level"] != "ok", d)
                check("la date de debut de mesure est celle du 1er echantillon", full["measuredSinceUtc"] == live["measuredSinceUtc"])
    finally:
        out = ""
        if server:
            server.terminate()
            try:
                out = server.communicate(timeout=8)[0]
            except subprocess.TimeoutExpired:
                server.kill()
        check("aucune exception dans les journaux du serveur", "Traceback" not in (out or ""), (out or "")[-600:])
        check("aucun mot de passe de test dans les journaux", GATE_PASSWORD not in (out or ""))
        if failures:
            print("---- journal du serveur (fin) ----")
            for line in (out or "").splitlines()[-20:]:
                print(line)
        shutil.rmtree(root, ignore_errors=True)
    print("\nRESULT:", "OK" if not failures else f"{len(failures)} ECHEC(S): {failures}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    main()
