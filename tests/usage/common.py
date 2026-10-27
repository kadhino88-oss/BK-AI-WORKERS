# -*- coding: utf-8 -*-
"""Outils communs de tests/usage : le VRAI dashboard/usage.py sur une racine jetable, horloge injectee, aucun reseau, aucun modele, aucun secret."""
import datetime
import json
import os
import shutil
import sys
import tempfile

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(REPO, "dashboard"))

import usage  # noqa: E402

T0 = datetime.datetime(2026, 10, 20, 8, 12, 0, tzinfo=datetime.timezone.utc).timestamp()     # date figee : jamais le jour de lancement
CYCLE_START = "2026-10-12T10:11:12Z"
CYCLE_END = "2026-11-12T10:11:12Z"
A, B = "CLI-CUST-AAAAAAAA", "CLI-CUST-BBBBBBBB"

failures = []
passed = [0]


def check(name, cond, detail=""):
    print(("  PASS  " if cond else "  FAIL  ") + name + (f"  [{str(detail)[:300]}]" if detail and not cond else ""))
    if cond:
        passed[0] += 1
    else:
        failures.append(name)


def finish(title):
    print()
    if failures:
        print(f"{title} : {len(failures)} echec(s) :")
        for f in failures:
            print("  - " + f)
        return 1
    print(f"{title} : {passed[0]} verifications OK")
    return 0


class Clock:
    def __init__(self, t=T0):
        self.t = t

    def __call__(self):
        return self.t

    def advance(self, seconds):
        self.t += seconds


def pv_for(plan_id, monthly, cycle_start=CYCLE_START, renews=CYCLE_END, **extra):
    out = {"planId": plan_id, "monthlyCredits": monthly, "cycleStartUtc": cycle_start, "renewsAtUtc": renews, "exempt": False, "override": None}
    out.update(extra)
    return out


PLANS = {"solo": 250, "trio": 500, "equipe": 900, "pro": 1250, "scale": 4000, "enterprise": 10000, "starter": 150, "business": 600}


class Env:
    """Un service d'usage isole : racine jetable, horloge, forfaits par client modifiables, journal capture."""

    def __init__(self, mode="on", plans=None, **kw):
        self.root = tempfile.mkdtemp(prefix="bkusage-")
        kw.setdefault("limits", {"reconcileIntervalSec": 10 ** 7})          # la reconciliation periodique ne s'invite pas dans les tests qui n'en parlent pas
        self.clock = Clock()
        self.plans = dict(plans or {A: pv_for("solo", 250), B: pv_for("equipe", 900)})
        self.events = []
        self.nudges = []
        self.svc = usage.UsageService(self.root, plan_view=lambda c: dict(self.plans[c]) if c in self.plans else None, now=self.clock, mode=mode,
                                      log=lambda kind, **f: self.events.append((kind, f)), nudge=self.nudges.append, **kw)

    def write_task(self, client, credits, epoch, task_id=None, **extra):
        d = os.path.join(self.root, "runtime", "tasks")
        os.makedirs(d, exist_ok=True)
        tid = task_id or "%032X" % (len(os.listdir(d)) + 1)
        rec = {"TaskId": f"TASK-{tid}", "ClientId": client, "Credits": credits, "CreatedAtUtc": usage.iso(epoch) if epoch else None}
        rec.update(extra)
        with open(os.path.join(d, f"TASK-{tid}.json"), "w", encoding="utf-8") as f:
            json.dump(rec, f)

    def close(self):
        shutil.rmtree(self.root, ignore_errors=True)
