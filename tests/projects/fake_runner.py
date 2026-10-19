# -*- coding: utf-8 -*-
"""Faux lanceur d'etape pour les tests du moteur : meme contrat que Project-StepRunner.ps1 (input.json -> result.json, cost.json), SANS modele.

    python fake_runner.py <input.json> <result.json>

Les actions passent par les VRAIS outils (project_tools.run_tool) : memes ecritures dans workspace/ et spool/ que le lanceur PowerShell, memes
validations. Le comportement vient du scenario (variable FAKE_SCENARIO = chemin d'un JSON) :
    { "<kind>:<stepId>:<tentative>" | "<kind>:<stepId>" | "<stepId>" | "<kind>" : comportement, ... }   (la cle la plus precise gagne)
Comportement : {"actions":[{"tool":..., "input":{...}}], "complete":{...step_complete...}, "status":"DONE|PARTIAL|...", "exitReason":"...",
                "chf":0.02 (defaut : "_defaults": {"chf": ..} dans le scenario), "crash":true, "hang":true, "sleep":0.2, "answerText":"...", "error":"...", "exit":12, "writeResult":false}
Sans scenario, des comportements par defaut produisent un projet complet et coherent (plan de 3 etapes, livrables, verdicts PASS).
"""
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "dashboard"))
import project_tools  # noqa: E402


def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8-sig") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def tool(inp, name, payload):
    return project_tools.run_tool(name, {"projectDir": inp["paths"]["projectDir"], "stepDir": inp["paths"]["stepDir"], "stepId": inp["stepId"],
                                         "kind": inp["kind"], "worker": inp["worker"], "input": payload})


def pick(scenario, inp):
    k, s, a = inp["kind"], inp["stepId"], inp["attempt"]
    for key in (f"{k}:{s}:{a}", f"{k}:{s}", f"{s}:{a}", s, k):
        if key in scenario:
            return scenario[key]
    return None


def default_plan(inp):
    return {"goal": "Creer le site vitrine", "language": "fr",
            "assumptions": [{"id": "A1", "text": "3 pages"}],
            "criteria": [{"id": "C1", "text": "Les pages existent", "kind": "auto", "check": {"type": "file_exists", "path": "site/index.html", "minBytes": 5}},
                         {"id": "C2", "text": "Le ton est professionnel", "kind": "rubric", "rubric": "Aucun chiffre invente."}],
            "steps": [{"id": "S1", "title": "Accueil", "worker": "lucas", "goal": "Ecrire l'accueil", "criteriaIds": ["C1"], "expectedOutputs": ["site/index.html"], "estimateCredits": 4},
                      {"id": "S2", "title": "A propos", "worker": "emma", "goal": "Ecrire a propos", "criteriaIds": ["C2"], "expectedOutputs": ["site/about.html"], "estimateCredits": 4},
                      {"id": "S3", "title": "Liens", "worker": "lucas", "goal": "Relier les pages", "dependsOn": ["S1", "S2"], "criteriaIds": ["C1"],
                       "expectedOutputs": ["site/links.html"], "estimateCredits": 4}],
            "estimate": {"creditsMin": 8, "creditsMax": 16, "hoursMin": 0.5, "hoursMax": 1}}


def default_behavior(inp):
    kind = inp["kind"]
    ws = inp["paths"]["workspace"]
    plan = (read_json(os.path.join(inp["paths"]["projectDir"], "plan.json"), {}) or {}).get("plan") or {}
    if kind in ("plan", "replan"):
        return {"actions": [{"tool": "project_plan", "input": {"action": "set", "plan": default_plan(inp)}}], "complete": {"status": "DONE", "summary": "Plan pret."}}
    if kind in ("execute", "fix"):
        spec = next((s for s in plan.get("steps") or [] if s["id"] == inp["stepId"]), {})
        outs = spec.get("expectedOutputs") or [f"notes/{inp['stepId']}.md"]
        actions = [{"tool": "workspace_write", "input": {"path": p, "mode": "overwrite", "content": f"<h1>{p}</h1> Contenu produit par {inp['worker']} pour {inp['stepId']}."}} for p in outs]
        actions += [{"tool": "deliverable_register", "input": {"path": p, "title": p}} for p in outs]
        claims = [{"criterionId": c, "claim": "met", "evidence": [{"type": "file", "ref": outs[0]}]} for c in spec.get("criteriaIds") or []]
        return {"actions": actions, "complete": {"status": "DONE", "summary": f"{inp['stepId']} fait.", "deliverables": [{"path": p, "title": p} for p in outs],
                                                  "criteriaClaims": claims, "summaryUpdate": f"{inp['stepId']} ok.", "handoffNote": f"Fichiers : {', '.join(outs)}"}}
    if kind == "verify":
        crit = []
        some_file = None
        for dp, _d, fs in os.walk(ws):
            for n in sorted(fs):
                if n.endswith(".html") and not some_file:
                    some_file = os.path.relpath(os.path.join(dp, n), ws).replace(os.sep, "/")
        for c in plan.get("criteria") or []:
            crit.append({"id": c["id"], "verdict": "PASS", "note": "Verifie.", "evidence": [{"type": "file", "ref": some_file or "notes/x.md"}]})
        return {"complete": {"status": "DONE", "summary": "Verification terminee.", "verification": {"criteria": crit, "overall": "PASS", "summary": "RAS"}}}
    if kind == "consolidate":
        return {"complete": {"status": "DONE", "summary": "Voici vos livrables : le site est pret."}}
    if kind == "answer":
        return {"answerText": "Voici la reponse a votre question."}
    return {}


def main():
    in_path, out_path = sys.argv[1], sys.argv[2]
    inp = read_json(in_path)
    scenario = read_json(os.environ.get("FAKE_SCENARIO") or "", {}) or {}
    beh = pick(scenario, inp)
    base = default_behavior(inp)
    dflt = scenario.get("_defaults") if isinstance(scenario.get("_defaults"), dict) else {}
    if beh is None:
        beh = base
    else:                                   # ce que le scenario ne precise pas vient du comportement par defaut
        beh = dict(beh)
        if not any(k in beh for k in ("complete", "blocked", "report", "answerText", "hang", "crash")) and beh.get("status") not in ("FAILED", "RETRY_LATER", "BLOCKED", "NEEDS_INPUT"):
            beh["complete"] = base.get("complete")
            beh.setdefault("answerText", base.get("answerText", ""))
        if "actions" not in beh:
            beh["actions"] = base.get("actions") or []
    started = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    sd = inp["paths"]["stepDir"]
    with open(os.path.join(sd, "runner.log"), "a", encoding="utf-8") as f:
        f.write(f"fake runner {inp['kind']} {inp['stepId']} attempt {inp['attempt']}\n")
    if beh.get("sleep"):
        time.sleep(float(beh["sleep"]))
    for act in beh.get("actions") or []:
        out = tool(inp, act["tool"], act.get("input") or {})
        if act.get("expect_error") and out.get("ok"):
            print("expected an error", act)
        if beh.get("verbose"):
            print(json.dumps(out)[:300])
    chf = float(beh.get("chf", dflt.get("chf", 0.02)))
    usage = {"input_tokens": 1000, "output_tokens": 100, "api_calls": 2, "estimated_cost_usd": round(chf / 0.83107, 6), "estimated_cost_chf": chf,
             "cost_capped": bool(beh.get("capped")), "cost_ceiling_chf": inp.get("ceilingChf")}
    with open(os.path.join(sd, "cost.json"), "w", encoding="utf-8") as f:
        json.dump({"updatedUtc": started, "usage": usage}, f)
    if beh.get("crash"):
        os._exit(3)
    if beh.get("hang"):
        time.sleep(600)
    result = {"schema": "BK-STEP-RESULT-V1", "status": beh.get("status", "DONE"), "exitReason": beh.get("exitReason", "step_complete"), "report": beh.get("report") or {},
              "answerText": beh.get("answerText", ""), "usage": usage, "model": inp["model"], "iterations": 3, "filesImported": [], "error": beh.get("error"),
              "retryAfterSec": beh.get("retryAfterSec"), "startedUtc": started, "finishedUtc": started}
    comp = beh.get("complete")
    if comp is not None:
        out = tool(inp, "step_complete", comp)
        if out.get("ok"):
            result["report"] = out["result"]["report"]
            result["status"] = out["result"]["report"]["status"]
        else:
            result["status"], result["exitReason"], result["error"] = "FAILED", "step_complete", out.get("error")
            result["report"] = {"problems": out.get("problems")}
    blk = beh.get("blocked")
    if blk is not None:
        out = tool(inp, "step_blocked", blk)
        result["status"], result["exitReason"], result["report"] = "BLOCKED", "step_blocked", {"status": "BLOCKED", "summary": blk.get("detail"), "blocked": out["result"]["blocked"]}
    if beh.get("writeResult", True):
        tmp = out_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(result, f)
        os.replace(tmp, out_path)
    sys.exit(int(beh.get("exit", 0)))


if __name__ == "__main__":
    main()
