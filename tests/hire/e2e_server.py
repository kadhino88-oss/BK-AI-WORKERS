# -*- coding: utf-8 -*-
"""Bout en bout : le VRAI dashboard/server.py est demarre sur une COPIE jetable du depot (port libre, jamais les vraies donnees), avec
trois comptes clients et le proprietaire (porte). On verifie en HTTP l'offre « Worker a l'unite » :

  - attribution par le proprietaire (/api/admin/grant-workers) : reservee a la porte, validations, forfaits Solo/Trio, credits ;
  - refus d'une mission pour un Worker non embauche sur TOUTES les routes (HTTP 403 WORKER_NOT_INCLUDED, aucune tache creee, aucun credit) ;
  - un forfait classique (essai) n'est jamais restreint ; Chloe est incluse avec Trio seulement ;
  - choix des Workers par le client (/api/workers/hire), echange une fois par 30 jours, demandes d'embauche (/hire-request) ;
  - API d'installation : profil, brouillon, erreurs en francais, secrets refuses, activation seulement si tout est rempli, pause, suppression ;
  - isolation entre clients, identifiants pieges, tailles et frequences limitees ;
  - suppression de compte : l'installation du client disparait ; export du compte ;
  - automatisations : un Worker non embauche ou en pause n'est jamais lance par le cron (moteur PowerShell + quota-check.py).

Aucun modele ni reseau n'est appele : les routes testees refusent AVANT toute mission, ou echouent sur un objectif vide APRES avoir franchi les
controles d'acces (ce qui prouve que le Worker est bien autorise).

Lancer : python tests/hire/e2e_server.py      (Windows ou Linux/WSL ; python 3 ; PowerShell 7 pour la partie automatisations)
"""
import hashlib
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
import urllib.parse
import urllib.request

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SKIP_TOP = {".git", ".claude", ".secrets", "_archive", "runtime", "node_modules", "__pycache__", "tests", "docs"}
PASSWORD = "e2e-" + os.urandom(6).hex()
GATE_PASSWORD = "gate-" + os.urandom(6).hex()
PWSH = os.environ.get("BK_PWSH") or shutil.which("pwsh")
failures = []


def check(name, cond, detail=""):
    print(("  PASS  " if cond else "  FAIL  ") + name + (f"  [{detail}]" if detail and not cond else ""))
    if not cond:
        failures.append(name)


def ignore(directory, names):
    rel = os.path.relpath(directory, REPO).replace("\\", "/")
    skip = {n for n in names if n == "__pycache__" or (rel == "." and n in SKIP_TOP)}
    if rel == "memory":
        skip.add("runtime")
    if rel == "core/accounts":
        skip.add("data")
    if rel in ("core/billing", "core/automation", "core/profile", "core/leads", "core/hire"):
        skip.add("data")
        skip.add("runs")
    if rel == "core/connectors":
        skip.add("client-credentials")
    if rel == "dashboard":
        skip.add(".gate")
    return skip


class Client:
    def __init__(self, port, ip="198.51.100.1"):
        self.base = f"http://127.0.0.1:{port}"
        self.ip = ip
        self.jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPCookieProcessor(self.jar))

    def call(self, method, path, body=None, headers=None, raw_body=None):
        data = raw_body if raw_body is not None else (json.dumps(body).encode() if body is not None else None)
        h = {"Content-Type": "application/json", "X-Forwarded-For": self.ip}
        h.update(headers or {})
        req = urllib.request.Request(self.base + path, data=data, method=method, headers=h)
        try:
            with self.opener.open(req, timeout=60) as r:
                return r.status, r.read()
        except urllib.error.HTTPError as e:
            return e.code, e.read()

    def json(self, method, path, body=None, headers=None, raw_body=None):
        st, raw = self.call(method, path, body, headers, raw_body)
        try:
            return st, json.loads(raw.decode("utf-8"))
        except ValueError:
            return st, {"raw": raw[:200].decode("utf-8", "replace")}

    def get(self, path):
        return self.json("GET", path)

    def post(self, path, body=None):
        return self.json("POST", path, body if body is not None else {})


def signup(port, email, ip):
    c = Client(port, ip)
    st, out = c.post("/api/account/signup", {"email": email, "password": PASSWORD, "companyName": "Test " + email})
    assert st == 200, (st, out)
    st, me = c.get("/api/account/me")
    assert me.get("clientId"), me
    return c, me["clientId"]


def gate_hash(password):
    salt = os.urandom(16)
    return f"{salt.hex()}:{hashlib.pbkdf2_hmac('sha256', password.encode(), salt, 1000, dklen=32).hex()}:1000"


def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8-sig") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def good_alex():
    return {"workerId": "alex", "services": {"prospection-sortante": {
        "enabled": True, "level": "equilibre",
        "knowledge": {"site_web": "https://www.atelier-martin.example", "offre_description": "Maintenance d'ascenseurs pour copropriétés.",
                      "zone_geographique": "Suisse romande"},
        "autonomy": {"lecture-recherche": "auto", "redaction": "auto", "brouillon-email": "draft", "envoi-externe": "off"},
        "channels": ["web", "schedule"]}}, "notes": "Vouvoyer les clients."}


def main():
    root = tempfile.mkdtemp(prefix="bkhire-")
    server = None
    try:
        app = os.path.join(root, "app")
        shutil.copytree(REPO, app, ignore=ignore)
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]
        env = {k: v for k, v in os.environ.items() if not k.startswith("BK_SECRET") and k not in ("BK_REQUIRE_GATE", "BK_SMTP_HOST", "BK_SECRETS_DIR")}
        env.update(BK_ROOT=app, BK_PORT=str(port), BK_LISTEN_HOST="127.0.0.1", BK_PUBLIC_URL=f"http://127.0.0.1:{port}", BK_STATUS_DISABLE="1",
                   BK_GATE_HASH=gate_hash(GATE_PASSWORD),
                   BK_PILOT_NOTIFY_EMAIL="owner@mail-test.example")        # jamais l'adresse reelle du proprietaire ; aucun secret copie, aucun transport : rien ne part
        if PWSH:
            env["BK_PWSH"] = PWSH
        server = subprocess.Popen([sys.executable, "-u", os.path.join(app, "dashboard", "server.py")], cwd=app, env=env,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace")
        anon = Client(port, "198.51.100.90")
        end = time.time() + 60
        while time.time() < end:
            try:
                if anon.call("GET", "/api/health")[0] == 200:
                    break
            except Exception:
                pass
            time.sleep(0.5)
        else:
            raise SystemExit("serveur non demarre")

        alice, a_id = signup(port, "alice@mail-test.example", "198.51.100.11")
        bob, b_id = signup(port, "bob@mail-test.example", "198.51.100.12")
        carol, c_id = signup(port, "carol@mail-test.example", "198.51.100.13")
        owner = Client(port, "198.51.100.99")
        st, _ = owner.post("/api/gate/login", {"password": GATE_PASSWORD})
        assert st == 200, "connexion proprietaire"
        tasks_dir = os.path.join(app, "runtime", "tasks")

        def no_task_created():
            return not os.path.isdir(tasks_dir) or not [f for f in os.listdir(tasks_dir) if f.startswith("TASK-")]

        # ------------------------------------------------------------------------------------------------ attribution par le proprietaire
        print("\n== attribution des Workers par le proprietaire ==")
        grant = {"clientId": a_id, "planId": "solo", "workers": ["alex"]}
        st, out = anon.post("/api/admin/grant-workers", grant)
        check("sans porte : refuse (401 GATE_REQUIRED)", st == 401 and out.get("error") == "GATE_REQUIRED", (st, out))
        st, out = alice.post("/api/admin/grant-workers", dict(grant, clientId=a_id))
        check("un client ne peut pas s'attribuer un forfait (401, la session client ne suffit pas)", st == 401, (st, out))
        st, out = bob.post("/api/admin/grant-workers", dict(grant, clientId=b_id))
        check("un autre client non plus", st == 401, (st, out))
        check("rien n'a ete accorde par ces tentatives", read_json(os.path.join(app, "core", "billing", "data", a_id + ".json"), {}).get("planId") in (None, "essai"))
        for body, code, status in (
                (dict(grant, clientId="CLI-CUST-00000000"), "CLIENT_NOT_FOUND", 404),
                (dict(grant, clientId="../../x"), "CLIENT_NOT_FOUND", 404),
                (dict(grant, clientId="CLI-DASHBOARD"), "CLIENT_NOT_FOUND", 404),
                (dict(grant, planId="starter"), "INVALID_PLAN", 400),
                (dict(grant, planId="enterprise"), "INVALID_PLAN", 400),
                (dict(grant, workers=["alex", "nora"]), "TOO_MANY_WORKERS", 400),
                (dict(grant, workers=[]), "WORKERS_REQUIRED", 400),
                (dict(grant, workers="alex"), "WORKERS_REQUIRED", 400),
                (dict(grant, workers=["hacker"]), "UNKNOWN_WORKER", 404),
                (dict(grant, workers=["../etc/passwd"]), "UNKNOWN_WORKER", 404),
                (dict(grant, workers=["chloe"]), "CHLOE_NOT_HIRABLE", 400)):
            st, out = owner.post("/api/admin/grant-workers", body)
            check(f"attribution invalide {json.dumps(body)[:80]} -> {code}", st == status and out.get("error") == code, (st, out))
        st, out = owner.json("POST", "/api/admin/grant-workers", raw_body=b"x" * 6000)
        check("corps trop gros : 413 TOO_LARGE", st == 413 and out.get("error") == "TOO_LARGE", (st, out))
        st, out = owner.post("/api/admin/grant-workers", grant)
        check("proprietaire : Solo + Alex accordes", st == 200 and out.get("ok") and out["planId"] == "solo" and out["credits"] == 250
              and out["hire"]["hiredWorkers"] == ["alex"] and out["hire"]["slotsLeft"] == 0, (st, out))
        st, out = owner.post("/api/admin/grant-workers", {"clientId": c_id, "planId": "trio", "workers": ["alex"]})
        check("proprietaire : Trio accorde a un autre client avec 1 Worker sur 3", st == 200 and out["credits"] == 500 and out["hire"]["slotsLeft"] == 2, (st, out))

        st, bill = alice.get("/api/billing")
        check("facturation de la cliente Solo : forfait, credits, emplacements, Workers embauches",
              st == 200 and bill["planId"] == "solo" and bill["creditsTotal"] == 250 and bill["workerSlots"] == 1 and bill["hiredWorkers"] == ["alex"]
              and bill["hire"]["restricted"] is True and bill["hire"]["chloeIncluded"] is False, bill)
        # Expectations changed on 2026-10-12 (owner-validated price grid, docs/PRICING.md): availablePlans is now the plan picker of the grid
        # (Solo, Trio, Equipe, Pro, Scale, Enterprise on quote; never the trial; Starter/Business only for a subscriber who is on them), and
        # choosing Solo or Trio is still never free (see the next section). workerPlans is unchanged.
        check("Solo/Trio sont dans le choix de forfait (availablePlans) et detailles dans workerPlans",
              [p["planId"] for p in bill["availablePlans"]] == ["solo", "trio", "equipe", "pro", "scale", "enterprise"]
              and {p["planId"]: (p["credits"], p["workerSlots"]) for p in bill["workerPlans"]} == {"solo": (250, 1), "trio": (500, 3)}, bill["workerPlans"])
        check("les forfaits herites (Starter, Business) ne sont plus proposes dans availablePlans",
              "starter" not in [p["planId"] for p in bill["availablePlans"]] and "business" not in [p["planId"] for p in bill["availablePlans"]], bill["availablePlans"])
        st, bbill = bob.get("/api/billing")
        check("un client en Essai n'est pas restreint (workerSlots null, aucun Worker embauche)",
              bbill["planId"] == "essai" and bbill["workerSlots"] is None and bbill["hiredWorkers"] == [] and bbill["hire"]["restricted"] is False, bbill)

        print("\n== pas de bascule gratuite vers Solo/Trio ==")
        for c, name in ((alice, "alice"), (bob, "bob")):
            for plan in ("solo", "trio"):
                st, out = c.post("/api/billing/plan", {"planId": plan})
                if name == "alice" and plan == "solo":
                    # Expectation changed on 2026-10-12: alice IS on Solo already; asking for the plan she holds does nothing (no new cycle, no
                    # Checkout, so no double subscription) instead of a 403.
                    check("alice : redemander Solo, qu'elle a deja, est sans effet (aucun nouveau cycle)",
                          st == 200 and out.get("planId") == "solo" and out.get("cycleStartUtc") == bill["cycleStartUtc"], (st, out))
                    continue
                check(f"{name} : passer en {plan} en libre-service est refuse (403 PLAN_BY_INVOICE)", st == 403 and out.get("error") == "PLAN_BY_INVOICE", (st, out))
        st, bbill2 = bob.get("/api/billing")
        check("le forfait de bob n'a pas change", bbill2["planId"] == "essai" and bbill2["creditsTotal"] == bbill["creditsTotal"], bbill2["planId"])

        # ------------------------------------------------------------------------------------------------ refus des missions
        print("\n== un Worker non embauche ne demarre jamais (toutes les routes) ==")
        refusals = [
            ("POST", "/api/workers/nora/task", {"objective": "Prepare un tableau de suivi"}),
            ("POST", "/api/workers/nora/task/async", {"objective": "Prepare un tableau de suivi"}),
            ("POST", "/api/workers/maya/task", {"objective": ""}),
            ("POST", "/api/chloe/task", {"objective": "Fais ma prospection et mon marketing"}),
            ("POST", "/api/chloe/task/async", {"objective": "Fais ma prospection"}),
            ("POST", "/api/chloe/plan", {"objective": "Fais ma prospection"}),
        ]
        for method, path, body in refusals:
            st, out = alice.json(method, path, body)
            check(f"Solo/Alex : {path} -> 403 WORKER_NOT_INCLUDED", st == 403 and out.get("error") == "WORKER_NOT_INCLUDED", (st, out))
        st, out = alice.post("/api/workers/nora/task", {"objective": "x"})
        check("le message est en francais, nomme le Worker refuse et le Worker embauche",
              "Nora" in out.get("detail", "") and "Alex" in out.get("detail", "") and "Embauchez" in out.get("detail", ""), out)
        check("la reponse expose l'etat d'embauche pour l'interface", out.get("hire", {}).get("hiredWorkers") == ["alex"] and out.get("workerId") == "nora", out)
        st, out = alice.post("/api/chloe/task", {"objective": "x"})
        check("Chloe n'est pas incluse avec Solo (message Trio)", st == 403 and "Trio" in out.get("detail", ""), out)
        st, out = alice.post("/api/integrations/apikey/generate")
        api_key = out.get("apiKey")
        check("cle API generee pour l'API publique", st == 200 and api_key, (st, out))
        for worker in ("nora", None):
            body = {"request": "Fais un devis"} if worker is None else {"request": "Fais un devis", "worker": worker}
            st, out = alice.json("POST", "/api/public/v1/missions", body, headers={"Authorization": "Bearer " + str(api_key)})
            check(f"API publique (worker={worker or 'chloe par defaut'}) : 403 WORKER_NOT_INCLUDED", st == 403 and out.get("error") == "WORKER_NOT_INCLUDED", (st, out))
        st, out = alice.post("/api/automations", {"workerId": "nora", "objective": "Rapport hebdo", "frequencyMinutes": 60})
        check("creer une automatisation pour un Worker non embauche : 403", st == 403 and out.get("error") == "WORKER_NOT_INCLUDED", (st, out))
        st, out = alice.post("/api/automations", {"workerId": "chloe", "objective": "Rapport hebdo", "frequencyMinutes": 60})
        check("... ou pour Chloe avec Solo : 403", st == 403 and out.get("error") == "WORKER_NOT_INCLUDED", (st, out))
        check("aucune tache n'a ete creee par ces refus", no_task_created())
        st, bill = alice.get("/api/billing")
        check("aucun credit consomme", bill["creditsUsed"] == 0, bill["creditsUsed"])
        st, out = alice.post("/api/workers/ghost/task", {"objective": "x"})
        check("Worker inexistant : toujours 404 UNKNOWN_WORKER", st == 404 and out.get("error") == "UNKNOWN_WORKER", (st, out))

        print("\n== le Worker embauche, l'essai et Chloe-Trio franchissent les controles d'acces ==")
        for method, path in (("POST", "/api/workers/alex/task"), ("POST", "/api/workers/alex/task/async")):
            st, out = alice.json(method, path, {"objective": ""})
            check(f"Solo/Alex : {path} passe les controles puis refuse l'objectif vide (400 OBJECTIVE_REQUIRED)", st == 400 and out.get("error") == "OBJECTIVE_REQUIRED", (st, out))
        for path in ("/api/workers/nora/task", "/api/workers/nora/task/async", "/api/chloe/task", "/api/chloe/task/async"):
            st, out = bob.post(path, {"objective": ""})
            check(f"Essai (classique) : {path} jamais restreint (400 OBJECTIVE_REQUIRED)", st == 400 and out.get("error") == "OBJECTIVE_REQUIRED", (st, out))
        st, out = carol.post("/api/chloe/task", {"objective": ""})
        check("Trio : Chloe incluse (400 OBJECTIVE_REQUIRED, pas 403)", st == 400 and out.get("error") == "OBJECTIVE_REQUIRED", (st, out))
        st, out = carol.post("/api/workers/nora/task", {"objective": "x"})
        check("Trio avec Alex seulement : Nora refusee", st == 403 and out.get("error") == "WORKER_NOT_INCLUDED", (st, out))
        st, out = owner.post("/api/workers/nora/task/async", {"objective": ""})
        check("le proprietaire n'est jamais restreint", st == 400 and out.get("error") == "OBJECTIVE_REQUIRED", (st, out))
        check("toujours aucune tache creee", no_task_created())

        # ------------------------------------------------------------------------------------------------ choix des Workers par le client
        print("\n== le client choisit ses Workers (Trio : 3 emplacements) ==")
        st, out = carol.get("/api/workers/hired")
        check("GET /api/workers/hired : 1 Worker sur 3, 2 emplacements libres, echange possible",
              st == 200 and out["hire"]["hiredWorkers"] == ["alex"] and out["hire"]["slotsLeft"] == 2 and out["hire"]["canSwapNow"] is True and out["planName"] == "Trio", out)
        st, out = anon.get("/api/workers/hired")
        check("sans compte : 401", st == 401, (st, out))
        st, out = carol.post("/api/workers/hire", {"workerId": "nora"})
        check("embaucher Nora : ok", st == 200 and out["ok"] and out["hired"] == "nora" and out["hire"]["slotsLeft"] == 1, (st, out))
        st, out = carol.post("/api/workers/hire", {"workerId": "NORA"})
        check("la meme embauche une deuxieme fois est sans effet (alreadyHired)", st == 200 and out["alreadyHired"] is True and out["hire"]["slotsLeft"] == 1, (st, out))
        st, out = carol.post("/api/workers/hire", {"workerId": "maya"})
        check("embaucher Maya : ok, plus d'emplacement libre", st == 200 and out["hire"]["slotsLeft"] == 0, (st, out))
        st, out = carol.post("/api/workers/nora/task", {"objective": ""})
        check("Nora, desormais embauchee, franchit le controle d'acces", st == 400 and out.get("error") == "OBJECTIVE_REQUIRED", (st, out))
        st, out = carol.post("/api/workers/hire", {"workerId": "dario"})
        check("emplacements pleins : 409 NO_SLOT_LEFT avec la liste actuelle", st == 409 and out.get("error") == "NO_SLOT_LEFT" and out.get("hiredWorkers") == ["alex", "nora", "maya"], (st, out))
        st, out = carol.post("/api/workers/hire", {"workerId": "dario", "replaceWorkerId": "emma"})
        check("remplacer un Worker non embauche : 400 REPLACE_NOT_HIRED", st == 400 and out.get("error") == "REPLACE_NOT_HIRED", (st, out))
        carol_install = dict(good_alex(), workerId="alex")
        st, out = carol.post("/api/installations", carol_install)
        check("Carole installe Alex (brouillon) avant l'echange", st == 200 and out["ok"], (st, out))
        st, out = carol.post("/api/installations/status", {"workerId": "alex", "status": "active"})
        check("... et l'active", st == 200 and out["installation"]["status"] == "active", (st, out))
        st, out = carol.post("/api/workers/hire", {"workerId": "dario", "replaceWorkerId": "alex"})
        check("echange Alex -> Dario : ok (premier echange)", st == 200 and out["replaced"] == "alex" and out["hire"]["hiredWorkers"] == ["dario", "nora", "maya"]
              and out["hire"]["canSwapNow"] is False and out["hire"]["nextSwapAtUtc"], (st, out))
        rec = read_json(os.path.join(app, "runtime", "installations", c_id, "ALEX.json"), {})
        check("l'installation du Worker remplace est mise en pause (interrupteur d'arret)", rec.get("status") == "paused", rec.get("status"))
        st, out = carol.post("/api/workers/hire", {"workerId": "emma", "replaceWorkerId": "nora"})
        check("un second echange le meme mois : 409 SWAP_COOLDOWN + date du prochain echange", st == 409 and out.get("error") == "SWAP_COOLDOWN" and out.get("nextSwapAtUtc"), (st, out))
        st, out = carol.post("/api/workers/alex/task", {"objective": "x"})
        check("Alex, remplace, est refuse", st == 403 and out.get("error") == "WORKER_NOT_INCLUDED", (st, out))
        bpath = os.path.join(app, "core", "billing", "data", c_id + ".json")
        state = read_json(bpath)
        state["lastWorkerSwapAtUtc"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 31 * 86400))
        with open(bpath, "w", encoding="utf-8") as f:
            json.dump(state, f)
        st, out = carol.post("/api/workers/hire", {"workerId": "emma", "replaceWorkerId": "nora"})
        check("31 jours plus tard : l'echange est de nouveau possible", st == 200 and out["hire"]["hiredWorkers"] == ["dario", "emma", "maya"], (st, out))
        for body, code, status in (({"workerId": "chloe"}, "CHLOE_NOT_HIRABLE", 400), ({"workerId": "hacker"}, "UNKNOWN_WORKER", 404),
                                   ({"workerId": "../x"}, "UNKNOWN_WORKER", 404), ({}, "UNKNOWN_WORKER", 404)):
            st, out = carol.post("/api/workers/hire", body)
            check(f"embauche invalide {body} -> {code}", st == status and out.get("error") == code, (st, out))
        st, out = bob.post("/api/workers/hire", {"workerId": "nora"})
        check("forfait classique : rien a embaucher (409 NO_RESTRICTED_PLAN)", st == 409 and out.get("error") == "NO_RESTRICTED_PLAN", (st, out))
        st, out = owner.post("/api/workers/hire", {"workerId": "nora"})
        check("le proprietaire non plus (409)", st == 409, (st, out))
        st, out = carol.json("POST", "/api/workers/hire", raw_body=b"x" * 2500)
        check("corps trop gros : 413", st == 413 and out.get("error") == "TOO_LARGE", (st, out))

        print("\n== demandes d'embauche ==")
        st, out = alice.post("/api/workers/nora/hire-request", {"message": "Je voudrais Nora pour mes relances clients"})
        check("demande d'embauche enregistree, e-mail au proprietaire lance (adresse de test, aucun transport reel)", st == 200 and out["ok"] and out["requestId"].startswith("HRQ-")
              and out["alreadyRequested"] is False and out["notified"] is True, (st, out))
        first_id = out.get("requestId")
        st, out = alice.post("/api/workers/nora/hire-request", {"message": "bis"})
        check("une seule demande ouverte par client et par Worker", st == 200 and out["alreadyRequested"] is True and out["requestId"] == first_id, (st, out))
        st, out = bob.post("/api/workers/nora/hire-request", {"message": "Je voudrais souscrire Nora seule"})
        check("un client en Essai peut demander a souscrire un Worker seul", st == 200 and out["ok"] and out["alreadyRequested"] is False, (st, out))
        frank, f_id = signup(port, "frank@mail-test.example", "198.51.100.15")
        frank.get("/api/billing")                      # cree le fichier de facturation du compte
        fpath = os.path.join(app, "core", "billing", "data", f_id + ".json")
        fstate = read_json(fpath)
        fstate["planId"] = "starter"
        with open(fpath, "w", encoding="utf-8") as f:
            json.dump(fstate, f)
        st, out = frank.post("/api/workers/nora/hire-request", {})
        check("un forfait payant classique donne deja acces a tous les Workers : demande refusee (409)", st == 409 and out.get("error") == "ALREADY_INCLUDED", (st, out))
        st, out = alice.post("/api/workers/alex/hire-request", {})
        check("... ni son propre Worker embauche", st == 409 and out.get("error") == "ALREADY_INCLUDED", (st, out))
        st, out = alice.post("/api/workers/ghost/hire-request", {})
        check("Worker inconnu : 404", st == 404, (st, out))
        st, out = anon.post("/api/workers/nora/hire-request", {})
        check("sans compte : 401", st == 401, (st, out))
        st, out = alice.json("POST", "/api/workers/maya/hire-request", raw_body=b"x" * 3500)
        check("message trop gros : 413", st == 413, (st, out))
        st, ov = owner.get("/api/admin/overview")
        reqs = [r for r in ov.get("hireRequests", []) if r["clientId"] == a_id]
        check("l'apercu proprietaire expose la demande (Worker, client, message)", len(reqs) == 1 and reqs[0]["workerId"] == "nora" and reqs[0]["workerName"] == "Nora"
              and "relances" in reqs[0]["message"], ov.get("hireRequests"))
        rows = {c["clientId"]: c for c in ov["clients"]}
        check("... avec les emplacements et Workers de chaque client", rows[a_id]["hiredWorkers"] == ["alex"] and rows[a_id]["workerSlots"] == 1 and rows[b_id]["workerSlots"] is None, rows[a_id])
        st, out = alice.get("/api/admin/overview")
        check("un client ne voit jamais l'apercu proprietaire (401)", st == 401, (st, out))

        # ------------------------------------------------------------------------------------------------ API d'installation
        print("\n== API d'installation ==")
        for method, path in (("GET", "/api/installations"), ("GET", "/api/workers/alex/install-profile"), ("POST", "/api/installations"),
                             ("POST", "/api/installations/status"), ("POST", "/api/installations/delete")):
            st, out = anon.json(method, path, {} if method == "POST" else None)
            check(f"sans compte : {method} {path} -> 401", st == 401 and out.get("error") == "ACCOUNT_REQUIRED", (st, out))
        st, out = alice.get("/api/workers/alex/install-profile")
        check("profil d'Alex : services, champs, regles, canaux + installation vide + autorise",
              st == 200 and out["workerId"] == "alex" and out["entitled"] is True and out["installation"] is None and out["readiness"] is None
              and len(out["profile"]["services"]) >= 4 and out["profile"]["channelSupport"]["web"] == "available"
              and out["liveChannels"] == ["web", "schedule"] and "hubspot.controlled" in out["connectorStatus"], (st, str(out)[:300]))
        check("l'etat des connecteurs est faux tant que rien n'est connecte", out["connectorStatus"]["hubspot.controlled"] is False, out["connectorStatus"])
        st, out = alice.get("/api/workers/nora/install-profile")
        check("profil d'un Worker non embauche : lisible (pour decider), entitled=false", st == 200 and out["entitled"] is False, (st, str(out)[:200]))
        for bad in ("chloe", "ghost", "atlas", "NORA", "..%2F..%2Fetc%2Fpasswd", "alex%0A"):
            st, out = alice.get(f"/api/workers/{bad}/install-profile")
            check(f"profil d'un identifiant invalide « {bad} » : 404", st == 404, (st, str(out)[:120]))

        st, out = alice.post("/api/installations", good_alex())
        check("enregistrer un brouillon complet : ok, statut draft, rien a completer", st == 200 and out["ok"] and out["installation"]["status"] == "draft"
              and out["installation"]["readiness"] == [] and out["installation"]["entitled"] is True and out["warnings"] == [], (st, str(out)[:300]))
        check("la fiche est stockee pour CE client seulement", os.path.isfile(os.path.join(app, "runtime", "installations", a_id, "ALEX.json"))
              and not os.path.exists(os.path.join(app, "runtime", "installations", b_id)))
        st, out = alice.get("/api/installations")
        check("liste des installations de la cliente avec disponibilite et readiness", st == 200 and [i["workerId"] for i in out["installations"]] == ["alex"]
              and out["installations"][0]["readiness"] == [] and out["installations"][0]["workerName"] == "Alex", (st, str(out)[:200]))
        st, out = carol.get("/api/installations")
        check("isolation : la liste de Carole ne contient pas l'installation d'Alice", st == 200 and all(i["clientId"] == c_id for i in out["installations"]), out)
        st, out = bob.get("/api/installations")
        check("isolation : Bob n'a aucune installation", st == 200 and out["installations"] == [], out)
        st, out = alice.get("/api/workers/alex/install-profile")
        check("le profil renvoie l'installation de la cliente", out["installation"]["notes"] == "Vouvoyer les clients." and out["readiness"] == [], out.get("installation"))
        st, out = bob.get("/api/workers/alex/install-profile")
        check("... mais pas a un autre client", out["installation"] is None, out.get("installation"))

        bad = good_alex()
        bad["services"]["prospection-sortante"]["knowledge"]["offre_description"] = "Mon mot de passe : Tr0ub4dor&3xyz"
        st, out = alice.post("/api/installations", bad)
        check("un mot de passe dans la fiche est refuse, en francais", st == 400 and out["error"] == "INSTALLATION_INVALID"
              and any("ne saisissez jamais" in m for m in out["errors"]), (st, out))
        bad = good_alex()
        bad["services"]["prospection-sortante"]["autonomy"]["envoi-externe"] = "auto"
        st, out = alice.post("/api/installations", bad)
        check("'auto' sur envoyer / publier / payer / appeler est refuse (validation du client obligatoire)", st == 400
              and any("validation du client obligatoire" in m for m in out["errors"]), (st, out))
        bad = good_alex()
        bad["services"]["service-inconnu"] = {"enabled": True}
        st, out = alice.post("/api/installations", bad)
        check("service inconnu : erreur en francais", st == 400 and any("service inconnu" in m for m in out["errors"]), (st, out))
        st, out = alice.post("/api/installations", {"workerId": "ghost", "services": {}})
        check("Worker inconnu : 404", st == 404 and out["error"] == "UNKNOWN_WORKER", (st, out))
        st, out = alice.post("/api/installations", {"workerId": "chloe", "services": {}})
        check("Chloe n'a pas d'installation : 404", st == 404, (st, out))
        st, out = alice.post("/api/installations", dict(good_alex(), workerId="nora"))
        check("installer un Worker non embauche : 403 WORKER_NOT_INCLUDED", st == 403 and out["error"] == "WORKER_NOT_INCLUDED", (st, out))
        check("... et rien n'est ecrit", not os.path.exists(os.path.join(app, "runtime", "installations", a_id, "NORA.json")))
        for evil in ("../alex", "alex/..", "..", "%2e%2e", "al ex", "alex;rm", "a" * 200):
            st, out = alice.post("/api/installations", dict(good_alex(), workerId=evil))
            check(f"identifiant piege « {evil!r} » : refuse sans rien ecrire", st in (400, 404) and out.get("error") in ("UNKNOWN_WORKER", "INSTALLATION_INVALID", "NO_INSTALL_PROFILE"), (st, out))
        written = sorted(os.listdir(os.path.join(app, "runtime", "installations", a_id)))
        check("seule la fiche legitime existe dans le dossier de la cliente", written == ["ALEX.json"], written)
        lead = {"workerId": "alex", "services": {"qualification-lead-entrant": {"enabled": True, "channels": ["web", "phone", "whatsapp"],
                                                                                "knowledge": {"offre_description": "o", "criteres_client_ideal": "c"}}}}
        st, out = alice.post("/api/installations", lead)
        check("canaux telephone / WhatsApp : non enregistres, avertissement clair (pas annonces comme disponibles)",
              st == 200 and out["installation"]["services"]["qualification-lead-entrant"]["channels"] == ["web"]
              and any("pas encore disponible" in w for w in out["warnings"]), (st, out))
        st, out = alice.json("POST", "/api/installations", raw_body=b'{"workerId":"alex","notes":"' + b"x" * 250000 + b'"}')
        check("corps de plus de 200 Ko : 413", st == 413 and out["error"] == "TOO_LARGE", (st, str(out)[:100]))

        print("\n== activation, pause, suppression ==")
        incomplete = good_alex()
        incomplete["services"]["prospection-sortante"]["knowledge"].pop("zone_geographique")
        st, out = alice.post("/api/installations", incomplete)
        check("une fiche incomplete s'enregistre en brouillon avec ce qu'il manque", st == 200 and out["installation"]["status"] == "draft"
              and len(out["installation"]["readiness"]) == 1 and "obligatoire" in out["installation"]["readiness"][0], (st, out))
        st, out = alice.post("/api/installations/status", {"workerId": "alex", "status": "active"})
        check("activation refusee tant qu'il manque quelque chose : 409 NOT_READY + liste", st == 409 and out["error"] == "NOT_READY"
              and len(out["errors"]) == 1 and "Zone géographique" in out["errors"][0], (st, out))
        st, out = alice.post("/api/installations", good_alex())
        st, out = alice.post("/api/installations/status", {"workerId": "alex", "status": "active"})
        check("activation une fois tout rempli", st == 200 and out["installation"]["status"] == "active" and out["installation"]["installedAtUtc"], (st, str(out)[:200]))
        st, out = alice.post("/api/installations/status", {"workerId": "alex", "status": "paused"})
        check("pause (interrupteur d'arret)", st == 200 and out["installation"]["status"] == "paused", (st, out))
        st, out = alice.post("/api/installations/status", {"workerId": "alex", "status": "n-importe-quoi"})
        check("statut invalide : 400", st == 400 and out["error"] == "INVALID_STATUS", (st, out))
        st, out = alice.post("/api/installations/status", {"workerId": "alex", "status": "ACTIVE"})
        check("statut en majuscules : refuse (400)", st == 400, (st, out))
        st, out = alice.post("/api/installations/status", {"workerId": "nora", "status": "paused"})
        check("statut d'une installation inexistante : 404 NO_INSTALLATION", st == 404 and out["error"] == "NO_INSTALLATION", (st, out))
        st, out = bob.post("/api/installations/status", {"workerId": "alex", "status": "active"})
        check("Bob ne peut pas toucher l'installation d'Alice (404, scope = son propre compte)", st == 404 and out["error"] == "NO_INSTALLATION", (st, out))
        check("... et celle d'Alice est inchangee", read_json(os.path.join(app, "runtime", "installations", a_id, "ALEX.json"))["status"] == "paused")
        st, out = alice.post("/api/installations/status", {"workerId": "alex", "status": "active"})
        check("reprise de l'installation", st == 200 and out["installation"]["status"] == "active", (st, out))

        print("\n== le proprietaire utilise l'API pour lui-meme ==")
        st, out = owner.post("/api/installations", good_alex())
        check("proprietaire : brouillon enregistre sous CLI-DASHBOARD", st == 200 and out["installation"]["clientId"] == "CLI-DASHBOARD"
              and os.path.isfile(os.path.join(app, "runtime", "installations", "CLI-DASHBOARD", "ALEX.json")), (st, str(out)[:200]))
        st, out = owner.get("/api/installations")
        check("proprietaire : sa liste ne contient que ses installations", st == 200 and all(i["clientId"] == "CLI-DASHBOARD" for i in out["installations"]), out)

        print("\n== export du compte ==")
        st, raw = alice.call("POST", "/api/account/export", {})
        exported = json.loads(raw.decode("utf-8")) if st == 200 else {}
        check("l'export de compte contient les installations et les demandes d'embauche de la cliente",
              st == 200 and [i["workerId"] for i in exported.get("installations", [])] == ["alex"]
              and [r["workerId"] for r in exported.get("hireRequests", [])] == ["nora"], (st, list(exported)))

        # ------------------------------------------------------------------------------------------------ attribution : changement de Worker par le proprietaire
        print("\n== le proprietaire change le Worker d'une cliente ==")
        st, out = owner.post("/api/admin/grant-workers", {"clientId": a_id, "planId": "solo", "workers": ["nora"], "newCycle": False})
        check("attribution Solo / Nora (sans nouveau cycle)", st == 200 and out["newCycle"] is False and out["hire"]["hiredWorkers"] == ["nora"], (st, out))
        rec = read_json(os.path.join(app, "runtime", "installations", a_id, "ALEX.json"), {})
        check("l'installation du Worker retire est mise en pause", rec.get("status") == "paused", rec.get("status"))
        st, ov = owner.get("/api/admin/overview")
        check("la demande d'embauche satisfaite disparait de la liste", not [r for r in ov["hireRequests"] if r["clientId"] == a_id], ov["hireRequests"])
        st, out = alice.post("/api/workers/nora/task", {"objective": ""})
        check("Nora est maintenant autorisee pour Alice", st == 400 and out.get("error") == "OBJECTIVE_REQUIRED", (st, out))
        st, out = alice.post("/api/workers/alex/task", {"objective": ""})
        check("Alex ne l'est plus", st == 403, (st, out))

        # ------------------------------------------------------------------------------------------------ limites de frequence
        print("\n== limites de frequence ==")
        dave, d_id = signup(port, "dave@mail-test.example", "198.51.100.14")
        st, out = owner.post("/api/admin/grant-workers", {"clientId": d_id, "planId": "trio", "workers": ["lea"]})
        assert st == 200, out
        statuses = [dave.post("/api/workers/hire", {"workerId": "ghost"})[0] for _ in range(21)]
        check("embaucher : 20 essais par heure, le 21e est refuse (429)", statuses[:20] == [404] * 20 and statuses[20] == 429, statuses[-3:])
        statuses = [dave.post("/api/installations/status", {"workerId": "alex", "status": "paused"})[0] for _ in range(61)]
        check("statut d'installation : 60 par heure, le 61e est refuse (429)", statuses[:60] == [404] * 60 and statuses[60] == 429, statuses[-3:])
        statuses = [dave.post(f"/api/workers/{w}/hire-request", {})[0] for w in ("nora", "maya", "emma", "sam", "dario", "yanis")]
        check("demandes d'embauche : 5 par jour, la 6e est refusee (429)", statuses == [200] * 5 + [429], statuses)

        # ------------------------------------------------------------------------------------------------ automatisations
        print("\n== automatisations : Worker non embauche ou en pause ==")
        auto_path = os.path.join(app, "core", "automation", "data", "automations.json")
        os.makedirs(os.path.dirname(auto_path), exist_ok=True)
        past = "2026-01-01T00:00:00.0000000Z"

        def auto(aid, client, worker):
            return {"id": aid, "clientId": client, "workerId": worker, "objective": "Rapport hebdomadaire", "frequencyMinutes": 60, "enabled": True,
                    "notifySlack": False, "createdAtUtc": past, "lastRunAtUtc": None, "lastRunStatus": None, "nextRunAtUtc": past, "runCount": 0}

        with open(auto_path, "w", encoding="utf-8") as f:
            json.dump([auto("AUTO-NOTHIRED", a_id, "alex"), auto("AUTO-PAUSED", a_id, "nora"), auto("AUTO-CHLOE", a_id, "chloe")], f)
        # Alice est Solo / Nora : AUTO-NOTHIRED (worker alex) n'est plus embauche ; AUTO-PAUSED (worker nora) l'est ; Chloe n'est pas incluse
        st, out = alice.post("/api/automations/AUTO-NOTHIRED/toggle", {"enabled": True})
        check("activer une automatisation d'un Worker non embauche : 403", st == 403 and out.get("error") == "WORKER_NOT_INCLUDED", (st, out))
        st, out = alice.post("/api/automations/AUTO-NOTHIRED/run", {})
        check("\"Executer maintenant\" pour un Worker non embauche : 403", st == 403 and out.get("error") == "WORKER_NOT_INCLUDED", (st, out))
        st, out = alice.post("/api/automations/AUTO-CHLOE/run", {})
        check("... et pour Chloe avec Solo : 403", st == 403, (st, out))
        st, out = alice.post("/api/automations/AUTO-INCONNU/run", {})
        check("automatisation inconnue ou d'un autre client : jamais lancee (403 pour un forfait restreint)", st in (403, 404), (st, out))
        profile_nora = read_json(os.path.join(app, "workers", "nora", "install-profile.json"))
        nora_service = profile_nora["services"][0]
        nora_cfg = {"workerId": "nora", "services": {nora_service["id"]: {"enabled": True, "knowledge": {
            k["key"]: "valeur" for k in nora_service["knowledgeFields"] if k.get("required")}}}}
        st, out = alice.post("/api/installations", nora_cfg)
        check("Alice (Nora embauchee) installe Nora", st == 200 and out["ok"], (st, str(out)[:200]))
        st, out = alice.post("/api/installations/status", {"workerId": "nora", "status": "paused"})
        check("... puis la met en pause", st == 200 and out["installation"]["status"] == "paused", (st, str(out)[:200]))

        py = sys.executable
        quota = os.path.join(app, "dashboard", "quota-check.py")

        def verdict(*args):
            p = subprocess.run([py, quota, *args], capture_output=True, text=True, encoding="utf-8", errors="replace", env=dict(env), timeout=120, cwd=app)
            lines = [l for l in p.stdout.splitlines() if l.strip().startswith("{")]
            return json.loads(lines[-1]) if lines else {"raw": p.stdout + p.stderr}

        v = verdict(a_id, "alex", "scheduled")
        check("quota-check : Alex n'est plus embauche -> WORKER_NOT_INCLUDED", v.get("blocked") is True and v.get("code") == "WORKER_NOT_INCLUDED", v)
        v = verdict(a_id, "nora", "scheduled")
        check("quota-check : Nora en pause + passage automatique -> INSTALLATION_PAUSED", v.get("blocked") is True and v.get("code") == "INSTALLATION_PAUSED", v)
        v = verdict(a_id, "nora", "manual")
        check("quota-check : Nora en pause + lancement a la main -> autorise (les missions manuelles restent possibles)", v.get("blocked") is False and v.get("allowedWorkers") == "nora", v)
        v = verdict(b_id, "nora", "scheduled")
        check("quota-check : forfait classique -> autorise, pas de liste de Workers", v.get("blocked") is False and v.get("allowedWorkers") is None, v)
        v = verdict("CLI-DASHBOARD", "nora", "scheduled")
        check("quota-check : proprietaire -> autorise", v.get("blocked") is False, v)
        v = verdict(a_id, "chloe", "scheduled")
        check("quota-check : Chloe avec Solo -> WORKER_NOT_INCLUDED", v.get("blocked") is True and v.get("code") == "WORKER_NOT_INCLUDED", v)
        v = verdict(a_id)
        check("quota-check sans Worker : ancien comportement (quota seulement)", v.get("blocked") is False, v)

        if PWSH:
            bridge = os.path.join(app, "dashboard", "Automation-Bridge.ps1")
            out_file = os.path.join(root, "tick.json")
            tick_env = dict(env, BK_PYTHON=py)
            p = subprocess.run([PWSH, "-NoProfile", "-NonInteractive", "-File", bridge, "-Action", "tick", "-ClientId", a_id, "-OutFile", out_file],
                               capture_output=True, text=True, encoding="utf-8", errors="replace", env=tick_env, timeout=300, cwd=app)
            ran = read_json(out_file, [])
            ran = ran if isinstance(ran, list) else [ran]
            status_by_id = {r["AutomationId"]: r["Status"] for r in ran}
            check("moteur : le passage automatique saute le Worker non embauche, le Worker en pause et Chloe-Solo (aucune mission lancee)",
                  status_by_id == {"AUTO-NOTHIRED": "worker_not_included", "AUTO-PAUSED": "installation_paused", "AUTO-CHLOE": "worker_not_included"},
                  (status_by_id, p.stdout[-300:], p.stderr[-300:]))
            check("... et ne cree aucune tache", no_task_created())
            autos = {a["id"]: a for a in read_json(auto_path, [])}
            check("... en le notant dans l'automatisation (dernier statut)", autos["AUTO-PAUSED"]["lastRunStatus"] == "installation_paused", autos["AUTO-PAUSED"])
        else:
            print("  SKIP  moteur d'automatisation : pwsh absent")

        # ------------------------------------------------------------------------------------------------ suppression de compte
        print("\n== suppression de compte ==")
        st, out = carol.post("/api/installations", dict(good_alex(), workerId="dario", services={}))
        carol_dir = os.path.join(app, "runtime", "installations", c_id)
        check("avant suppression : la cliente a des installations et une demande", os.path.isdir(carol_dir) and os.listdir(carol_dir), os.path.isdir(carol_dir))
        st, out = carol.post("/api/workers/lea/hire-request", {"message": "avant suppression"})
        hr_before = [r for r in read_json(os.path.join(app, "core", "hire", "data", "hire-requests.json"), []) if r["clientId"] == c_id]
        check("(Carole a une demande d'embauche ouverte)", len(hr_before) == 1, (st, out, hr_before))
        st, out = carol.post("/api/account/delete", {"password": PASSWORD})
        check("suppression du compte de Carole : ok", st == 200 and out.get("ok"), (st, out))
        check("le dossier runtime/installations/<ClientId> est purge", not os.path.exists(carol_dir), os.listdir(os.path.join(app, "runtime", "installations")))
        hr_after = [r for r in read_json(os.path.join(app, "core", "hire", "data", "hire-requests.json"), []) if r["clientId"] == c_id]
        check("ses demandes d'embauche sont purgees", hr_after == [], hr_after)
        check("les installations des autres clients sont intactes", os.path.isfile(os.path.join(app, "runtime", "installations", a_id, "ALEX.json"))
              and os.path.isfile(os.path.join(app, "runtime", "installations", "CLI-DASHBOARD", "ALEX.json")))
        check("... ainsi que les demandes des autres", [r for r in read_json(os.path.join(app, "core", "hire", "data", "hire-requests.json"), []) if r["clientId"] == d_id])
        st, out = carol.get("/api/installations")
        check("la session de Carole n'ouvre plus rien (401)", st == 401, (st, out))

        # ------------------------------------------------------------------------------------------------ limite du proprietaire (en dernier : bloque l'heure)
        print("\n== limite de frequence de l'attribution ==")
        statuses = [owner.post("/api/admin/grant-workers", {})[0] for _ in range(60)]
        check("attribution : 60 appels par heure au total, ensuite 429", 429 in statuses and statuses[-1] == 429, statuses[-3:])
    finally:
        if server is not None:
            server.terminate()
            try:
                server.wait(timeout=10)
            except Exception:
                server.kill()
        shutil.rmtree(root, ignore_errors=True)

    print()
    if failures:
        print(f"{len(failures)} echec(s) :")
        for f in failures:
            print("  - " + f)
        sys.exit(1)
    print("Tout est vert.")


if __name__ == "__main__":
    main()
