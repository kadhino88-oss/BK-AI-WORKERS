# -*- coding: utf-8 -*-
"""Faux lanceur d'étape du BANC DE PREUVE : même contrat que tests/projects/fake_runner.py (qui reste intact), outils de l'atelier de sites enregistrés, et le comportement
d'un « bon modèle » écrit pour chaque flagship (tests/proving/fl_*.py). Aucun modèle, aucun réseau.

    python proving_runner.py <input.json> <result.json>

Réglages de test (fichier <BK_ROOT>/_prove/knobs.json) : {"slow": {"<stepId>": secondes}}  -> la première tentative de l'étape dort (pour tuer le serveur en plein travail)."""
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(REPO, "tests", "projects"))
sys.path.insert(0, os.path.join(REPO, "dashboard"))
import site_tools  # noqa: E402,F401  (registre des outils site_*)
import fake_runner  # noqa: E402
from common import project_plan, project_state, read_json  # noqa: E402
import fl_ads  # noqa: E402
import fl_chloe  # noqa: E402
import fl_prospects  # noqa: E402
import fl_seo  # noqa: E402
import fl_site  # noqa: E402

CHF = {"plan": 0.12, "execute": 0.30, "fix": 0.20, "verify": 0.16, "consolidate": 0.10, "answer": 0.04}


def detect(goal):
    g = (goal or "").lower()
    if g.startswith("test-"):
        return None
    if "physiothérapie à lausanne (cabinet léman santé). crée-moi un site professionnel" in g:
        return fl_chloe
    if "site vitrine de mon cabinet de physioth" in g:
        return fl_site
    if "audit seo" in g:
        return fl_seo
    if "prospects" in g and "fiduciaires" in g:
        return fl_prospects
    if "campagne meta" in g:
        return fl_ads
    return None


def knobs(inp):
    return read_json(os.path.join(os.environ.get("BK_ROOT", REPO), "_prove", "knobs.json"), {}) or {}


def behavior(inp):
    st = project_state(inp)
    fl = detect(st.get("goal"))
    kind, sid = inp["kind"], inp["stepId"]
    goal = st.get("goal") or ""
    if fl is None:
        beh = fake_runner.default_behavior_orig(inp)
        if goal.upper().startswith("TEST-QUESTION") and kind in ("execute", "fix") and sid == "S1" and inp["attempt"] <= 1:
            beh = {"actions": [{"tool": "request_input", "input": {"question": "Quelle est la raison sociale exacte à imprimer sur la facture (avec la forme juridique) ?", "blocking": True,
                                                                  "why": "Elle figure sur le document et je ne peux pas la deviner."}}],
                   "complete": {"status": "NEEDS_INPUT", "summary": "Tout ce qui ne dépend pas de la réponse est fait ; la raison sociale manque.",
                                "inputQuestions": [{"question": "Quelle est la raison sociale exacte à imprimer sur la facture (avec la forme juridique) ?", "blocking": True}]}}
        beh.setdefault("chf", float(knobs(inp).get("chf") or os.environ.get("PROVE_CHF", "0.30")))
        return beh
    beh = None
    if kind in ("plan", "replan"):
        beh = {"actions": [{"tool": "project_plan", "input": {"action": "set", "plan": fl.plan(inp)}}], "complete": {"status": "DONE", "summary": "Plan prêt, critères repris de la recette."}}
    elif kind == "execute":
        beh = fl.execute(inp, sid, inp["attempt"], False)
    elif kind == "fix":
        stp = st.get("steps", {}).get(sid) or {}
        crit = stp.get("criteriaIds") or (stp.get("spec") or {}).get("criteriaIds") or []
        beh = fl.fix(inp, crit)
    elif kind == "verify":
        plan = project_plan(inp)
        scope = inp.get("scope") or "final"
        verdicts = fl.verify(inp, scope) if hasattr(fl, "verify") else {}
        crit = []
        for c in plan.get("criteria") or []:
            if (scope == "consistency") != (c["id"] == "C-coherence"):
                continue
            v = verdicts.get(c["id"])
            if v:
                item = {"id": c["id"], "verdict": v[0], "note": v[1], "evidence": [{"type": "file", "ref": next(iter(_files(inp)), "notes/x.md")}]}
                if len(v) > 2 and v[2]:
                    item["fixHint"] = v[2]
            else:
                item = {"id": c["id"], "verdict": "PASS", "note": "Contrôlé par le moteur (critère automatique) ou relu : conforme.", "evidence": [{"type": "file", "ref": next(iter(_files(inp)), "notes/x.md")}]}
            crit.append(item)
        overall = "PASS" if all(c["verdict"] == "PASS" for c in crit) else "FAIL"
        beh = {"complete": {"status": "DONE", "summary": "Vérification terminée.", "verification": {"criteria": crit, "consistency": [], "overall": overall, "summary": "Voir les critères."}}}
    if beh is None:
        beh = fake_runner.default_behavior_orig(inp)
    beh = dict(beh)
    beh.setdefault("chf", CHF.get(kind, 0.2))
    slow = (knobs(inp).get("slow") or {}).get(sid)
    if slow and inp["attempt"] <= 1 and kind == "execute":
        beh["sleep"] = float(slow)
    return beh


def _files(inp):
    ws = inp["paths"]["workspace"]
    for dp, _d, fs in os.walk(ws):
        for n in sorted(fs):
            if n.endswith((".md", ".csv", ".html")):
                yield os.path.relpath(os.path.join(dp, n), ws).replace(os.sep, "/")


def main():
    fake_runner.default_behavior_orig = fake_runner.default_behavior
    fake_runner.default_behavior = behavior
    fake_runner.main()


if __name__ == "__main__":
    main()
