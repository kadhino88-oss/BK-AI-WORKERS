# -*- coding: utf-8 -*-
"""Banc d'essai du MOTEUR de projets (dashboard/projects*.py) avec un faux lanceur (tests/projects/fake_runner.py), une fausse UsageService
(fenetres session / semaine / mois), une portee des Workers modifiable et un faux executeur de connecteurs. Aucun modele, aucun reseau.

Un projet reel est cree sur disque dans un dossier temporaire ; `drive` fait tourner le superviseur a la main (tick) jusqu'a une condition."""
import json
import os
import shutil
import sys
import tempfile
import time
import threading
import types

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(REPO, "dashboard"))
FAKE_RUNNER = os.path.join(HERE, "fake_runner.py")
CLIENT = "CLI-CUST-AAAAAAAA"
CLIENT_B = "CLI-CUST-BBBBBBBB"
WORKERS_17 = ["alex", "amina", "clara", "dario", "emma", "ines", "lea", "lucas", "maya", "noah", "nora", "rayan", "sam", "seoya", "sophie", "thomas", "yanis"]

import projects  # noqa: E402
import projects_store as ps  # noqa: E402


def iso(ts):
    return ps.iso(ts)


class FakeUsage:
    """UsageService simulee (interface 6b.8) : trois fenetres, reservation partielle, blocage avec l'heure de renouvellement."""

    def __init__(self, session=1000, week=1000, month=1000, now=time.time):
        self.now = now
        t = now()
        self.w = {"session": {"limit": session, "used": 0, "reserved": 0, "resetsAtUtc": iso(t + 4 * 3600)},
                  "week": {"limit": week, "used": 0, "reserved": 0, "resetsAtUtc": iso(t + 7 * 86400)},
                  "month": {"limit": month, "used": 0, "reserved": 0, "resetsAtUtc": iso(t + 25 * 86400)}}
        self.exempt = False
        self.rsv = {}
        self.n = 0
        self.lock = threading.Lock()
        self.settled = []
        self.released = []
        self.charged = 0

    def _win(self, name):
        w = self.w[name]
        rem = max(0, w["limit"] - w["used"] - w["reserved"])
        return types.SimpleNamespace(limit=w["limit"], used=w["used"], reserved=w["reserved"], remaining=rem, opened=True, startUtc=None, resetsAtUtc=w["resetsAtUtc"])

    def remaining(self, client_id, now=None):
        with self.lock:
            wins = {n: self._win(n) for n in self.w}
            allowed = min(v.remaining for v in wins.values())
            binding = min(wins, key=lambda n: wins[n].remaining)
        if self.exempt:
            return types.SimpleNamespace(session=None, week=None, month=None, binding=None, allowedNow=10 ** 9, exempt=True)
        return types.SimpleNamespace(session=wins["session"], week=wins["week"], month=wins["month"], binding=binding, allowedNow=allowed, exempt=False)

    def reserve(self, client_id, credits, kind, ref, ttl_s=None, allow_partial=False):
        view = self.remaining(client_id)
        if view.exempt:
            self.n += 1
            return types.SimpleNamespace(id=f"RSV-{self.n}", credits=credits, kind=kind, ref=ref)
        allowed = view.allowedNow
        if credits > allowed:
            if allow_partial and allowed >= 6:
                credits = allowed
            else:
                return types.SimpleNamespace(limit=view.binding, resetsAtUtc=getattr(view, view.binding).resetsAtUtc, remaining=allowed, needed=credits, view=view)
        with self.lock:
            self.n += 1
            rid = f"RSV-{self.n}"
            self.rsv[rid] = credits
            for w in self.w.values():
                w["reserved"] += credits
        return types.SimpleNamespace(id=rid, credits=credits, kind=kind, ref=ref)

    def settle(self, client_id, rsv_id, actual):
        with self.lock:
            credits = self.rsv.pop(rsv_id, None)
            if credits is None:
                return
            self.settled.append((rsv_id, actual))
            for w in self.w.values():
                w["reserved"] -= credits
                w["used"] += int(actual)

    def release(self, client_id, rsv_id):
        with self.lock:
            credits = self.rsv.pop(rsv_id, None)
            if credits is not None:
                self.released.append(rsv_id)
                for w in self.w.values():
                    w["reserved"] -= credits

    def next_renewal(self, client_id):
        return self.w["session"]["resetsAtUtc"]

    def reconcile(self, client_id):
        return {}

    def on_billing_saved(self, client_id):
        pass

    def renew(self, name):
        """Le renouvellement de la fenetre `name` : compteur a zero, prochaine echeance plus loin."""
        with self.lock:
            self.w[name]["used"] = 0
            self.w[name]["resetsAtUtc"] = iso(self.now() + 4 * 3600)


class Scope:
    def __init__(self, allowed=None, chloe=True):
        self.allowed = list(allowed if allowed is not None else WORKERS_17)
        self.chloe = chloe

    def __call__(self, client_id):
        denied = [{"workerId": w, "reason": "hors forfait"} for w in WORKERS_17 if w not in self.allowed]
        return {"chloe": self.chloe, "allowed": list(self.allowed), "denied": denied, "hireOffer": bool(denied)}


class Env:
    """Un moteur complet sur un dossier temporaire."""

    def __init__(self, plan="equipe", usage=None, scope=None, scenario=None, connectors=(), limits=None, paused=None, runner_cmd=None, tick_sec=0.05,
                 client=CLIENT, enabled=True, allowlist=None, chf=None):
        self.root = tempfile.mkdtemp(prefix="bkeng-")
        for rel in ("core/projects/APPROVAL-RISK.json", "core/projects/PROJECT-LIMITS.json", "core/ai/PROJECT-PHASES.json", "core/ai/LEVELS.json",
                    "core/integrations/Connector-Dispatch.ps1", "core/projects/WORKER-CARDS.json"):
            src = os.path.join(REPO, *rel.split("/"))
            if os.path.isfile(src):
                os.makedirs(os.path.dirname(os.path.join(self.root, *rel.split("/"))), exist_ok=True)
                shutil.copy2(src, os.path.join(self.root, *rel.split("/")))
        if limits:
            p = os.path.join(self.root, "core", "projects", "PROJECT-LIMITS.json")
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w", encoding="utf-8") as f:
                json.dump(limits, f)
        self.client = client
        self.plan = {"planId": plan}
        self.usage = usage or FakeUsage()
        self.scope = scope or Scope()
        self.paused = paused if paused is not None else set()
        self.notifications = []
        self.connector_calls = []
        self.connector_result = {"Status": "SUCCESS", "Detail": "ok"}
        self.activate(connectors)
        self.scenario_path = os.path.join(self.root, "scenario.json")
        scenario = dict(scenario or {})
        if chf is not None:
            scenario["_defaults"] = {"chf": chf}                  # cout simule par defaut de chaque etape (0,02 CHF si omis)
        self.set_scenario(scenario)
        os.environ["FAKE_SCENARIO"] = self.scenario_path
        os.environ["BK_ROOT"] = self.root
        # le dernier argument imite la ligne de commande du vrai lanceur : sous Linux, le moteur ne tue un processus orphelin que si /proc/<pid>/cmdline la contient
        self.runner_cmd = runner_cmd or (lambda i, o: [sys.executable, FAKE_RUNNER, i, o, "Project-StepRunner"])
        self.tick_sec = tick_sec
        self.enabled = enabled
        self.allowlist = allowlist
        self.svc = self.new_service()

    def new_service(self):
        return projects.ProjectService(
            self.root, [], resolve_scope=lambda c: self.scope(c), usage=self.usage, notify=lambda c, k, s, h, t: self.notifications.append((c, k, s)) or True,
            run_connector=self._run_connector, plan_view=lambda c: dict(self.plan), enabled=self.enabled, runner_cmd=self.runner_cmd, tick_sec=self.tick_sec,
            installation_paused=lambda c, w: (c, w) in self.paused or ("*", w) in self.paused, mem_available=lambda: 4000, account_email=lambda c: "client@test.example",
            public_url="https://test.example", allowlist=self.allowlist or "", upgrade=lambda c: {"planId": "pro", "planName": "Pro"})

    def _run_connector(self, conn, op, params, client_id):
        self.connector_calls.append((conn, op, dict(params), client_id))
        return dict(self.connector_result)

    def activate(self, connectors):
        p = os.path.join(self.root, "core", "connectors", "data", self.client + ".json")
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8") as f:
            json.dump(list(connectors), f)

    def set_scenario(self, scenario):
        with open(self.scenario_path, "w", encoding="utf-8") as f:
            json.dump(scenario, f)

    # ---- pilotage
    def state(self, pid):
        return self.svc.store.state(pid)

    def drive(self, pid, until, timeout=45, interval=0.05):
        """tick() jusqu'a ce que until(state) soit vrai ; echec avec l'etat si le delai est depasse."""
        end = time.time() + timeout
        st = None
        while time.time() < end:
            self.svc.tick()
            st = self.state(pid)
            if until(st):
                return st
            time.sleep(interval)
        raise AssertionError(f"delai depasse. statut={st['status']} waitingFor={st.get('waitingFor')} reason={st.get('statusReason')} "
                             f"etapes={ {k: (v['status'], v.get('blockedReason'), v.get('error')) for k, v in st['steps'].items()} }")

    def drive_status(self, pid, *statuses, timeout=45):
        return self.drive(pid, lambda s: s["status"] in statuses, timeout)

    def create(self, goal="Creer le site vitrine de mon cabinet", worker="chloe", **kw):
        kw.setdefault("auto_start", True)
        return self.svc.create_project(self.client, goal, worker, **kw)["projectId"]

    def run_to_done(self, pid, timeout=90):
        return self.drive_status(pid, "DONE", "FAILED", "CANCELLED", timeout=timeout)

    def events(self, pid, types=None):
        evs = self.svc.store.read_jsonl(pid, "events.jsonl")
        return [e for e in evs if not types or e["type"] in types]

    def wspath(self, pid, rel):
        return os.path.join(self.svc.store.project_dir(pid), "workspace", *rel.split("/"))

    def close(self):
        try:
            self.svc.stop(kill=True)
        except Exception:  # noqa: BLE001
            pass
        shutil.rmtree(self.root, ignore_errors=True)
