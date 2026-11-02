# -*- coding: utf-8 -*-
"""Bout en bout des PROJETS : le VRAI dashboard/server.py est démarré sur une COPIE jetable du dépôt (port libre, jamais les vraies données) avec
BK_PROJECTS=1, des comptes clients de forfaits différents et le propriétaire (porte). Le lanceur d'étape est le faux lanceur
(tests/projects/fake_runner.py : mêmes outils réels, aucun modèle) et l'exécuteur de connecteurs est un faux qui note ses appels : aucun réseau,
aucun coût, aucun secret.

On vérifie en HTTP : porte du forfait, création, liste, détail, progression (ETag), messages, validation du plan, approbations (une exécution),
pause, reprise, annulation, suppression, téléchargements (en-têtes de sécurité), isolation entre clients (404 partout), limites de débit,
routes du propriétaire, interrupteur général, export et suppression de compte ; puis un second serveur SANS BK_PROJECTS : tout répond 503 et
rien d'existant ne change.

Lancer : python tests/projects/e2e_server.py      (Windows ou Linux/WSL ; python 3)
"""
import hashlib
import http.cookiejar
import io
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
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
SKIP_TOP = {".git", ".claude", ".secrets", "_archive", "runtime", "node_modules", "__pycache__", "tests", "docs"}
PASSWORD = "e2e-" + os.urandom(6).hex()
GATE_PASSWORD = "gate-" + os.urandom(6).hex()
failures = []

WRAPPER = r'''
import json, os, runpy, sys, time
ROOT = os.environ["BK_ROOT"]
sys.path.insert(0, os.path.join(ROOT, "dashboard"))
import projects_wiring
_orig = projects_wiring.build
FAKE = os.path.join(ROOT, "tests", "projects", "fake_runner.py")
CALLS = os.path.join(ROOT, "_e2e", "connector-calls.jsonl")

def fake_connector(conn, op, params, client_id):
    with open(CALLS, "a", encoding="utf-8") as f:
        f.write(json.dumps({"connector": conn, "operation": op, "params": params, "clientId": client_id}) + "\n")
    return {"Status": "SUCCESS", "Detail": "fake"}

def build(srv, env=None, **ov):
    ov.setdefault("runner_cmd", lambda i, o: [sys.executable, FAKE, i, o])
    ov.setdefault("run_connector", fake_connector)
    ov.setdefault("tick_sec", 0.3)
    return _orig(srv, env, **ov)

projects_wiring.build = build
runpy.run_path(os.path.join(ROOT, "dashboard", "server.py"), run_name="__main__")
'''


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


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


class Client:
    def __init__(self, port, ip="198.51.100.1"):
        self.base = f"http://127.0.0.1:{port}"
        self.ip = ip
        self.jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPCookieProcessor(self.jar), NoRedirect())

    def call(self, method, path, body=None, headers=None, raw_body=None):
        """(statut, corps, en-têtes)"""
        data = raw_body if raw_body is not None else (json.dumps(body).encode() if body is not None else None)
        h = {"Content-Type": "application/json", "X-Forwarded-For": self.ip}
        h.update(headers or {})
        req = urllib.request.Request(self.base + path, data=data, method=method, headers=h)
        try:
            with self.opener.open(req, timeout=60) as r:
                return r.status, r.read(), dict(r.headers)
        except urllib.error.HTTPError as e:
            return e.code, e.read(), dict(e.headers)

    def json(self, method, path, body=None, headers=None, raw_body=None):
        st, raw, hd = self.call(method, path, body, headers, raw_body)
        try:
            out = json.loads(raw.decode("utf-8"))
        except ValueError:
            out = {"raw": raw[:200].decode("utf-8", "replace")}
        out["_headers"] = hd if isinstance(out, dict) else None
        return st, out

    def get(self, path, **kw):
        return self.json("GET", path, **kw)

    def post(self, path, body=None, **kw):
        return self.json("POST", path, body if body is not None else {}, **kw)

    def delete(self, path):
        return self.json("DELETE", path)


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


def start_server(app, projects_on):
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    env = {k: v for k, v in os.environ.items() if not k.startswith("BK_SECRET") and k not in ("BK_REQUIRE_GATE", "BK_SMTP_HOST", "BK_SECRETS_DIR", "BK_PROJECTS", "BK_PROJECTS_ALLOW")}
    env.update(BK_ROOT=app, BK_PORT=str(port), BK_LISTEN_HOST="127.0.0.1", BK_PUBLIC_URL=f"http://127.0.0.1:{port}", BK_STATUS_DISABLE="1",
               BK_GATE_HASH=gate_hash(GATE_PASSWORD), BK_PILOT_NOTIFY_EMAIL="owner@mail-test.example",
               FAKE_SCENARIO=os.path.join(app, "_e2e", "scenario.json"), PYTHONIOENCODING="utf-8")
    if projects_on:
        env["BK_PROJECTS"] = "1"
    script = os.path.join(app, "_e2e", "wrapper.py")
    log = open(os.path.join(app, "_e2e", f"server-{'on' if projects_on else 'off'}.log"), "w", encoding="utf-8", errors="replace")
    proc = subprocess.Popen([sys.executable, "-u", script], cwd=app, env=env, stdout=log, stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace")
    proc.log_path = log.name
    anon = Client(port, "198.51.100.90")
    end = time.time() + 90
    while time.time() < end:
        try:
            if anon.call("GET", "/api/health")[0] == 200:
                return proc, port
        except Exception:
            pass
        time.sleep(0.5)
    proc.kill()
    raise SystemExit("serveur non demarre")


def poll(fn, timeout=90, every=0.4):
    end = time.time() + timeout
    last = None
    while time.time() < end:
        last = fn()
        if last:
            return last
        time.sleep(every)
    return None


def put_scenario(app, scenario):
    with open(os.path.join(app, "_e2e", "scenario.json"), "w", encoding="utf-8") as f:
        json.dump(scenario, f)


def main():
    root = tempfile.mkdtemp(prefix="bkproj-e2e-")
    procs = []
    try:
        app = os.path.join(root, "app")
        shutil.copytree(REPO, app, ignore=ignore)
        os.makedirs(os.path.join(app, "tests", "projects"), exist_ok=True)
        shutil.copy2(os.path.join(HERE, "fake_runner.py"), os.path.join(app, "tests", "projects", "fake_runner.py"))
        os.makedirs(os.path.join(app, "_e2e"), exist_ok=True)
        with open(os.path.join(app, "_e2e", "wrapper.py"), "w", encoding="utf-8") as f:
            f.write(WRAPPER)
        put_scenario(app, {})
        sys.path.insert(0, HERE)
        import fake_runner as fr

        proc, port = start_server(app, True)
        procs.append(proc)
        anon = Client(port, "198.51.100.90")
        alice, a_id = signup(port, "alice@mail-test.example", "198.51.100.11")
        bob, b_id = signup(port, "bob@mail-test.example", "198.51.100.12")
        carol, c_id = signup(port, "carol@mail-test.example", "198.51.100.13")
        dana, d_id = signup(port, "dana@mail-test.example", "198.51.100.14")
        erin, e_id = signup(port, "erin@mail-test.example", "198.51.100.15")
        owner = Client(port, "198.51.100.99")
        st, _ = owner.post("/api/gate/login", {"password": GATE_PASSWORD})
        assert st == 200, "connexion proprietaire"
        for cid in (a_id, b_id, e_id):
            st, out = owner.post("/api/admin/set-plan", {"clientId": cid, "planId": "equipe", "paidMonths": 1})
            assert st == 200, (st, out)
        st, out = owner.post("/api/admin/grant-workers", {"clientId": d_id, "planId": "trio", "workers": ["lucas"]})
        assert st == 200, (st, out)
        os.makedirs(os.path.join(app, "core", "connectors", "data"), exist_ok=True)
        with open(os.path.join(app, "core", "connectors", "data", a_id + ".json"), "w", encoding="utf-8") as f:
            json.dump(["slack"], f)
        origin = {"Origin": f"http://127.0.0.1:{port}"}

        def status_of(client, pid):
            st, out = client.get(f"/api/projects/{pid}/progress")
            return out.get("status") if st == 200 else None

        # ------------------------------------------------------------------------------------------ porte, entrées
        print("\n== porte du forfait et validation des entrées ==")
        st, out = anon.get("/api/projects")
        check("sans compte : 401 ACCOUNT_REQUIRED", st == 401 and out.get("error") == "ACCOUNT_REQUIRED", (st, out))
        st, out = anon.post("/api/projects", {"goal": "x"})
        check("sans compte, création : 401", st == 401, (st, out))
        st, out = carol.post("/api/projects", {"goal": "Creer le site de mon cabinet", "workerId": "chloe"})
        check("Essai : 403 PROJECT_NOT_IN_PLAN avec la montée en gamme", st == 403 and out.get("error") == "PROJECT_NOT_IN_PLAN" and out.get("upgrade"), (st, out))
        st, out = dana.post("/api/projects", {"goal": "Creer le site de mon cabinet", "workerId": "emma"})
        check("Trio : un Worker non embauché est refusé (403 WORKER_NOT_INCLUDED)", st == 403 and out.get("error") == "WORKER_NOT_INCLUDED", (st, out))
        for body, code in (({"goal": ""}, "GOAL_REQUIRED"), ({"goal": "   "}, "GOAL_REQUIRED"), ({"goal": "x" * 4001}, "GOAL_TOO_LONG"),
                           ({"goal": "ok ok ok", "level": "turbo"}, "INVALID_INPUT"), ({"goal": "mon mot de passe: hunter2xyzabc"}, "INVALID_INPUT"),
                           ({"goal": "Creer un site", "workerId": "../etc"}, None)):
            st, out = alice.post("/api/projects", body)
            check(f"création invalide {json.dumps(body)[:50]} -> 400", st == 400 and (code is None or out.get("error") == code), (st, out))
        st, out = alice.json("POST", "/api/projects", raw_body=b"{pas du json")
        check("JSON invalide : 400", st == 400, (st, out))
        st, out = alice.post("/api/projects", {"goal": "Creer le site de mon cabinet"}, headers={"Origin": "https://evil.example"})
        check("Origin étranger : 403 BAD_ORIGIN", st == 403 and out.get("error") == "BAD_ORIGIN", (st, out))
        check("rien n'a été créé par ces refus", alice.get("/api/projects")[1].get("projects") == [])

        # ------------------------------------------------------------------------------------------ parcours complet
        print("\n== un projet de bout en bout ==")
        st, out = alice.post("/api/projects", {"goal": "Creer le site vitrine de mon cabinet de physiotherapie a Lausanne", "workerId": "chloe", "autoStart": False}, headers=origin)
        pid = out.get("projectId")
        check("création : 201 avec un identifiant", st == 201 and str(pid).startswith("PRJ-") and len(pid) == 36, (st, out))
        ok = poll(lambda: (alice.get(f"/api/projects/{pid}/progress")[1].get("waitingFor") == "PLAN_VALIDATION"))
        check("le plan est prêt et attend la validation du client", ok)
        st, d = alice.get(f"/api/projects/{pid}")
        steps = (d.get("plan") or {}).get("steps") or []
        own = [x for x in steps if not x.get("system")]
        check("détail : plan de 3 étapes (+ étapes système), critères, budget, capacités", st == 200 and len(own) == 3 and d["plan"]["criteria"] and d.get("budget") and d.get("capabilities"), (st, len(own), list(d)[:15]))
        check("détail : les Workers de l'équipe sont listés (couloirs)", {w["id"] for w in d.get("workers") or []} >= {"lucas", "emma"})
        st, lst = alice.get("/api/projects")
        check("liste : un projet, résumé sans fuite", st == 200 and len(lst["projects"]) == 1 and lst["projects"][0]["projectId"] == pid and "plan" not in lst["projects"][0], (st, lst))
        st, out = alice.post(f"/api/projects/{pid}/messages", {"type": "note", "text": "Utilisez le vouvoiement partout"}, headers=origin)
        check("message : 202", st == 202 and out.get("messageId"), (st, out))
        st, out = alice.json("POST", f"/api/projects/{pid}/messages", raw_body=b'{"type":"note","text":"' + b"x" * 70000 + b'"}', headers=origin)
        check("corps trop gros : 413 TOO_LARGE", st == 413 and out.get("error") == "TOO_LARGE", (st, out))
        st, out = alice.post(f"/api/projects/{pid}/messages", {"type": "teleport", "text": "x"}, headers=origin)
        check("message d'un type inconnu : 400", st == 400, (st, out))
        st, out = alice.post(f"/api/projects/{pid}/messages", {"type": "note", "text": "mon mot de passe: hunter2xyzabc"}, headers=origin)
        check("message contenant un secret : refusé", st == 400, (st, out))
        st, msgs = alice.get(f"/api/projects/{pid}/messages")
        check("messages : la note est listée", st == 200 and any("vouvoiement" in m["text"] for m in msgs["messages"]), (st, msgs))
        st, out = alice.post(f"/api/projects/{pid}/plan/approve", {}, headers=origin)
        check("validation du plan : le projet démarre", st == 200, (st, out))
        done = poll(lambda: status_of(alice, pid) in ("DONE", "FAILED") and status_of(alice, pid), timeout=150)
        check("le projet se termine : DONE (vérifié)", done == "DONE", done)
        st, d = alice.get(f"/api/projects/{pid}")
        verdicts = {c["id"]: c.get("verdict") for c in d["plan"]["criteria"]}
        check("détail final : tous les critères PASS avec preuve", set(verdicts.values()) == {"PASS"}, verdicts)
        st, dl = alice.get(f"/api/projects/{pid}/deliverables")
        paths = [x["path"] for x in dl.get("deliverables", [])]
        check("livrables listés", st == 200 and "site/index.html" in paths and len(paths) >= 3, (st, paths))
        st, raw, hd = alice.call("GET", f"/api/projects/{pid}/files/site/index.html")
        lh = {k.lower(): v for k, v in hd.items()}
        check("fichier : en pièce jointe, nosniff, CSP stricte, pas de cache", st == 200 and "attachment" in lh.get("content-disposition", "") and lh.get("x-content-type-options") == "nosniff"
              and "default-src 'none'" in lh.get("content-security-policy", "") and "no-store" in lh.get("cache-control", ""), (st, lh))
        st, raw, hd = alice.call("GET", f"/api/projects/{pid}/files/site/index.html?inline=1")
        check("fichier en ligne : toujours sous CSP sandbox", st == 200 and "sandbox" in {k.lower(): v for k, v in hd.items()}.get("content-security-policy", ""))
        st, raw, hd = alice.call("GET", f"/api/projects/{pid}/files/final-report.md")
        check("rapport final téléchargeable", st == 200 and b"Rapport final" in raw, (st, raw[:80]))
        for bad in ("../state.json", "..%2fstate.json", "site/%2e%2e/%2e%2e/state.json", "site/index.html%00.png", ".hidden.md", "site/..\\x"):
            st, raw, hd = alice.call("GET", f"/api/projects/{pid}/files/{bad}")
            check(f"chemin piégé refusé : {bad}", st in (400, 404) and b"admin" not in raw and b'"clientId"' not in raw, (st, raw[:80]))
        st, raw, hd = alice.call("GET", f"/api/projects/{pid}/export.zip")
        names = []
        if st == 200:
            names = zipfile.ZipFile(io.BytesIO(raw)).namelist()
        check("export zip des livrables", st == 200 and any(n.endswith("index.html") for n in names), (st, names[:5]))
        st, log = alice.get(f"/api/projects/{pid}/log")
        check("journal du projet", st == 200 and log.get("events"), (st, list(log)))
        st, pr = alice.get(f"/api/projects/{pid}/progress")
        etag = pr["_headers"].get("ETag") or pr["_headers"].get("Etag")
        st304, raw, hd = alice.call("GET", f"/api/projects/{pid}/progress?since={pr['seq']}", headers={"If-None-Match": etag or "x"})
        check("progression : ETag puis 304 quand rien n'a changé", bool(etag) and st304 == 304, (etag, st304))
        st, ev = alice.get(f"/api/projects/{pid}/progress?since=0")
        check("progression : événements en français, sans identifiant du fournisseur d'IA", st == 200 and ev["events"] and "file_" not in json.dumps(ev) and "container" not in json.dumps(ev), (st, ev.get("events", [])[:1]))
        st, out = alice.delete(f"/api/projects/{pid}")
        check("suppression sans confirmation : 409 CONFIRM_REQUIRED", st == 409 and out.get("error") == "CONFIRM_REQUIRED", (st, out))

        # ------------------------------------------------------------------------------------------ isolation
        print("\n== isolation entre clients ==")
        routes = [("GET", ""), ("GET", "/progress"), ("GET", "/messages"), ("GET", "/approvals"), ("GET", "/deliverables"), ("GET", "/files/site/index.html"),
                  ("GET", "/files/final-report.md"), ("GET", "/export.zip"), ("GET", "/log"), ("POST", "/messages"), ("POST", "/plan/approve"), ("POST", "/plan/reject"),
                  ("POST", "/pause"), ("POST", "/resume"), ("POST", "/cancel"), ("POST", "/budget"), ("POST", "/accept-gaps"), ("POST", "/retry-step"), ("POST", "/input"),
                  ("POST", "/approvals/batch"), ("POST", "/approvals/APR-00000000/approve"), ("POST", "/approvals/APR-00000000/reject"), ("DELETE", "?confirm=1")]
        leaks = []
        for method, suffix in routes:
            path = f"/api/projects/{pid}{suffix}"
            body = {"type": "note", "text": "x", "creditsCap": 100, "stepId": "S1", "ids": ["APR-00000000"], "decision": "approve", "questionId": "Q-1", "answer": "x"}
            st, out = bob.json(method, path, body if method == "POST" else None, headers=origin)
            if st != 404:
                leaks.append((method, suffix, st))
        check("un autre client reçoit 404 sur TOUTES les routes du projet", not leaks, leaks)
        check("sa liste est vide", bob.get("/api/projects")[1].get("projects") == [])
        st, out = alice.get(f"/api/projects/{pid}")
        check("le projet d'alice est intact après ces tentatives", st == 200 and out["status"] == "DONE", (st, out.get("status")))
        st, out = alice.get("/api/projects/PRJ-" + "0" * 32)
        check("projet inexistant : 404 identique", st == 404 and out.get("error") == "NOT_FOUND", (st, out))
        st, out = alice.get("/api/projects/../../etc/passwd")
        check("identifiant piégé : jamais traité comme un projet", st in (400, 404), (st, out))
        check("suppression d'alice après confirmation", alice.delete(f"/api/projects/{pid}?confirm=1")[0] == 200)
        check("projet supprimé : 404", alice.get(f"/api/projects/{pid}")[0] == 404)

        # ------------------------------------------------------------------------------------------ pause, reprise, annulation
        print("\n== pause, reprise, annulation ==")
        put_scenario(app, {"S1": {"sleep": 4}})
        st, out = alice.post("/api/projects", {"goal": "Un projet que l'on met en pause puis qu'on annule", "autoStart": True}, headers=origin)
        p2 = out.get("projectId")
        check("création avec démarrage automatique", st == 201, (st, out))
        poll(lambda: status_of(alice, p2) in ("RUNNING",))
        st, out = alice.post(f"/api/projects/{p2}/pause", {}, headers=origin)
        check("pause : 200 PAUSED", st == 200 and out.get("status") == "PAUSED", (st, out))
        st, out = alice.post(f"/api/projects/{p2}/pause", {}, headers=origin)
        check("pause d'un projet déjà en pause : 409 INVALID_STATE", st == 409 and out.get("error") == "INVALID_STATE", (st, out))
        time.sleep(1.5)
        steps_running = [s for s in alice.get(f"/api/projects/{p2}")[1]["plan"]["steps"] if s["status"] == "RUNNING"] if alice.get(f"/api/projects/{p2}")[1].get("plan") else []
        st, out = alice.post(f"/api/projects/{p2}/resume", {}, headers=origin)
        check("reprise : 200", st == 200 and out.get("status") in ("RUNNING", "PLANNING"), (st, out))
        st, out = alice.post(f"/api/projects/{p2}/cancel", {"reason": "test"}, headers=origin)
        check("annulation : 200 CANCELLED", st == 200 and out.get("status") == "CANCELLED", (st, out))
        st, out = alice.post(f"/api/projects/{p2}/cancel", {}, headers=origin)
        check("seconde annulation : 409", st == 409, (st, out))
        st, out = alice.post(f"/api/projects/{p2}/messages", {"type": "note", "text": "encore"}, headers=origin)
        check("message sur un projet annulé : 409 INVALID_STATE", st == 409, (st, out))
        time.sleep(1.0)
        check("l'état reste CANCELLED (aucun lanceur ne repart)", status_of(alice, p2) == "CANCELLED")
        check("suppression d'un projet annulé : 200", alice.delete(f"/api/projects/{p2}?confirm=1")[0] == 200)

        # ------------------------------------------------------------------------------------------ approbations
        print("\n== approbations : une exécution, jamais deux ==")
        plan = fr.default_plan({})
        plan["steps"][2]["requiresApprovalsFrom"] = ["S2"]
        asks = [{"tool": "request_approval", "input": {"connectorId": "slack", "operation": "POST_MESSAGE", "title": f"Message {i}", "what": "Envoie un message",
                                                       "params": {"channel": "#general", "text": f"Bonjour {i}"}}} for i in range(3)]
        asks.append({"tool": "request_approval", "input": {"kind": "manual", "title": "Ajouter le DNS", "details": "Chez votre hébergeur, ajoutez l'enregistrement A"}})
        asks.append({"tool": "request_approval", "input": {"connectorId": "slack", "operation": "POST_MESSAGE", "title": "Envoi à 30 personnes", "what": "Envoie un message",
                                                           "recipients": 30, "params": {"channel": "#vip", "text": "Annonce"}}})
        scenario = {"plan": {"actions": [{"tool": "project_plan", "input": {"action": "set", "plan": plan}}], "complete": {"status": "DONE", "summary": "Plan pret."}},
                    "S2": {"actions": [{"tool": "workspace_write", "input": {"path": "site/about.html", "mode": "overwrite", "content": "<h1>A propos</h1> contenu"}},
                                       {"tool": "deliverable_register", "input": {"path": "site/about.html", "title": "A propos"}}] + asks}}
        put_scenario(app, scenario)
        calls_path = os.path.join(app, "_e2e", "connector-calls.jsonl")
        st, out = alice.post("/api/projects", {"goal": "Un projet avec des actions a faire valider", "autoStart": True}, headers=origin)
        p3 = out.get("projectId")
        ok = poll(lambda: status_of(alice, p3) == "WAITING_APPROVAL", timeout=90)
        check("le projet attend les validations", bool(ok), status_of(alice, p3))
        st, ap = alice.get(f"/api/projects/{p3}/approvals?status=PENDING")
        rows = ap.get("approvals") or []
        check("5 actions en attente, rien n'est parti", st == 200 and len(rows) == 5 and not os.path.exists(calls_path), (st, len(rows)))
        slack = sorted([r for r in rows if r["connectorId"] == "slack" and r["risk"] == "medium"], key=lambda r: r["display"]["title"])
        high = [r for r in rows if r["risk"] == "high"]
        manual = [r for r in rows if r["kind"] == "manual_action"]
        check("classes de risque : 3 moyennes, 1 élevée, 1 manuelle", len(slack) == 3 and len(high) == 1 and len(manual) == 1, [(r["kind"], r["risk"]) for r in rows])
        st, out = alice.post(f"/api/projects/{p3}/approvals/{high[0]['id']}/approve", {}, headers=origin)
        check("risque élevé sans confirmation saisie : 409 CONFIRM_REQUIRED", st == 409 and out.get("error") == "CONFIRM_REQUIRED", (st, out))
        st, out = alice.post(f"/api/projects/{p3}/approvals/batch", {"ids": [high[0]["id"]], "decision": "approve"}, headers=origin)
        check("risque élevé en lot : refusé", st == 200 and out["results"][0].get("error") == "BATCH_NOT_ALLOWED", (st, out))
        st, out = alice.post(f"/api/projects/{p3}/approvals/{slack[0]['id']}/approve", {"params": {"text": "Bonjour corrigé"}}, headers=origin)
        check("approbation avec modification du texte : EXECUTING", st == 200 and out.get("status") == "EXECUTING", (st, out))
        st, out = alice.post(f"/api/projects/{p3}/approvals/{slack[0]['id']}/approve", {}, headers=origin)
        check("seconde approbation de la même action : 409", st == 409 and out.get("error") == "APPROVAL_NOT_PENDING", (st, out))
        st, out = alice.post(f"/api/projects/{p3}/approvals/{slack[1]['id']}/reject", {"reason": "Pas ce ton"}, headers=origin)
        check("rejet : REJECTED", st == 200 and out.get("status") == "REJECTED", (st, out))
        st, out = alice.post(f"/api/projects/{p3}/approvals/{manual[0]['id']}/approve", {}, headers=origin)
        check("action manuelle confirmée : EXECUTED sans appel de connecteur", st == 200 and out.get("status") == "EXECUTED", (st, out))
        st, out = alice.post(f"/api/projects/{p3}/approvals/batch", {"ids": [slack[2]["id"]], "decision": "approve"}, headers=origin)
        check("lot d'une action moyenne : EXECUTING", st == 200 and out["results"][0]["status"] == "EXECUTING", (st, out))
        st, out = alice.post(f"/api/projects/{p3}/approvals/{high[0]['id']}/approve", {"confirm": "J'autorise"}, headers=origin)
        check("risque élevé avec « J'autorise » : EXECUTING", st == 200 and out.get("status") == "EXECUTING", (st, out))
        ok = poll(lambda: os.path.exists(calls_path) and len(open(calls_path, encoding="utf-8").read().splitlines()) >= 3)
        time.sleep(2.5)                                                                      # espacement entre exécutions (1 s) : laisser finir
        calls = [json.loads(x) for x in open(calls_path, encoding="utf-8").read().splitlines()] if os.path.exists(calls_path) else []
        texts = sorted(c["params"]["text"] for c in calls)
        check("exactement 3 appels au connecteur : le texte corrigé, le lot, l'envoi confirmé", texts == ["Annonce", "Bonjour 2", "Bonjour corrigé"], texts)
        check("jamais le message rejeté ni l'action manuelle", all(c["params"].get("text") != "Bonjour 1" for c in calls) and all(c["clientId"] == a_id for c in calls))
        done = poll(lambda: status_of(alice, p3) in ("DONE", "FAILED") and status_of(alice, p3), timeout=150)
        check("une fois les actions décidées, le projet se termine", done == "DONE", done)
        st, ap = alice.get(f"/api/projects/{p3}/approvals")
        check("décomptes d'actions cohérents", ap["counts"].get("EXECUTED") == 4 and ap["counts"].get("REJECTED") == 1, ap.get("counts"))
        st, out = bob.post(f"/api/projects/{p3}/approvals/{slack[0]['id']}/approve", {}, headers=origin)
        check("un autre client ne peut pas décider (404)", st == 404, (st, out))

        # ------------------------------------------------------------------------------------------ limites de débit
        print("\n== limites de débit ==")
        put_scenario(app, {})
        st, out = bob.post("/api/projects", {"goal": "Projet de bob pour les limites de débit", "autoStart": False}, headers=origin)
        bp = out.get("projectId")
        check("projet de bob créé", st == 201, (st, out))
        poll(lambda: bob.get(f"/api/projects/{bp}/progress")[1].get("waitingFor") == "PLAN_VALIDATION")
        sent, last = 0, None
        for i in range(65):
            st, out = bob.post(f"/api/projects/{bp}/messages", {"type": "note", "text": f"precision {i}"}, headers=origin)
            last = (st, out)
            if st == 429:
                break
            sent += 1
        check("messages : 60 par heure (les tentatives sur le projet d'un autre comptent aussi) puis 429 RATE_LIMITED avec Retry-After",
              55 <= sent <= 60 and last[0] == 429 and last[1].get("error") == "RATE_LIMITED" and "Retry-After" in (last[1].get("_headers") or {}), (sent, last[0]))
        n429 = 0
        for i in range(130):
            st, out = bob.get(f"/api/projects/{bp}/progress")
            if st == 429:
                n429 += 1
        check("progression : plus de 120 requêtes par minute -> 429", n429 > 0, n429)
        st, out = alice.get("/api/projects")
        check("les limites de bob ne touchent pas alice", st == 200)

        # ------------------------------------------------------------------------------------------ propriétaire
        print("\n== propriétaire : pause d'un client, arrêt d'un projet, interrupteur général ==")
        st, out = anon.get("/api/admin/projects")
        check("liste d'administration sans porte : 403 GATE_REQUIRED", st == 403 and out.get("error") == "GATE_REQUIRED", (st, out))
        st, out = alice.get("/api/admin/projects")
        check("la session d'un client ne suffit pas", st == 403, (st, out))
        st, out = alice.post("/api/admin/projects/kill-all", {"on": True}, headers=origin)
        check("un client ne peut pas actionner l'interrupteur général", st == 403, (st, out))
        st, out = owner.get("/api/admin/projects")
        check("propriétaire : liste de tous les projets", st == 200 and any(r["clientId"] == b_id for r in out.get("projects", [])), (st, list(out)))
        put_scenario(app, {"execute": {"sleep": 6}})
        st, out = alice.post("/api/projects", {"goal": "Un projet que le proprietaire va mettre en pause", "autoStart": True}, headers=origin)
        bp = out.get("projectId")
        check("alice lance un projet lent", st == 201, (st, out))
        poll(lambda: status_of(alice, bp) in ("RUNNING",))
        st, out = owner.post("/api/admin/projects/pause-client", {"clientId": a_id, "paused": True})
        check("propriétaire : pause du client", st == 200 and a_id in out.get("pausedClients", []), (st, out))
        ok = poll(lambda: status_of(alice, bp) == "PAUSED")
        check("les projets du client passent en pause", bool(ok), status_of(alice, bp))
        st, out = alice.post(f"/api/projects/{bp}/resume", {}, headers=origin)
        check("le client ne peut pas lever la pause du propriétaire (409)", st == 409, (st, out))
        owner.post("/api/admin/projects/pause-client", {"clientId": a_id, "paused": False})
        ok = poll(lambda: status_of(alice, bp) in ("RUNNING", "VERIFYING", "DONE"))
        check("pause levée : le projet reprend tout seul", bool(ok), status_of(alice, bp))
        st, out = owner.post(f"/api/admin/projects/{bp}/kill", {})
        check("propriétaire : arrêt d'un projet", st == 200 and out.get("status") == "CANCELLED", (st, out))
        check("le projet arrêté est CANCELLED côté client", status_of(alice, bp) == "CANCELLED")
        st, out = owner.post("/api/admin/projects/kill-all", {"on": True})
        check("interrupteur général activé", st == 200 and out.get("killAll") is True, (st, out))
        st, out = alice.post("/api/projects", {"goal": "Projet pendant l'arrêt général"}, headers=origin)
        check("création pendant l'arrêt général : 503 PROJECTS_DISABLED", st == 503 and out.get("error") == "PROJECTS_DISABLED", (st, out))
        check("la lecture reste possible pendant l'arrêt général", alice.get("/api/projects")[0] == 200)
        st, out = owner.post("/api/admin/projects/kill-all", {"on": False})
        check("interrupteur général relâché", st == 200 and out.get("killAll") is False, (st, out))
        put_scenario(app, {})
        st, out = alice.post("/api/projects", {"goal": "Projet après l'arrêt général", "autoStart": False}, headers=origin)
        check("création de nouveau possible", st == 201, (st, out))

        # ------------------------------------------------------------------------------------------ plafonds de création
        print("\n== files d'attente et plafonds ==")
        st, out = erin.post("/api/projects", {"goal": "Premier projet d'erin", "autoStart": False}, headers=origin)
        check("erin crée un premier projet", st == 201, (st, out))
        codes = []
        for i in range(8):
            st, out = erin.post("/api/projects", {"goal": f"Projet numero {i} d'erin", "autoStart": False}, headers=origin)
            codes.append((st, out.get("error") or out.get("status")))
        check("au-delà des actifs : mis en file (QUEUED) puis refus propre 429 (jamais d'erreur 500)", any(c[1] == "QUEUED" for c in codes) and all(c[0] in (201, 429) for c in codes)
              and any(c == (429, "PROJECT_LIMIT_REACHED") or c[1] in ("RATE_LIMITED", "PROJECT_LIMIT_REACHED") for c in codes), codes)

        # ------------------------------------------------------------------------------------------ compte : export, suppression
        print("\n== export et suppression de compte ==")
        st, raw, hd = erin.call("POST", "/api/account/export", {}, headers=origin)
        exported = {}
        try:
            exported = json.loads(raw.decode("utf-8"))
        except ValueError:
            pass
        check("export du compte : contient les projets", st == 200 and len(exported.get("projects") or []) >= 1, (st, list(exported)[:12]))
        pdir = os.path.join(app, "runtime", "projects", e_id)
        check("avant suppression : le dossier du client existe", os.path.isdir(pdir))
        st, out = erin.post("/api/account/delete", {"password": PASSWORD}, headers=origin)
        check("suppression du compte : 200", st == 200, (st, out))
        check("après suppression : runtime/projects/<ClientId> a disparu", not os.path.exists(pdir))
        check("les autres clients sont intacts", os.path.isdir(os.path.join(app, "runtime", "projects", a_id)))

        # ------------------------------------------------------------------------------------------ le serveur reste sain
        tail = ""
        try:
            procs[0].terminate()
            procs[0].wait(timeout=15)
            with open(procs[0].log_path, encoding="utf-8", errors="replace") as f:
                tail = f.read()
        except Exception:
            pass
        bad = [l for l in tail.splitlines() if "Traceback" in l or "projects supervisor tick" in l or "[projects-api]" in l]
        check("aucune trace d'erreur interne dans le journal du serveur", not bad, bad[:3])

        # ------------------------------------------------------------------------------------------ BK_PROJECTS=0
        print("\n== second serveur, projets désactivés (défaut) : tout répond 503 et rien d'existant ne change ==")
        shutil.rmtree(os.path.join(app, "runtime", "projects"), ignore_errors=True)
        proc2, port2 = start_server(app, False)
        procs.append(proc2)
        a2, _ = signup(port2, "zoe@mail-test.example", "198.51.100.21")
        for method, path in (("GET", "/api/projects"), ("POST", "/api/projects"), ("GET", "/api/recipes?workerId=lucas"), ("GET", f"/api/projects/{pid}"),
                             ("GET", f"/api/projects/{pid}/progress"), ("DELETE", f"/api/projects/{pid}?confirm=1"), ("POST", f"/api/projects/{pid}/pause")):
            st, out = a2.json(method, path, {"goal": "x"} if method == "POST" else None)
            check(f"BK_PROJECTS=0 : {method} {path[:40]} -> 503 PROJECTS_DISABLED", st == 503 and out.get("error") == "PROJECTS_DISABLED", (st, out))
        st, out = Client(port2).get("/api/admin/projects")
        check("BK_PROJECTS=0 : la route d'administration répond aussi 503", st == 503, (st, out))
        check("BK_PROJECTS=0 : /api/health inchangé", Client(port2).get("/api/health")[0] == 200)
        st, me = a2.get("/api/account/me")
        check("BK_PROJECTS=0 : un compte se connecte et se lit comme avant", st == 200 and me.get("clientId"), (st, me))
        st, raw, hd = a2.call("POST", "/api/account/export", {})
        check("BK_PROJECTS=0 : l'export de compte n'a pas de clé « projects »", st == 200 and "projects" not in json.loads(raw.decode("utf-8")), st)
        check("BK_PROJECTS=0 : aucun dossier runtime/projects créé par ce serveur", not os.path.exists(os.path.join(app, "runtime", "projects")))
        proc2.terminate()
    except BaseException:
        for p in procs:                                  # le journal du serveur aide à comprendre une panne
            try:
                with open(p.log_path, encoding="utf-8", errors="replace") as f:
                    print("---- fin du journal du serveur ----")
                    print("".join(f.readlines()[-40:]))
            except Exception:
                pass
        raise
    finally:
        for p in procs:
            try:
                p.kill()
            except Exception:
                pass
        shutil.rmtree(root, ignore_errors=True)
    print()
    if failures:
        print(f"{len(failures)} verification(s) en echec :")
        for f in failures:
            print("  -", f)
        return 1
    print("OK : toutes les verifications passent.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
