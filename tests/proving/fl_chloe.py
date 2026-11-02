# -*- coding: utf-8 -*-
"""Flagship 5 : UNE demande à Chloé qui exige trois Workers (site, SEO, publicités). Chloé décompose, délègue, chaque Worker relit le fichier de remise du précédent
(hand-off par l'espace de travail), puis Chloé consolide. Sur un forfait Trio (un seul Worker embauché), le plan ne contient que les étapes que le forfait permet et le
rapport dit lesquels manquent. Les fichiers citent mot pour mot une ligne du livrable précédent : le vérificateur le contrôle."""
from common import claim, project_state, read_ws, register, write

BRIEF = ("Je lance mon cabinet de physiothérapie à Lausanne (Cabinet Léman Santé). Crée-moi un site professionnel, optimise-le pour le SEO et prépare mes publicités Meta "
         "pour le lancement, budget 400 CHF. Coordonne le tout.")
WORKER = "chloe"
STEPS = [("S1", "lucas", "Cahier du site et arborescence", "deliverables/site-brief.md", []),
         ("S2", "seoya", "Plan SEO d'après l'arborescence", "deliverables/seo-plan.md", ["S1"]),
         ("S3", "maya", "Plan publicitaire d'après le site et le SEO", "deliverables/ads-plan.md", ["S1", "S2"])]
HEAD = {"S1": "Pages prévues : accueil, soins, équipe, tarifs, contact", "S2": "Mots-clés prioritaires : physiothérapie Lausanne, rééducation sportive Lausanne",
        "S3": "Budget : 400 CHF sur 30 jours, 3 campagnes en pause"}


def allowed_workers(inp):
    sc = project_state(inp).get("scope") or {}
    allowed = sc.get("allowedWorkers")
    return None if allowed is None else list(allowed)


def plan(inp):
    allowed = allowed_workers(inp)
    steps, dropped = [], []
    ids = set()
    for sid, w, title, out, deps in STEPS:
        if allowed is not None and w not in allowed:
            dropped.append(w)
            continue
        ids.add(sid)
        steps.append({"id": sid, "title": title, "worker": w, "goal": title + " (reprendre la ligne de remise de l'étape précédente, mot pour mot).", "dependsOn": [d for d in deps if d in ids and d != sid],
                      "criteriaIds": [{"S1": "C1", "S2": "C2", "S3": "C3"}[sid], "C4"], "expectedOutputs": [out], "estimateCredits": 8})
    crit = []
    for cid, path, must, label in (("C1", "deliverables/site-brief.md", "Pages", "Le cahier du site existe"), ("C2", "deliverables/seo-plan.md", "Mots-cl", "Le plan SEO existe"),
                                   ("C3", "deliverables/ads-plan.md", "Budget", "Le plan publicitaire existe")):
        if any(s["criteriaIds"][0] == cid for s in steps):
            crit.append({"id": cid, "text": label, "kind": "auto", "check": {"type": "file_contains", "path": path, "mustContain": [must]}})
    crit.append({"id": "C4", "text": "Chaque étape reprend la remise de l'étape précédente", "kind": "rubric", "rubric": "La ligne de remise citée existe, mot pour mot, dans le fichier du Worker précédent."})
    assumptions = [{"id": "A1", "text": "Projet piloté par Chloé : une étape = un Worker, relais par fichiers de remise."}]
    if dropped:
        assumptions.append({"id": "A2", "text": "Workers non disponibles dans ce forfait : %s. Embauchez-les pour leur confier ces parties." % ", ".join(dropped)})
    return {"goal": BRIEF[:300], "language": "fr", "assumptions": assumptions, "criteria": crit, "steps": steps,
            "estimate": {"creditsMin": 8 * len(steps), "creditsMax": 12 * len(steps) + 10, "hoursMin": 0.3, "hoursMax": 1}}


def execute(inp, sid, attempt, fix):
    spec = next((s for s in STEPS if s[0] == sid), None)
    if not spec:
        return None
    _sid, w, title, out, deps = spec
    prior = []
    for d in deps:
        prev = next((s for s in STEPS if s[0] == d), None)
        text = read_ws(inp, prev[3]) if prev else None
        if text:
            prior.append("Repris de %s : %s" % (d, HEAD[d]))
    body = "# %s\n\n%s\n\n" % (title, HEAD[sid]) + ("\n".join(prior) + "\n" if prior else "")
    return {"actions": [write(out, body), register(out, title)],
            "complete": {"status": "DONE", "summary": "%s : fait par %s." % (title, w), "deliverables": [{"path": out, "title": title}],
                         "criteriaClaims": [claim({"S1": "C1", "S2": "C2", "S3": "C3"}[sid], out)], "summaryUpdate": "%s terminé." % sid, "handoffNote": "Ligne de remise : %s" % HEAD[sid]}}


def verify(inp, scope):
    bad = []
    for sid, _w, _t, out, deps in STEPS:
        text = read_ws(inp, out)
        if text is None:
            continue
        for d in deps:
            prev = next(s for s in STEPS if s[0] == d)
            if read_ws(inp, prev[3]) is None:
                continue
            if "Repris de %s : %s" % (d, HEAD[d]) not in text or HEAD[d] not in (read_ws(inp, prev[3]) or ""):
                bad.append("%s ne reprend pas la remise de %s" % (sid, d))
    return {"C4": ("PASS" if not bad else "FAIL", "Chaque étape cite la remise de la précédente, retrouvée mot pour mot." if not bad else "; ".join(bad), "")}
