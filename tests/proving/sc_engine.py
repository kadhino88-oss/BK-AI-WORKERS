# -*- coding: utf-8 -*-
"""Scénarios du moteur lui-même : Chloé sur trois Workers (Équipe/Scale puis Trio), question bloquante (WAITING_INPUT), fenêtre de session atteinte (WAITING_QUOTA, reprise
automatique puis reprise immédiate à la montée en gamme), redémarrage brutal du serveur en plein travail."""
import json
import os
import time

import harness as H
import scenarios as SC
import sc_flagships as F
import fl_chloe
import fl_seo


def sc_chloe(lab, check):
    c, cid, pid, snap, t0, p = SC.flagship(lab, check, "chloe", fl_chloe, "chloe", [])
    out = F.summary_of(lab, snap, t0, pid)
    d = snap["detail"]
    own = [s for s in out["steps"] if not str(s["id"]).startswith(("PLAN", "VER", "CONS", "REPLAN", "FIX"))]
    workers = [s["worker"] for s in own]
    check("chloe : DONE, tous critères PASS", d.get("status") == "DONE" and set(out["criteria"].values()) == {"PASS"}, (d.get("status"), out["criteria"]))
    check("chloe : la demande est répartie sur 3 Workers différents (%s)" % "/".join(workers), len(set(workers)) == 3, workers)
    plan_steps = (d.get("plan") or {}).get("steps") or []
    deps = {s["id"]: s.get("dependsOn") for s in plan_steps if s["id"] in ("S1", "S2", "S3")}
    check("chloe : les étapes sont enchaînées avec relais (S2 dépend de S1, S3 de S1 et S2)", deps.get("S2") == ["S1"] and set(deps.get("S3") or []) == {"S1", "S2"}, deps)
    t3 = F.ws_read(lab, cid, pid, "deliverables/ads-plan.md") or ""
    check("chloe : le Worker 3 reprend mot pour mot la remise des Workers 1 et 2", fl_chloe.HEAD["S1"] in t3 and fl_chloe.HEAD["S2"] in t3, t3[:300])
    check("chloe : une étape de consolidation finale existe", any(str(s["id"]).startswith("CONS") for s in out["steps"]), out["steps"][-3:])
    check("chloe : le rapport final existe", d.get("hasFinalReport"))
    out["cid"] = cid
    return out


def sc_trio(lab, check):
    c, cid = lab.account("trio", "trio@mail-test.example", "198.51.100.61", plan="trio", workers=["lucas"])
    t0 = time.time()
    pid = SC._create(c, fl_chloe.BRIEF, "chloe")
    p = H.wait(c, pid, lambda p: p.get("waitingFor") == "PLAN_VALIDATION" or p.get("status") in H.TERMINAL, timeout=120)
    st, d0 = c.get("/api/projects/%s" % pid)
    plan_steps = [s for s in (d0.get("plan") or {}).get("steps") or [] if not s.get("system")]
    check("trio : Chloé ne délègue qu'au Worker embauché (%s)" % ",".join(s["worker"] for s in plan_steps), {s["worker"] for s in plan_steps} == {"lucas"}, plan_steps)
    scope = d0.get("scope") or {}
    denied = scope.get("deniedWorkers") or []
    check("trio : le détail du projet liste les Workers que Chloé ne peut pas utiliser", "seoya" in denied and "maya" in denied and scope.get("allowedWorkers") == ["lucas"], scope)
    notes = json.dumps((d0.get("plan") or {}).get("assumptions") or [], ensure_ascii=False)
    check("trio : le plan écrit lesquels sont indisponibles", "seoya" in notes and "maya" in notes, notes[:200])
    p = SC._drive(c, pid, lambda p: p.get("status") in H.TERMINAL, timeout=200)
    snap = SC._snap(c, pid)
    check("trio : le projet va au bout avec ce qui est permis (DONE)", snap["detail"].get("status") == "DONE", snap["detail"].get("status"))
    out = F.summary_of(lab, snap, t0, pid)
    out["scope"] = scope
    return out


def sc_input(lab, check):
    c, cid = lab.account("input", "input@mail-test.example", "198.51.100.62", plan="scale")
    t0 = time.time()
    pid = SC._create(c, "TEST-QUESTION facture : créer le modèle de facture de mon entreprise", "lucas")
    p = H.wait(c, pid, lambda p: p.get("waitingFor") == "PLAN_VALIDATION", timeout=120)
    c.post("/api/projects/%s/plan/approve" % pid, {}, headers=SC.ORIGIN)
    p = H.wait(c, pid, lambda p: p.get("status") in ("WAITING_INPUT",) + H.TERMINAL, timeout=120)
    check("input : le projet s'arrête en WAITING_INPUT (%s)" % p.get("waitingFor"), p.get("status") == "WAITING_INPUT" and p.get("waitingFor") == "INPUT", p)
    st, d = c.get("/api/projects/%s" % pid)
    qs = d.get("questions") or []
    check("input : une seule question, précise, avec sa raison", len(qs) == 1 and "raison sociale" in qs[0].get("question", "") and qs[0].get("why"), qs)
    steps = {s["id"]: s["status"] for s in (d.get("plan") or {}).get("steps") or []}
    check("input : les étapes indépendantes ont continué pendant l'attente (%s)" % steps, steps.get("S2") == "DONE", steps)
    if qs:
        st, r = c.post("/api/projects/%s/input" % pid, {"questionId": qs[0]["id"], "answer": "Bonvin Menuiserie Sàrl"}, headers=SC.ORIGIN)
        check("input : la réponse du client est acceptée", st == 200, (st, r))
    p = H.wait(c, pid, lambda p: p.get("status") in H.TERMINAL, timeout=200)
    check("input : après la réponse le projet reprend seul et finit (DONE)", p.get("status") == "DONE", p)
    snap = SC._snap(c, pid)
    return F.summary_of(lab, snap, t0, pid)


def _set_limits(lab, **kw):
    path = os.path.join(lab.app, "core", "usage", "USAGE-LIMITS.json")
    with open(path, encoding="utf-8-sig") as f:
        lim = json.load(f)
    lim.update(kw)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(lim, f)


def sc_quota(lab, check):
    """Fenêtre de session courte (36 s) et petit contingent : le projet doit se mettre en pause avec l'heure exacte, reprendre SEUL au renouvellement, et reprendre TOUT DE SUITE
    quand le client monte en gamme (seconde partie, fenêtre longue)."""
    lab.set_knobs({"chf": 0.30})
    c, cid = lab.account("quota", "quota@mail-test.example", "198.51.100.63", plan="equipe")
    _set_limits(lab, sessionHours=0.01, overridesByClient={cid: {"sessionCredits": 16, "weekCredits": 400}})
    t0 = time.time()
    st, view = c.get("/api/usage")
    out = {"usageBefore": {k: v for k, v in view.items() if k != "_headers"}}
    pid = SC._create(c, "TEST-QUOTA tâche courte en trois étapes", "lucas")
    H.wait(c, pid, lambda p: p.get("waitingFor") == "PLAN_VALIDATION", timeout=120)
    c.post("/api/projects/%s/plan/approve" % pid, {}, headers=SC.ORIGIN)
    p = H.wait(c, pid, lambda p: p.get("status") in ("WAITING_QUOTA",) + H.TERMINAL, timeout=150)
    check("quota : le projet se met en pause WAITING_QUOTA (et ne meurt pas)", p.get("status") == "WAITING_QUOTA", p)
    check("quota : la reprise annonce l'heure exacte (resumeAtUtc)", bool(p.get("resumeAtUtc")), p.get("resumeAtUtc"))
    check("quota : la fenêtre qui borne est la session", (p.get("usage") or {}).get("binding") == "session", p.get("usage"))
    st, d = c.get("/api/projects/%s" % pid)
    steps_before = {s["id"]: s["status"] for s in (d.get("plan") or {}).get("steps") or []}
    out["pausedAt"] = {"progress": {k: v for k, v in p.items() if k != "events"}, "steps": steps_before, "creditsCharged": d.get("creditsCharged")}
    check("quota : l'état est conservé (étapes déjà faites restent DONE)", any(v == "DONE" for k, v in steps_before.items() if k.startswith("S")), steps_before)
    st, view = c.get("/api/usage")
    out["usageWhilePaused"] = {k: v for k, v in view.items() if k != "_headers"}
    check("quota : le client voit sa session pleine, l'heure de renouvellement et le forfait du dessus", bool(json.dumps(view)) and ("upgrade" in view or "nextPlan" in json.dumps(view) or "upgrade" in json.dumps(view)), list(view)[:12])
    resumed = H.wait(c, pid, lambda p: p.get("status") not in ("WAITING_QUOTA",), timeout=120)
    check("quota : la fenêtre se renouvelle et le projet reprend SEUL", resumed.get("status") not in ("WAITING_QUOTA", None) and not resumed.get("_timeout"), resumed.get("status"))
    # le projet peut se remettre en pause à la fenêtre suivante : on le laisse aller jusqu'au bout (chaque pause est une fenêtre de 36 s)
    final = H.wait(c, pid, lambda p: p.get("status") in H.TERMINAL, timeout=400)
    check("quota : le projet finit (DONE) après une ou plusieurs pauses", final.get("status") == "DONE", final.get("status"))
    snap = SC._snap(c, pid)
    pauses = [e for e in snap["log"].get("events") or [] if "quota" in json.dumps(e, ensure_ascii=False).lower()]
    out["quotaEvents"] = [{"type": e.get("type"), "text": e.get("text")} for e in pauses][:12]
    out["final"] = F.summary_of(lab, snap, t0, pid)
    # ---- seconde partie : montée en gamme pendant la pause
    _set_limits(lab, sessionHours=1.0)
    c2, cid2 = lab.account("quota2", "quota2@mail-test.example", "198.51.100.64", plan="equipe")
    _set_limits(lab, sessionHours=1.0, overridesByClient={cid: {"sessionCredits": 16, "weekCredits": 400}, cid2: {"sessionCredits": 16, "weekCredits": 400}})
    pid2 = SC._create(c2, "TEST-QUOTA tâche courte en trois étapes", "lucas")
    H.wait(c2, pid2, lambda p: p.get("waitingFor") == "PLAN_VALIDATION", timeout=120)
    c2.post("/api/projects/%s/plan/approve" % pid2, {}, headers=SC.ORIGIN)
    p2 = H.wait(c2, pid2, lambda p: p.get("status") in ("WAITING_QUOTA",) + H.TERMINAL, timeout=150)
    check("quota/montée : pause WAITING_QUOTA avec fenêtre longue (1 h)", p2.get("status") == "WAITING_QUOTA", p2)
    o = lab.owner()
    _set_limits(lab, sessionHours=1.0, overridesByClient={})
    st, r = o.post("/api/admin/set-plan", {"clientId": cid2, "planId": "pro", "paidMonths": 1})
    t_up = time.time()
    p3 = H.wait(c2, pid2, lambda p: p.get("status") != "WAITING_QUOTA", timeout=90)
    out["upgradeResumeSeconds"] = round(time.time() - t_up, 1)
    check("quota/montée : la montée en gamme relance le projet tout de suite (%.0f s, fenêtre de 1 h non écoulée)" % out["upgradeResumeSeconds"], not p3.get("_timeout"), p3.get("status"))
    fin2 = H.wait(c2, pid2, lambda p: p.get("status") in H.TERMINAL, timeout=200)
    check("quota/montée : le projet finit (DONE)", fin2.get("status") == "DONE", fin2.get("status"))
    lab.set_knobs({})
    return out


def sc_restart(lab, check):
    """Mort brutale du serveur (kill -9) pendant une étape ; redémarrage ; le projet doit reprendre et finir sans doublon ni état corrompu."""
    lab.set_knobs({"slow": {"S3": 40}})
    c, cid = lab.account("restart", "restart@mail-test.example", "198.51.100.65", plan="scale", connectors=["wordpress"])
    t0 = time.time()
    pid = SC._create(c, fl_seo.BRIEF, "seoya")
    H.wait(c, pid, lambda p: p.get("waitingFor") == "PLAN_VALIDATION", timeout=120)
    c.post("/api/projects/%s/plan/approve" % pid, {}, headers=SC.ORIGIN)
    p = H.wait(c, pid, lambda p: (p.get("currentStep") or {}).get("id") == "S3" or p.get("status") in H.TERMINAL, timeout=120)
    time.sleep(2)
    st0, d0 = c.get("/api/projects/%s" % pid)
    running = {s["id"]: s["status"] for s in (d0.get("plan") or {}).get("steps") or []}
    check("restart : le serveur est tué en plein travail (S3 en cours : %s)" % running.get("S3"), running.get("S3") == "RUNNING", running)
    lab.kill_hard()
    lab.set_knobs({})
    lab.start()
    c.opener.close = getattr(c.opener, "close", lambda: None)
    c, cid = lab.clients["restart"]
    out = {"before": running}
    p = H.wait(c, pid, lambda p: p.get("status") in H.TERMINAL or p.get("status") == "WAITING_INPUT", timeout=300)
    st, d = c.get("/api/projects/%s" % pid)
    check("restart : après redémarrage le projet reprend et finit (DONE, sans intervention)", d.get("status") == "DONE", (d.get("status"), d.get("statusReason")))
    ap = SC._approvals({"approvals": c.get("/api/projects/%s/approvals" % pid)[1]})
    keys = [(a.get("connectorId"), a.get("operation"), (a.get("display") or {}).get("title")) for a in ap]
    check("restart : aucun article d'approbation en double (%d)" % len(ap), len(keys) == len(set(keys)), keys)
    check("restart : aucun appel de connecteur de plus", len(lab.connector_calls()) == lab.expected_calls)
    snap = SC._snap(c, pid)
    out["final"] = F.summary_of(lab, snap, t0, pid)
    ev = [e for e in snap["log"].get("events") or [] if any(k in json.dumps(e, ensure_ascii=False).lower() for k in ("reprise", "redémarr", "resume", "orphan", "interrompu"))]
    out["resumeEvents"] = [{"type": e.get("type"), "text": e.get("text")} for e in ev][:8]
    return out
