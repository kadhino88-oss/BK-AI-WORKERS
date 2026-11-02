# -*- coding: utf-8 -*-
"""Banc de preuve : démarre le VRAI dashboard/server.py sur une COPIE jetable du dépôt (port libre, BK_PROJECTS=1, BK_USAGE_WINDOWS=1), le faux lanceur « bon modèle »
(tests/proving/proving_runner.py), un faux exécuteur de connecteurs qui NOTE ses appels (aucun réseau), et des comptes de test générés. Aucun modèle, aucun secret, aucun coût.

Utilisé par run_proving.py. Les identifiants de test sont tirés au sort à chaque lancement et ne sont jamais écrits dans un fichier de preuve."""
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(REPO, "tests", "projects"))
import e2e_server as E  # noqa: E402  (client HTTP, comptes, copie du dépôt)

WRAPPER = r'''
import json, os, runpy, sys
ROOT = os.environ["BK_ROOT"]
sys.path.insert(0, os.path.join(ROOT, "dashboard"))
import projects_wiring
_orig = projects_wiring.build
RUNNER = os.environ.get("PROVE_RUNNER") or os.path.join(ROOT, "tests", "proving", "proving_runner.py")
CALLS = os.path.join(ROOT, "_prove", "connector-calls.jsonl")

def fake_connector(conn, op, params, client_id):
    with open(CALLS, "a", encoding="utf-8") as f:
        f.write(json.dumps({"connector": conn, "operation": op, "params": params, "clientId": client_id}, ensure_ascii=False) + "\n")
    return {"Status": "SUCCESS", "Detail": "fake"}

def build(srv, env=None, **ov):
    ov.setdefault("runner_cmd", lambda i, o: [sys.executable, RUNNER, i, o])
    ov.setdefault("run_connector", fake_connector)
    ov.setdefault("tick_sec", 0.3)
    return _orig(srv, env, **ov)

projects_wiring.build = build
runpy.run_path(os.path.join(ROOT, "dashboard", "server.py"), run_name="__main__")
'''


class Lab:
    def __init__(self, extra_env=None):
        self.root = tempfile.mkdtemp(prefix="bkprove-")
        self.app = os.path.join(self.root, "app")
        self.extra_env = dict(extra_env or {})
        self.proc = None
        self.port = None
        self.clients = {}
        self.expected_calls = 0

    # ------------------------------------------------------------------ copie et démarrage
    def prepare(self):
        shutil.copytree(REPO, self.app, ignore=E.ignore)
        for rel in ("tests/projects/fake_runner.py", "tests/proving/common.py", "tests/proving/proving_runner.py", "tests/proving/fl_site.py", "tests/proving/fl_seo.py",
                    "tests/proving/fl_prospects.py", "tests/proving/fl_ads.py", "tests/proving/fl_chloe.py", "tests/proving/ollama_runner.py"):
            dst = os.path.join(self.app, *rel.split("/"))
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(os.path.join(REPO, *rel.split("/")), dst)
        os.makedirs(os.path.join(self.app, "_prove"), exist_ok=True)
        with open(os.path.join(self.app, "_prove", "wrapper.py"), "w", encoding="utf-8") as f:
            f.write(WRAPPER)
        self.set_knobs({})

    def set_knobs(self, knobs):
        with open(os.path.join(self.app, "_prove", "knobs.json"), "w", encoding="utf-8") as f:
            json.dump(knobs, f)

    def start(self):
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1] if self.port is None else self.port
        self.port = port
        env = {k: v for k, v in os.environ.items() if not k.startswith("BK_SECRET") and k not in ("BK_REQUIRE_GATE", "BK_SMTP_HOST", "BK_SECRETS_DIR", "BK_PROJECTS", "BK_PROJECTS_ALLOW", "ANTHROPIC_API_KEY")}
        env.update(BK_ROOT=self.app, BK_PORT=str(port), BK_LISTEN_HOST="127.0.0.1", BK_PUBLIC_URL="http://127.0.0.1:%d" % port, BK_STATUS_DISABLE="1",
                   BK_GATE_HASH=E.gate_hash(E.GATE_PASSWORD), BK_PILOT_NOTIFY_EMAIL="owner@mail-test.example", PYTHONIOENCODING="utf-8", BK_PROJECTS="1", BK_USAGE_WINDOWS="1")
        env.update(self.extra_env)
        log = open(os.path.join(self.app, "_prove", "server.log"), "a", encoding="utf-8", errors="replace")
        self.proc = subprocess.Popen([sys.executable, "-u", os.path.join(self.app, "_prove", "wrapper.py")], cwd=self.app, env=env, stdout=log, stderr=subprocess.STDOUT, text=True,
                                     encoding="utf-8", errors="replace")
        anon = E.Client(port, "198.51.100.90")
        end = time.time() + 90
        while time.time() < end:
            try:
                if anon.call("GET", "/api/health")[0] == 200:
                    return port
            except Exception:  # noqa: BLE001
                pass
            time.sleep(0.5)
        self.proc.kill()
        raise SystemExit("serveur non démarré (voir %s)" % log.name)

    def kill_hard(self):
        """Mort brutale (comme un redémarrage du conteneur) : aucun arrêt propre."""
        if self.proc and self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait(20)

    def stop(self):
        self.kill_hard()

    def cleanup(self):
        self.stop()
        shutil.rmtree(self.root, ignore_errors=True)

    # ------------------------------------------------------------------ comptes
    def owner(self):
        c = E.Client(self.port, "198.51.100.99")
        st, _ = c.post("/api/gate/login", {"password": E.GATE_PASSWORD})
        assert st == 200, "connexion propriétaire"
        return c

    def account(self, key, email, ip, plan="equipe", connectors=(), workers=None):
        c, cid = E.signup(self.port, email, ip)
        o = self.owner()
        if workers:
            st, out = o.post("/api/admin/grant-workers", {"clientId": cid, "planId": plan, "workers": workers})
        else:
            st, out = o.post("/api/admin/set-plan", {"clientId": cid, "planId": plan, "paidMonths": 1})
        assert st == 200, (st, out)
        os.makedirs(os.path.join(self.app, "core", "connectors", "data"), exist_ok=True)
        with open(os.path.join(self.app, "core", "connectors", "data", cid + ".json"), "w", encoding="utf-8") as f:
            json.dump(list(connectors), f)
        self.clients[key] = (c, cid)
        return c, cid

    def connector_calls(self):
        p = os.path.join(self.app, "_prove", "connector-calls.jsonl")
        if not os.path.isfile(p):
            return []
        return [json.loads(x) for x in open(p, encoding="utf-8") if x.strip()]

    def project_dir(self, cid, pid):
        return os.path.join(self.app, "runtime", "projects", cid, pid)


TERMINAL = ("DONE", "FAILED", "CANCELLED", "BUDGET_REACHED")


def progress(c, pid):
    st, out = c.get("/api/projects/%s/progress" % pid)
    return out if st == 200 else {}


def wait(c, pid, until, timeout=240, every=0.7, on_status=None):
    """Interroge /progress jusqu'à until(progress). `on_status(progress)` peut agir (valider un plan, répondre...) et renvoyer True pour continuer l'attente."""
    end = time.time() + timeout
    last = {}
    while time.time() < end:
        last = progress(c, pid)
        if last and until(last):
            return last
        if on_status:
            on_status(last)
        time.sleep(every)
    return dict(last, _timeout=True)
