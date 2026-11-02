# -*- coding: utf-8 -*-
"""Aides communes du banc de preuve (tests/proving) : le « faux bon modèle » écrit des actions d'outils, jamais du texte libre.

Chaque flagship (site, seo, prospects, ads, chloe) fournit : plan(inp), execute(inp, step_id, attempt, fix) et verify(inp, scope). Les actions passent par les
VRAIS outils (project_tools.run_tool) ; les critères automatiques sont rejoués par le MOTEUR (project_checks), jamais par ce module.

Rien ici n'est un modèle : la QUALITÉ des textes n'est pas une preuve de ce que ferait un vrai modèle. Seules la mécanique (plan, étapes, espace de travail,
vérification, approbations, reprise, quotas) est mise à l'épreuve."""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(REPO, "dashboard"))


def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8-sig") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def read_ws(inp, rel):
    try:
        with open(os.path.join(inp["paths"]["workspace"], *rel.split("/")), encoding="utf-8") as f:
            return f.read()
    except OSError:
        return None


def exists_ws(inp, rel):
    return os.path.isfile(os.path.join(inp["paths"]["workspace"], *rel.split("/")))


def write(path, content):
    return {"tool": "workspace_write", "input": {"path": path, "mode": "overwrite", "content": content}}


def register(path, title):
    return {"tool": "deliverable_register", "input": {"path": path, "title": title}}


def claim(cid, ref, text="critère rempli"):
    return {"criterionId": cid, "claim": text, "evidence": [{"type": "file", "ref": ref}]}


def project_state(inp):
    return read_json(os.path.join(inp["paths"]["projectDir"], "state.json"), {}) or {}


def project_plan(inp):
    return (read_json(os.path.join(inp["paths"]["projectDir"], "plan.json"), {}) or {}).get("plan") or {}


def plan_from_recipe(recipe_id, goal, root=None, steps_patch=None, criteria_patch=None, drop_steps=(), extra_assumptions=()):
    """Plan à partir d'une VRAIE recette (workers/<id>/recipes/*.json) : les critères sont ceux de la recette, mot pour mot (sauf correctif déclaré)."""
    import recipes
    r = recipes.get(recipe_id)
    if not r:
        raise RuntimeError("recette introuvable : " + recipe_id)
    crit = []
    for c in r["definitionOfDone"]:
        c = json.loads(json.dumps(c))
        if criteria_patch and c["id"] in criteria_patch:
            c = criteria_patch[c["id"]](c)
        crit.append(c)
    steps = []
    for s in r["steps"]:
        if s["id"] in drop_steps:
            continue
        s = json.loads(json.dumps(s))
        if steps_patch and s["id"] in steps_patch:
            s.update(steps_patch[s["id"]])
        s.setdefault("expectedOutputs", ["notes/%s.md" % s["id"]])
        s["dependsOn"] = [d for d in s.get("dependsOn") or [] if d not in drop_steps]
        steps.append({k: s[k] for k in ("id", "title", "worker", "goal", "dependsOn", "criteriaIds", "expectedOutputs", "estimateCredits", "effort") if k in s})
    credits = sum(int(s.get("estimateCredits") or 6) for s in steps)
    lo, hi = r["budget"]["typicalCredits"]
    return {"goal": goal[:300], "language": "fr", "recipeId": recipe_id,
            "assumptions": [{"id": "A%d" % (i + 1), "text": t} for i, t in enumerate(extra_assumptions)] or [{"id": "A1", "text": "Hypothèses de la recette, étiquetées dans les rapports."}],
            "criteria": crit, "steps": steps,
            "estimate": {"creditsMin": min(lo, credits), "creditsMax": max(hi, credits), "hoursMin": r["budget"]["typicalHours"][0], "hoursMax": r["budget"]["typicalHours"][1]}}


def csv_rows(text):
    import csv
    import io
    return list(csv.DictReader(io.StringIO(text or "")))


def csv_text(columns, rows):
    import csv
    import io
    buf = io.StringIO()
    w = csv.writer(buf, lineterminator="\n")
    w.writerow(columns)
    for r in rows:
        w.writerow([r.get(c, "") for c in columns])
    return buf.getvalue()


def slug(text):
    t = re.sub(r"[^a-z0-9]+", "-", text.lower().replace("é", "e").replace("è", "e").replace("ô", "o").replace("à", "a").replace("ç", "c"))
    return t.strip("-")
