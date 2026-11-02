# -*- coding: utf-8 -*-
"""Banc de preuve MÉCANIQUE du moteur de projets, par le vrai serveur HTTP (voir docs/PROVING-REPORT.md).

    python tests/proving/run_proving.py [--only site,seo,prospects,ads,chloe,trio,quota,input,restart] [--keep] [--out evidence.json]

Chaque scénario écrit ses preuves (états, journaux, approbations, appels de connecteurs) dans un JSON. Aucun modèle, aucun réseau, aucun coût.
--keep laisse le serveur démarré à la fin (recette manuelle dans le navigateur) et affiche son adresse ; le dossier jetable n'est alors PAS supprimé."""
import json
import os
import sys
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import harness as H  # noqa: E402
import fl_ads  # noqa: E402
import fl_chloe  # noqa: E402
import fl_prospects  # noqa: E402
import fl_seo  # noqa: E402
import fl_site  # noqa: E402

CHECKS = []
EVIDENCE = {}
ORIGIN = {}


def check(name, cond, detail=""):
    CHECKS.append({"name": name, "ok": bool(cond), "detail": str(detail)[:400] if not cond else ""})
    print(("  PASS  " if cond else "  FAIL  ") + name + (("  [%s]" % str(detail)[:300]) if detail and not cond else ""))
    return bool(cond)


def create(c, goal, worker, **kw):
    body = {"goal": goal, "workerId": worker, "autoStart": False}
    body.update(kw)
    st, out = c.post("/api/projects", body, headers=ORIGIN)
    assert st == 201, (st, out)
    return out["projectId"]


def drive(lab, c, pid, until, timeout=300, answers=None, approve_plan=True):
    """Valide le plan quand il attend le « go » du client, répond aux questions bloquantes (answers: {mot-clé: réponse}), jusqu'à until(progress)."""
    asked = []

    def act(p):
        wf = p.get("waitingFor")
        if wf == "PLAN_VALIDATION" and approve_plan:
            c.post("/api/projects/%s/plan/approve" % pid, {}, headers=ORIGIN)
        if p.get("status") == "WAITING_INPUT" and wf == "INPUT" and answers is not None:
            st, d = c.get("/api/projects/%s" % pid)
            for q in d.get("openQuestions") or d.get("questions") or []:
                if q.get("id") not in asked:
                    asked.append(q.get("id"))
                    c.post("/api/projects/%s/input" % pid, {"questionId": q.get("id"), "answer": answers}, headers=ORIGIN)
    return H.wait(c, pid, until, timeout=timeout, on_status=act)


def snapshot(lab, c, cid, pid):
    st, d = c.get("/api/projects/%s" % pid)
    st2, ap = c.get("/api/projects/%s/approvals" % pid)
    st3, dl = c.get("/api/projects/%s/deliverables" % pid)
    st4, lg = c.get("/api/projects/%s/log" % pid)
    return {"detail": d, "approvals": ap, "deliverables": dl, "log": lg}


def summarize(snap, t0):
    d = snap["detail"]
    steps = (d.get("plan") or {}).get("steps") or []
    approvals = (snap["approvals"] or {}).get("approvals") or (snap["approvals"] or {}).get("items") or []
    return {"status": d.get("status"), "statusReason": d.get("statusReason"), "seconds": round(time.time() - t0, 1), "steps": [{"id": s.get("id"), "worker": s.get("worker"), "status": s.get("status"), "system": s.get("system")} for s in steps],
            "criteria": {c["id"]: c.get("verdict") for c in (d.get("plan") or {}).get("criteria") or []}, "budget": d.get("budget"),
            "approvals": [{"id": a.get("id"), "connector": a.get("connectorId"), "operation": a.get("operation"), "kind": a.get("kind"), "status": a.get("status"), "risk": a.get("risk"),
                           "title": (a.get("display") or {}).get("title")} for a in approvals],
            "deliverables": [x.get("path") for x in (snap["deliverables"] or {}).get("deliverables") or []]}


def main():
    args = sys.argv[1:]
    only = None
    if "--only" in args:
        only = set(args[args.index("--only") + 1].split(","))
    keep = "--keep" in args
    out_path = args[args.index("--out") + 1] if "--out" in args else os.path.join(HERE, "last-evidence.json")
    lab = H.Lab()
    try:
        lab.prepare()
        port = lab.start()
        ORIGIN["Origin"] = "http://127.0.0.1:%d" % port
        print("serveur de preuve sur le port", port, "dossier", lab.root)
        import scenarios as S
        import sc_flagships as F
        S.ORIGIN = ORIGIN
        import sc_engine as G
        registry = [("site", F.sc_site), ("seo", F.sc_seo), ("prospects", F.sc_prospects), ("ads", F.sc_ads), ("chloe", G.sc_chloe), ("trio", G.sc_trio), ("input", G.sc_input),
                    ("quota", G.sc_quota), ("restart", G.sc_restart)]
        for name, fn in registry:
            if only and name not in only:
                continue
            print("\n== %s ==" % name)
            try:
                EVIDENCE[name] = fn(lab, check)
            except Exception as e:  # noqa: BLE001
                traceback.print_exc()
                check("%s : le scénario s'exécute" % name, False, "%s: %s" % (type(e).__name__, e))
        EVIDENCE["_checks"] = CHECKS
        with open(out_path, "w", encoding="utf-8") as f:
            json.dump(EVIDENCE, f, ensure_ascii=False, indent=1)
        failed = [c for c in CHECKS if not c["ok"]]
        print("\n%d contrôles, %d échec(s). Preuves : %s" % (len(CHECKS), len(failed), out_path))
        if keep:
            creds = args[args.index("--creds") + 1] if "--creds" in args else None
            if creds:                                          # identifiants de TEST tirés au sort pour ce lancement (serveur local jetable), hors du dépôt
                with open(creds, "w", encoding="utf-8") as f:
                    json.dump({"port": port, "password": H.E.PASSWORD, "accounts": {k: {"email": "%s@mail-test.example" % k, "clientId": v[1]} for k, v in lab.clients.items()}}, f)
            print("Serveur laissé démarré : http://127.0.0.1:%d  (Ctrl+C pour arrêter)" % port)
            try:
                while True:
                    time.sleep(3600)
            except KeyboardInterrupt:
                pass
        return 1 if failed else 0
    finally:
        if not keep:
            lab.cleanup()


if __name__ == "__main__":
    sys.exit(main())
