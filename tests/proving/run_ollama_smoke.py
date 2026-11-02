# -*- coding: utf-8 -*-
"""UN smoke avec le vrai petit modèle local (Ollama, gratuit) dans le vrai moteur de projets. Voir docs/PROVING-REPORT.md, section « smoke avec le modèle local ».

    python tests/proving/run_ollama_smoke.py [--model qwen2.5:1.5b] [--phase gate|free|scripted|all] [--out smoke.json]

  gate     : serveur lancé avec BK_AI_PROVIDER=ollama : la création d'un projet doit être REFUSÉE (ENGINE_NO_PROJECTS), c'est la porte qui marche.
  free     : lanceur Ollama (ollama_runner.py) sur tout le projet, planification comprise : on observe ce que fait un petit modèle livré à lui-même.
  scripted : même chose mais le plan est écrit par le banc (plan connu bon) : on observe le modèle sur l'exécution et la vérification seules.

Aucun appel Anthropic (la clé n'est jamais transmise). Coût : 0."""
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import harness as H  # noqa: E402

ORIGIN = {}
GOAL = "Écris une courte page d'accueil de 3 phrases pour la boulangerie Pain Doré à Fribourg, dans le fichier site/accueil.md. N'invente ni prix ni horaires."
PLAN = {"goal": "Page d'accueil de la boulangerie Pain Doré", "language": "fr", "assumptions": [{"id": "A1", "text": "Prix et horaires non fournis : non mentionnés."}],
        "criteria": [{"id": "C1", "text": "Le fichier site/accueil.md existe et n'est pas vide", "kind": "auto", "check": {"type": "file_exists", "path": "site/accueil.md", "minBytes": 40}},
                     {"id": "C2", "text": "Aucun prix ni horaire inventé", "kind": "auto", "check": {"type": "file_contains", "path": "site/accueil.md", "mustContain": ["re:[Pp]ain"], "mustNotContain": ["re:\\d+ ?(CHF|Fr\\.|€)", "re:\\d{1,2} ?h ?\\d{0,2}"]}}],
        "steps": [{"id": "S1", "title": "Écrire la page d'accueil", "worker": "lucas", "goal": "Écrire site/accueil.md : 3 phrases chaleureuses sur la boulangerie Pain Doré à Fribourg, sans prix ni horaire.",
                   "criteriaIds": ["C1", "C2"], "expectedOutputs": ["site/accueil.md"], "estimateCredits": 6}],
        "estimate": {"creditsMin": 6, "creditsMax": 20, "hoursMin": 0.1, "hoursMax": 0.3}}


def drive(c, pid, timeout):
    def act(p):
        if p.get("waitingFor") == "PLAN_VALIDATION":
            c.post("/api/projects/%s/plan/approve" % pid, {}, headers=ORIGIN)
    return H.wait(c, pid, lambda p: p.get("status") in H.TERMINAL + ("WAITING_INPUT",) and p.get("waitingFor") != "PLAN_VALIDATION", timeout=timeout, on_status=act, every=2.0)


def traces(lab, cid, pid):
    out = []
    base = os.path.join(lab.project_dir(cid, pid), "steps")
    for sid in sorted(os.listdir(base)) if os.path.isdir(base) else []:
        for att in sorted(os.listdir(os.path.join(base, sid))):
            p = os.path.join(base, sid, att, "ollama-trace.jsonl")
            if os.path.isfile(p):
                lines = [json.loads(x) for x in open(p, encoding="utf-8") if x.strip()]
                out.append({"step": sid, "attempt": att, "iterations": len({x['iter'] for x in lines}), "toolCalls": [x.get("tool") or [c.get("name") for c in x.get("calls") or []] for x in lines],
                            "toolErrors": [(x.get("tool"), x.get("error")) for x in lines if x.get("tool") and not x.get("ok")]})
    return out


def run_phase(phase, model, timeout):
    lab = H.Lab()
    res = {"phase": phase, "model": model}
    try:
        lab.prepare()
        env = {"PROVE_RUNNER": os.path.join(lab.app, "tests", "proving", "ollama_runner.py"), "BK_OLLAMA_URL": os.environ.get("BK_OLLAMA_URL", "http://127.0.0.1:11434"), "BK_OLLAMA_MODEL": model}
        if phase == "gate":
            env.update(BK_AI_PROVIDER="ollama")
        lab.extra_env = env
        if phase == "scripted":
            lab.set_knobs({"scriptedPlan": PLAN})
        port = lab.start()
        ORIGIN["Origin"] = "http://127.0.0.1:%d" % port
        c, cid = lab.account("smoke", "smoke@mail-test.example", "198.51.100.71", plan="scale")
        t0 = time.time()
        st, out = c.post("/api/projects", {"goal": GOAL, "workerId": "lucas", "autoStart": False}, headers=ORIGIN)
        res["createStatus"] = st
        res["createResponse"] = {k: v for k, v in out.items() if k != "_headers"}
        if st != 201:
            return res
        pid = out["projectId"]
        p = drive(c, pid, timeout)
        st, d = c.get("/api/projects/%s" % pid)
        res.update(seconds=round(time.time() - t0, 1), status=d.get("status"), statusReason=d.get("statusReason"), creditsCharged=d.get("creditsCharged"),
                   steps=[{"id": s.get("id"), "kind": s.get("kind"), "worker": s.get("worker"), "status": s.get("status")} for s in (d.get("plan") or {}).get("steps") or []],
                   criteria={x["id"]: x.get("verdict") for x in (d.get("plan") or {}).get("criteria") or []}, traces=traces(lab, cid, pid),
                   events=[(e.get("type"), (e.get("text") or "")[:120]) for e in (c.get("/api/projects/%s/log" % pid)[1].get("events") or [])][-14:])
        try:
            with open(os.path.join(lab.project_dir(cid, pid), "workspace", "site", "accueil.md"), encoding="utf-8") as f:
                res["fileWritten"] = f.read()[:600]
        except OSError:
            res["fileWritten"] = None
        return res
    finally:
        lab.cleanup()


def main():
    args = sys.argv[1:]
    model = args[args.index("--model") + 1] if "--model" in args else "qwen2.5:1.5b"
    phase = args[args.index("--phase") + 1] if "--phase" in args else "all"
    out = args[args.index("--out") + 1] if "--out" in args else os.path.join(HERE, "last-smoke.json")
    results = []
    for ph in (["gate", "free", "scripted"] if phase == "all" else [phase]):
        print("== phase", ph, flush=True)
        r = run_phase(ph, model, 420 if ph != "gate" else 60)
        print(json.dumps({k: v for k, v in r.items() if k not in ("traces", "events")}, ensure_ascii=False)[:900], flush=True)
        results.append(r)
        with open(out, "w", encoding="utf-8") as f:
            json.dump(results, f, ensure_ascii=False, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
