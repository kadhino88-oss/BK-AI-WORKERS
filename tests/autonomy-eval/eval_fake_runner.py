# -*- coding: utf-8 -*-
"""Faux lanceur d'étape du BANC D'ÉVALUATION (dry-run du bras « moteur de projet »). Même contrat que tests/projects/fake_runner.py (qui reste intact) mais
le comportement vient du scénario d'évaluation : le plan reprend les étapes de la recette, et chaque fichier du livrable « conforme » est écrit par une
étape (via les VRAIS outils de l'espace de travail). Aucun modèle, aucun réseau.

    python eval_fake_runner.py <input.json> <result.json>      (EVAL_PLAN = chemin d'un JSON {plan, assign:{stepId:{chemin:contenu}}, evidence})
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "projects"))
import fake_runner  # noqa: E402


def _load():
    with open(os.environ["EVAL_PLAN"], encoding="utf-8") as f:
        return json.load(f)


def behavior(inp):
    cfg = _load()
    kind = inp["kind"]
    if kind in ("plan", "replan"):
        return {"actions": [{"tool": "project_plan", "input": {"action": "set", "plan": cfg["plan"]}}], "complete": {"status": "DONE", "summary": "Plan prêt (banc d'évaluation)."}}
    if kind in ("execute", "fix"):
        files = (cfg.get("assign") or {}).get(inp["stepId"]) or {}
        text = {p: c for p, c in files.items() if not isinstance(c, dict)}
        actions = [{"tool": "workspace_write", "input": {"path": p, "mode": "overwrite", "content": c}} for p, c in text.items()]
        outs = list(files)
        spec = next((s for s in (fake_runner.read_json(os.path.join(inp["paths"]["projectDir"], "plan.json"), {}).get("plan") or {}).get("steps") or [] if s["id"] == inp["stepId"]), {})
        ev = cfg["evidence"]
        claims = [{"criterionId": c, "claim": "met", "evidence": [{"type": "file", "ref": ev}]} for c in spec.get("criteriaIds") or []]
        return {"actions": actions + [{"tool": "deliverable_register", "input": {"path": p, "title": p}} for p in text],
                "complete": {"status": "DONE", "summary": "%s fait." % inp["stepId"], "deliverables": [{"path": p, "title": p} for p in text], "criteriaClaims": claims,
                             "summaryUpdate": "%s ok." % inp["stepId"], "handoffNote": "Fichiers : %s" % ", ".join(outs)}}
    if kind == "verify":
        plan = (fake_runner.read_json(os.path.join(inp["paths"]["projectDir"], "plan.json"), {}) or {}).get("plan") or {}
        scope = inp.get("scope") or "final"
        crit = [{"id": c["id"], "verdict": "PASS", "note": "Vérifié.", "evidence": [{"type": "file", "ref": cfg["evidence"]}]}
                for c in plan.get("criteria") or [] if (scope == "consistency") == (c["id"] == "C-coherence")]
        return {"complete": {"status": "DONE", "summary": "Vérification terminée.", "verification": {"criteria": crit, "consistency": [], "overall": "PASS", "summary": "RAS"}}}
    return fake_runner.default_behavior_orig(inp)


def main():
    fake_runner.default_behavior_orig = fake_runner.default_behavior
    fake_runner.default_behavior = behavior
    fake_runner.main()


if __name__ == "__main__":
    main()
