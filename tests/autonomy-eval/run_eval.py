# -*- coding: utf-8 -*-
"""Banc d'évaluation de l'autonomie des Workers : exécute des scénarios avec la boucle actuelle (baseline), le moteur de projet (project) ou une référence
simple (reference), note les résultats avec des contrôles SANS modèle + un juge à l'aveugle, écrit du JSON et un rapport markdown.

    python tests/autonomy-eval/run_eval.py list
    python tests/autonomy-eval/run_eval.py validate
    python tests/autonomy-eval/run_eval.py selftest                      # les contrôles détectent-ils 100 % des défauts semés ?
    python tests/autonomy-eval/run_eval.py run --dry-run --arms baseline,project,reference --scenarios all --out C:/tmp/eval
    python tests/autonomy-eval/run_eval.py run --arms reference --provider ollama --scenarios S13-compte-rendu-reunion --judge none --out C:/tmp/eval
    python tests/autonomy-eval/run_eval.py report --in C:/tmp/eval/<run> [--out rapport.md]

--dry-run : fausse API, faux lanceur, juge simulé. AUCUN appel Anthropic sans --allow-anthropic + --max-usd > 0 + ANTHROPIC_API_KEY (crédit épuisé : ne pas le faire).
"""
import argparse
import copy
import datetime
import json
import os
import shutil
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "..", "dashboard"))

import eval_lib as E  # noqa: E402
import engines  # noqa: E402
import judge as J  # noqa: E402
import report as R  # noqa: E402


def now_id():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def pick(scenarios, spec):
    if spec in (None, "", "all"):
        return list(scenarios.values())
    out = []
    for key in spec.split(","):
        key = key.strip()
        hits = [s for sid, s in scenarios.items() if sid == key or sid.startswith(key)]
        if not hits:
            raise SystemExit("scénario inconnu : %s" % key)
        out += hits
    return out


def grade_run(scenario, res, judge_provider, args, guard):
    """Complète le dict du bras avec la note (contrôles automatiques + juge)."""
    rec = {k: v for k, v in res.items() if k != "workspaceDir"}
    rec["workspace"] = res.get("workspaceDir")
    if not res.get("workspaceDir") or res["status"] in ("SKIPPED", "REFUSED", "ERROR", "CAPPED"):
        rec.update(completed=False, autoScore=None, judgeScore=None, score=None, criteria=[], fabrications=[], judge=None)
        return rec
    ws = E.Workspace(res["workspaceDir"], res.get("connectorCalls"), engines.fixtures_of(scenario))
    g0 = E.grade(scenario, ws, None)
    jr = None
    scores = None
    if judge_provider != "none":
        jr = J.judge(scenario, res["workspaceDir"], g0["autoScore"], judge_provider, passes=scenario["judge"].get("passes", 2), model=args.judge_model, guard=guard,
                     allow_anthropic=args.allow_anthropic)
        scores = jr.get("scores")
    g = E.grade(scenario, ws, scores)
    rec.update(completed=g["completed"] if scores is not None else False, autoScore=g["autoScore"], judgeScore=g["judgeScore"], score=g["score"], criteria=g["criteria"],
               fabrications=g["fabrications"], judge=jr, judged=g["judged"], deliverablesOk=g["deliverablesOk"])
    auto = [c for c in g["criteria"] if c["kind"] == "auto"]
    rec["criteriaMet"] = "%d/%d" % (sum(1 for c in auto if c["ok"]), len(auto))
    if scores is None:
        rec["notes"] = list(rec.get("notes") or []) + ["partie juge non notée : « terminé » exige le juge, la complétion n'est pas comptée"]
    return rec


def cmd_run(args):
    scenarios = E.load_scenarios()
    chosen = pick(scenarios, args.scenarios)
    arms = [a.strip() for a in args.arms.split(",") if a.strip()]
    for a in arms:
        if a not in engines.ARMS:
            raise SystemExit("bras inconnu : %s" % a)
    provider = "fake" if args.dry_run and args.provider == "auto" else (args.provider if args.provider != "auto" else "fake")
    judge_provider = args.judge or ("fake" if args.dry_run else "none")
    guard = engines.SpendGuard(args.max_usd)
    run_id = now_id()
    out_root = os.path.join(args.out, run_id)
    os.makedirs(out_root, exist_ok=True)
    records = []
    t0 = time.time()
    for s in chosen:
        for arm in arms:
            d = os.path.join(out_root, s["id"], arm)
            os.makedirs(d, exist_ok=True)
            print("-> %s / %s ..." % (s["id"], arm), flush=True)
            kw = {"provider": provider, "dry_run": args.dry_run}
            if arm == "reference":
                kw.update(model=args.model, guard=guard, allow_anthropic=args.allow_anthropic, num_predict=args.num_predict)
            res = engines.RUNNERS[arm](s, d, **kw)
            rec = grade_run(s, res, judge_provider, args, guard)
            rec["worker"] = s["workerId"]
            records.append(rec)
            with open(os.path.join(d, "result.json"), "w", encoding="utf-8") as f:
                json.dump(rec, f, ensure_ascii=False, indent=1)
            print("   %s  note=%s  terminé=%s  %s" % (rec["status"], rec.get("score"), rec.get("completed"), rec.get("error") or ""), flush=True)
    doc = {"schema": "BK-EVAL-RESULTS-V1", "runId": run_id, "createdUtc": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "dryRun": bool(args.dry_run),
           "provider": provider, "judge": judge_provider, "arms": arms, "scenarios": [s["id"] for s in chosen], "spend": {"capUsd": guard.cap, "spentUsd": round(guard.spent, 6), "log": guard.log},
           "elapsedSec": round(time.time() - t0, 1), "runs": records}
    with open(os.path.join(out_root, "results.json"), "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=1)
    md = R.render(doc)
    with open(os.path.join(out_root, "rapport.md"), "w", encoding="utf-8") as f:
        f.write(md)
    print("\nRésultats : %s\nRapport : %s" % (os.path.join(out_root, "results.json"), os.path.join(out_root, "rapport.md")))
    return 0


def cmd_list(_args):
    for sid, s in E.load_scenarios().items():
        crit = s["rubric"]["criteria"]
        print("%-28s %-8s %-9s %2d critères (%d auto, %d juge)  %s" % (sid, s["workerId"], s["difficulty"], len(crit), sum(1 for c in crit if c["kind"] == "auto"), sum(1 for c in crit if c["kind"] == "judge"), s["title"]))
    return 0


def cmd_validate(_args):
    bad = 0
    for sid, s in E.load_scenarios().items():
        for e in E.validate_scenario(s):
            print("%s : %s" % (sid, e))
            bad += 1
    print("scénarios invalides : %d" % bad)
    return 1 if bad else 0


def selftest():
    """Chaque contrôle automatique : passe sur le jeu conforme, échoue sur son défaut semé. Renvoie (détectés, total, manqués)."""
    det = tot = 0
    missed = []
    for sid, s in E.load_scenarios().items():
        good = E.synth_good(s)
        fx = engines.fixtures_of(s)
        with tempfile.TemporaryDirectory() as d:
            E.write_files(d, good)
            g = E.grade(s, E.Workspace(d, fixtures=fx), None)
        if g["autoScore"] < 1.0 and not all(c["ok"] for c in g["criteria"] if c["kind"] == "auto" and c["id"] != "C_ops"):
            missed.append((sid, "jeu conforme refusé", [c["id"] for c in g["criteria"] if c["kind"] == "auto" and not c["ok"]]))
        for c in s["rubric"]["criteria"]:
            if c["kind"] != "auto" or c["check"]["type"] == "connector_ops":
                continue
            files = copy.deepcopy(good)
            if not E.seed_defect(c, files, None):
                missed.append((sid, c["id"], "pas de défaut défini"))
                continue
            tot += 1
            with tempfile.TemporaryDirectory() as d:
                E.write_files(d, files)
                ok, _ = E.run_check(c["check"], E.Workspace(d, fixtures=fx))
            if ok:
                missed.append((sid, c["id"], "défaut non détecté"))
            else:
                det += 1
    return det, tot, missed


def cmd_selftest(_args):
    det, tot, missed = selftest()
    print("défauts semés détectés : %d/%d" % (det, tot))
    for m in missed:
        print("  MANQUÉ", m)
    return 0 if not missed else 1


def cmd_report(args):
    path = os.path.join(args.inp, "results.json") if os.path.isdir(args.inp) else args.inp
    with open(path, encoding="utf-8") as f:
        doc = json.load(f)
    md = R.render(doc)
    if args.out:
        open(args.out, "w", encoding="utf-8").write(md)
        print("rapport écrit :", args.out)
    else:
        print(md)
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list").set_defaults(fn=cmd_list)
    sub.add_parser("validate").set_defaults(fn=cmd_validate)
    sub.add_parser("selftest").set_defaults(fn=cmd_selftest)
    r = sub.add_parser("run")
    r.add_argument("--scenarios", default="all")
    r.add_argument("--arms", default="baseline,project,reference")
    r.add_argument("--provider", default="auto", choices=["auto"] + list(engines.PROVIDERS))
    r.add_argument("--judge", default=None, choices=["fake", "ollama", "anthropic", "none"])
    r.add_argument("--judge-model", default=None)
    r.add_argument("--model", default=None)
    r.add_argument("--dry-run", action="store_true")
    r.add_argument("--max-usd", type=float, default=0.0)
    r.add_argument("--allow-anthropic", action="store_true")
    r.add_argument("--num-predict", type=int, default=3000)
    r.add_argument("--out", default=os.path.join(tempfile.gettempdir(), "bk-autonomy-eval"))
    r.set_defaults(fn=cmd_run)
    p = sub.add_parser("report")
    p.add_argument("--in", dest="inp", required=True)
    p.add_argument("--out", default=None)
    p.set_defaults(fn=cmd_report)
    args = ap.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
