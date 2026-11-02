# -*- coding: utf-8 -*-
"""Scénarios du banc de preuve (appelés par run_proving.py). Chacun reçoit (lab, check) et renvoie un dict de preuves."""
import time

import harness as H
import fl_ads
import fl_chloe
import fl_prospects
import fl_seo
import fl_site

ORIGIN = {}
TERMINAL_OR_WAIT = ("DONE", "FAILED", "CANCELLED", "BUDGET_REACHED", "WAITING_INPUT", "WAITING_QUOTA")


def _create(c, goal, worker, **kw):
    body = {"goal": goal, "workerId": worker, "autoStart": False}
    body.update(kw)
    st, out = c.post("/api/projects", body, headers=ORIGIN)
    assert st == 201, (st, out)
    return out["projectId"]


def _drive(c, pid, until, timeout=300, answer=None):
    asked = set()

    def act(p):
        wf = p.get("waitingFor")
        if wf == "PLAN_VALIDATION":
            c.post("/api/projects/%s/plan/approve" % pid, {}, headers=ORIGIN)
        if answer and p.get("status") == "WAITING_INPUT" and wf == "INPUT":
            st, d = c.get("/api/projects/%s" % pid)
            for q in (d.get("questions") or d.get("openQuestions") or d.get("inputs") or []):
                if q.get("id") and q["id"] not in asked and not q.get("answered"):
                    asked.add(q["id"])
                    c.post("/api/projects/%s/input" % pid, {"questionId": q["id"], "answer": answer}, headers=ORIGIN)
    return H.wait(c, pid, until, timeout=timeout, on_status=act)


def _snap(c, pid):
    out = {}
    for key, path in (("detail", ""), ("approvals", "/approvals"), ("deliverables", "/deliverables"), ("log", "/log"), ("progress", "/progress")):
        st, body = c.get("/api/projects/%s%s" % (pid, path))
        body.pop("_headers", None)
        out[key] = body if st == 200 else {"_status": st}
    return out


def _approvals(snap):
    a = snap["approvals"]
    return a.get("approvals") or a.get("items") or []


def flagship(lab, check, key, mod, worker, connectors, plan="scale", email=None, ip=None, timeout=420):
    c, cid = lab.account(key, email or "%s@mail-test.example" % key, ip or "198.51.100.%d" % (20 + len(lab.clients)), plan=plan, connectors=connectors)
    t0 = time.time()
    pid = _create(c, mod.BRIEF, worker)
    p = H.wait(c, pid, lambda p: p.get("waitingFor") == "PLAN_VALIDATION" or p.get("status") in H.TERMINAL, timeout=120)
    check("%s : le plan est prêt et attend le « go » du client" % key, p.get("waitingFor") == "PLAN_VALIDATION", p)
    st, d0 = c.get("/api/projects/%s" % pid)
    plan_steps = [s for s in (d0.get("plan") or {}).get("steps") or [] if not s.get("system")]
    workers = sorted({s.get("worker") for s in plan_steps})
    check("%s : le plan a %d étapes de travail et %d critères (Workers %s)" % (key, len(plan_steps), len((d0.get("plan") or {}).get("criteria") or []), "/".join(workers)), len(plan_steps) >= 3 and len((d0.get("plan") or {}).get("criteria") or []) >= 5, plan_steps)
    p = _drive(c, pid, lambda p: p.get("status") in H.TERMINAL or (p.get("status") == "WAITING_INPUT" and p.get("waitingFor") == "CRITERIA_FAILED"), timeout=timeout)
    snap = _snap(c, pid)
    return c, cid, pid, snap, t0, p
