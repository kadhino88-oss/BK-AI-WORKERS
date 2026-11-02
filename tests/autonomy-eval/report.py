# -*- coding: utf-8 -*-
"""Rapport markdown d'une exécution du banc (results.json -> tableau). Honnête : bannière dry-run, effectifs faibles, coûts simulés signalés."""

ARM_LABEL = {"baseline": "A. Boucle actuelle (mission)", "project": "B. Moteur de projet", "reference": "C. Référence simple"}


def _pct(n, d):
    return "n/a" if not d else "%d %%" % round(100 * n / d)


def _avg(vals):
    vals = [v for v in vals if v is not None]
    return None if not vals else sum(vals) / len(vals)


def _fmt(v, fmt="%.2f"):
    return "n/a" if v is None else fmt % v


def summarize(doc):
    out = {}
    for arm in doc["arms"]:
        runs = [r for r in doc["runs"] if r["arm"] == arm]
        ran = [r for r in runs if r["status"] not in ("SKIPPED", "REFUSED", "ERROR", "CAPPED")]
        judged = [r for r in ran if r.get("judged")]
        done = [r for r in judged if r.get("completed")]
        crit_met = []
        for r in ran:
            if r.get("criteriaMet"):
                a, b = r["criteriaMet"].split("/")
                crit_met.append(int(a) / int(b) if int(b) else 0)
        out[arm] = {"planned": len(runs), "ran": len(ran), "judged": len(judged), "completed": len(done), "skipped": len(runs) - len(ran), "criteria": _avg(crit_met),
                    "score": _avg([r.get("score") for r in ran]), "chf": sum(r.get("chf") or 0 for r in ran), "usd": sum(r.get("usd") or 0 for r in ran),
                    "minutes": _avg([(r.get("seconds") or 0) / 60 for r in ran]), "steps": _avg([r.get("steps") for r in ran]),
                    "fabrications": sum(len(r.get("fabrications") or []) for r in ran)}
    return out


def render(doc):
    L = ["# Évaluation de l'autonomie des Workers", "", "Exécution `%s` (%s), fournisseur `%s`, juge `%s`, %s scénario(s), %s s." % (
        doc["runId"], doc["createdUtc"], doc["provider"], doc["judge"], len(doc["scenarios"]), doc.get("elapsedSec"))]
    if doc.get("dryRun"):
        L += ["", "> **DRY-RUN : ces chiffres ne mesurent PAS la qualité d'un moteur.** Fausse API, faux lanceur, juge simulé, coûts simulés. Ils prouvent seulement que le banc "
              "(exécution, notation, rapport) fonctionne. Aucune décision produit ne doit s'appuyer sur ce tableau."]
    L += ["", "Effectifs faibles (1 exécution par case) : résultats **indicatifs, pas statistiques**.", ""]
    sm = summarize(doc)
    L += ["## Synthèse par bras", "", "| Bras | Exécutés / prévus | Terminés (jugés) | Critères auto atteints | Note moyenne | Fabrications | Coût CHF | Minutes (moy.) | Étapes (moy.) |",
          "|---|---|---|---|---|---|---|---|---|"]
    for arm in doc["arms"]:
        s = sm[arm]
        L.append("| %s | %d / %d | %s | %s | %s | %d | %s%s | %s | %s |" % (
            ARM_LABEL.get(arm, arm), s["ran"], s["planned"], "%d / %d (%s)" % (s["completed"], s["judged"], _pct(s["completed"], s["judged"])),
            _fmt(None if s["criteria"] is None else s["criteria"] * 100, "%.0f %%"), _fmt(s["score"]), s["fabrications"], _fmt(s["chf"], "%.3f"),
            " (simulé)" if doc.get("dryRun") or any(r.get("simulatedCost") for r in doc["runs"] if r["arm"] == arm) else "", _fmt(s["minutes"], "%.1f"), _fmt(s["steps"], "%.1f")))
    L += ["", "« Terminé » = tous les critères obligatoires passent, zéro fabrication, livrables présents, partie automatique ≥ seuil, et le juge ≥ 50 %. "
              "Sans juge, la complétion n'est pas comptée (colonne « jugés »).", ""]
    L += ["## Scénario par bras", "", "| Scénario | Worker | " + " | ".join(ARM_LABEL.get(a, a) for a in doc["arms"]) + " |", "|---|---|" + "---|" * len(doc["arms"])]
    for sid in doc["scenarios"]:
        cells = []
        worker = ""
        for arm in doc["arms"]:
            r = next((x for x in doc["runs"] if x["scenarioId"] == sid and x["arm"] == arm), None)
            if r is None:
                cells.append("-")
                continue
            worker = r.get("worker", worker)
            if r["status"] in ("SKIPPED", "REFUSED", "ERROR", "CAPPED"):
                cells.append("%s" % r["status"].lower())
            else:
                mark = "terminé" if r.get("completed") else "non terminé"
                cells.append("%s, note %s, critères %s%s" % (mark, _fmt(r.get("score")), r.get("criteriaMet", "n/a"), ", **fabrication**" if r.get("fabrications") else ""))
        L.append("| %s | %s | %s |" % (sid, worker, " | ".join(cells)))
    L += ["", "## Détail des critères manqués", ""]
    any_missed = False
    for r in doc["runs"]:
        missed = [c for c in r.get("criteria") or [] if c["kind"] == "auto" and not c.get("ok")]
        if missed:
            any_missed = True
            L.append("- **%s / %s** : %s" % (r["scenarioId"], r["arm"], " ; ".join("%s (%s)" % (c["id"], str(c.get("detail"))[:80]) for c in missed[:6])))
    if not any_missed:
        L.append("(aucun critère automatique manqué)")
    skipped = [r for r in doc["runs"] if r["status"] in ("SKIPPED", "REFUSED", "ERROR", "CAPPED")]
    if skipped:
        L += ["", "## Non exécutés", ""]
        seen = set()
        for r in skipped:
            key = (r["arm"], r.get("error"))
            if key not in seen:
                seen.add(key)
                L.append("- %s : %s (%s)" % (ARM_LABEL.get(r["arm"], r["arm"]), r.get("error"), r["status"]))
    sp = doc.get("spend") or {}
    L += ["", "## Dépense", "", "Plafond %.2f USD, dépensé %.4f USD (réel). Les coûts « simulés » ci-dessus viennent de jetons factices ou d'un faux lanceur et ne sont pas de l'argent." % (sp.get("capUsd", 0), sp.get("spentUsd", 0)), ""]
    return "\n".join(L) + "\n"
