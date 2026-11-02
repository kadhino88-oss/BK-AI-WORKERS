# -*- coding: utf-8 -*-
"""Génère workers/<id>/recipes/*.json, chloe/recipes/*.json, core/projects/RECIPE-INDEX.json, RECIPE-CATALOG.json et RECIPE-SOURCES.json.

Usage : python core/projects/recipes_src/build.py            (écrit)
        python core/projects/recipes_src/build.py --check    (échoue si les fichiers écrits diffèrent de la source)
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))

import deep, light1, light2, light3  # noqa: E402

FETCHED = "2026-11-02"
SOURCES = {
    "seo-starter": ("Google Search Central : guide de démarrage SEO", "https://developers.google.com/search/docs/fundamentals/seo-starter-guide", True,
                    "Titres et descriptions uniques, texte de lien descriptif, alt des images, plan de site facultatif."),
    "title-link": ("Google Search Central : titres de page", "https://developers.google.com/search/docs/appearance/title-link", True,
                   "Un titre par page, descriptif et concis, sans répétition ni bourrage, dans la langue de la page."),
    "spam-policies": ("Google Search Central : règles anti-spam", "https://developers.google.com/search/docs/essentials/spam-policies", True,
                      "Cloaking, pages satellites, contenu produit en masse, liens achetés, texte caché, bourrage de mots-clés : interdits."),
    "wcag22": ("W3C : WCAG 2.2, référence rapide", "https://www.w3.org/WAI/WCAG22/quickref/", True,
               "Contraste 4,5:1 (3:1 pour grand texte), alternatives textuelles, étiquettes de formulaire, clavier, focus visible. Seuils de la taille des cibles non relus."),
    "gads-rsa": ("Google Ads : annonces responsives du réseau de recherche", "https://support.google.com/google-ads/answer/7684791", True,
                 "Jusqu'à 15 titres de 30 caractères et 4 descriptions de 90 caractères (minimum 3 titres et 2 descriptions)."),
    "gads-editorial": ("Google Ads : règles éditoriales", "https://support.google.com/adspolicy/answer/6021546", True,
                       "Ponctuation, majuscules et répétitions abusives interdites ; l'annonce doit nommer l'entité promue."),
    "meta-feed-specs": ("Meta : spécifications des annonces image du fil", "https://www.facebook.com/business/ads-guide/image/facebook-feed/traffic", True,
                        "Ratio 4:5, 1440 x 1800 px conseillés ; texte principal de 50 à 150 caractères ; titre court (27)."),
    "meta-ad-standards": ("Meta : normes publicitaires", "https://transparency.meta.com/policies/ad-standards/", False,
                          "La page n'a pas pu être lue en entier par le moteur : relire les normes (attributs personnels, allégations trompeuses, avant/après) avant toute campagne."),
    "gdpr-art21": ("RGPD art. 21 : droit d'opposition", "https://gdpr-info.eu/art-21-gdpr/", True,
                   "Al. 2-3 : la personne peut s'opposer à tout moment à la prospection ; ses données ne doivent plus être traitées à cette fin. (Miroir non officiel du texte ; texte officiel : eur-lex.europa.eu.)"),
    "uwg-fedlex": ("LCD / UWG (RS 241), art. 3 al. 1 lit. o : publicité de masse par télécommunication", "https://www.fedlex.admin.ch/eli/cc/1988/223_223_223/fr", False,
                   "Texte officiel NON relu par le moteur (page non lisible le 2026-11-02) : aucune règle n'est affirmée ici ; à confirmer par un juriste."),
    "eprivacy-edpb": ("Directive ePrivacy art. 13 et lignes directrices CEPD 1/2024 sur l'intérêt légitime", "https://www.edpb.europa.eu/our-work-tools/documents/public-consultations/2024/guidelines-12024-processing-personal-data-based_en", False,
                      "Sources secondaires seulement : le consentement préalable est la règle de l'art. 13 ; le régime B2B varie selon les États. Aucun texte primaire relu : à confirmer par un juriste."),
    "nlpd-fedlex": ("Loi fédérale sur la protection des données (nLPD, RS 235.1)", "https://www.fedlex.admin.ch/eli/cc/2022/491/fr", False,
                    "Texte officiel non relu par le moteur : toute obligation citée doit être confirmée sur le texte en vigueur."),
    "co-fedlex": ("Code des obligations (RS 220)", "https://www.fedlex.admin.ch/eli/cc/27/317_321_377/fr", False,
                  "Texte officiel non relu par le moteur : clauses à faire valider par un juriste."),
}

# Tâches du catalogue (services des fiches d'installation) sans recette de bout en bout, avec la raison.
UNCOVERED = {
    ("lucas", "surveillance-maintenance-site"): "Tâche récurrente sur un connecteur de supervision : elle relève d'une mission récurrente, pas d'un projet à livrables finis ; couverte par rayan/runbook-surveillance pour le mode d'emploi.",
    ("alex", "prevision-pipeline"): "Exige un export CRM réel et une base d'historique ; sans ces données la prévision serait inventée. À ajouter quand un jeu de données d'essai existe.",
    ("maya", "landing-page-conversion"): "Couvert par lucas/site-vitrine-pro (profil landing de l'atelier de sites) ; recette dédiée à écrire après l'évaluation de l'atelier.",
    ("seoya", "suivi-requetes-search-console"): "Exige le connecteur Search Console connecté par le client ; tâche récurrente de lecture, pas un projet à livrables finis.",
    ("ines", "analyse-trafic-tracking"): "Exige des données de trafic réelles (Search Console / Meta en lecture) fournies par le client ; couverte à la demande en mode mission.",
    ("dario", "paie-cout-employeur"): "Exige les barèmes de cotisations sociales en vigueur (canton, caisse) que le moteur ne peut pas relire de façon fiable ; sans eux le calcul serait inventé. À ajouter avec un barème fourni par le client.",
}


def main():
    check = "--check" in sys.argv
    recipes = deep.recipes() + light1.recipes() + light2.recipes() + light3.recipes()
    ids = [r["id"] for r in recipes]
    assert len(ids) == len(set(ids)), "identifiants en double"
    out_files = {}
    for r in recipes:
        d = os.path.join("chloe", "recipes") if r["workerId"] == "chloe" else os.path.join("workers", r["workerId"], "recipes")
        out_files[os.path.join(d, r["id"].split("/")[1] + ".json")] = r

    workers = sorted(w for w in os.listdir(os.path.join(ROOT, "workers")) if os.path.isdir(os.path.join(ROOT, "workers", w, "identity")) and w != "atlas")
    catalog, missing = {}, []
    for w in workers:
        prof = json.load(open(os.path.join(ROOT, "workers", w, "install-profile.json"), encoding="utf-8-sig"))
        rows = []
        for s in prof.get("services") or []:
            cov = sorted(r["id"] for r in recipes if s["id"] in r.get("services", []))
            row = {"serviceId": s["id"], "task": s.get("label"), "recipes": cov}
            if not cov:
                reason = UNCOVERED.get((w, s["id"]))
                if not reason:
                    missing.append((w, s["id"]))
                row["reason"] = reason
            rows.append(row)
        catalog[w] = rows
    if missing:
        print("TACHES SANS RECETTE NI RAISON :", missing)
        sys.exit(1)
    per_worker = {w: sorted(r["id"] for r in recipes if r["workerId"] == w) for w in workers}
    short = [w for w, v in per_worker.items() if len(v) < 3]
    if short:
        print("MOINS DE 3 RECETTES :", short)
        sys.exit(1)

    index = {"schema": "BK-RECIPE-INDEX-V1", "count": len(recipes), "recipes": [
        {"id": r["id"], "title": r["title"], "workerId": r["workerId"], "supportingWorkers": r["supportingWorkers"], "minPlan": r["minPlan"],
         "typicalCredits": r["budget"]["typicalCredits"], "typicalHours": r["budget"]["typicalHours"], "services": r.get("services", []),
         "path": ("chloe/recipes/" if r["workerId"] == "chloe" else "workers/%s/recipes/" % r["workerId"]) + r["id"].split("/")[1] + ".json"}
        for r in sorted(recipes, key=lambda x: x["id"])]}
    sources = {"schema": "BK-RECIPE-SOURCES-V1", "fetchedUtc": FETCHED, "note": "Sources lues par le moteur à la date indiquée. verified=false : la page n'a pas pu être lue en entier ; aucune règle n'en est tirée et le point est signalé « à confirmer par un juriste ».",
               "sources": {k: {"title": t, "url": u, "fetchedUtc": FETCHED, "verified": v, "claim": c} for k, (t, u, v, c) in SOURCES.items()}}
    outputs = {os.path.join("core", "projects", "RECIPE-INDEX.json"): index, os.path.join("core", "projects", "RECIPE-CATALOG.json"):
               {"schema": "BK-RECIPE-CATALOG-V1", "note": "Tâches de chaque Worker (services de install-profile.json) et recette qui les mène au bout ; reason = pourquoi une tâche n'a pas (encore) de recette.", "workers": catalog},
               os.path.join("core", "projects", "RECIPE-SOURCES.json"): sources}
    for rel, data in list(out_files.items()) + list(outputs.items()):
        p = os.path.join(ROOT, rel)
        text = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
        if check:
            if not os.path.exists(p) or open(p, encoding="utf-8").read() != text:
                print("DIFFÉRENT :", rel)
                sys.exit(1)
            continue
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
    covered = sum(1 for rows in catalog.values() for x in rows if x["recipes"])
    total = sum(len(rows) for rows in catalog.values())
    print("%d recettes ; %d/%d tâches du catalogue couvertes ; par Worker : %s" % (len(recipes), covered, total, {w: len(v) for w, v in per_worker.items()}))


if __name__ == "__main__":
    main()
