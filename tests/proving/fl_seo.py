# -*- coding: utf-8 -*-
"""Flagship 2 : audit SEO (recette seoya/audit-seo-complet, 5 étapes, 3 Workers). Site audité : le site FICTIF « Atelier Papier » dont les pages sont des instantanés déposés par
ce banc (le vrai Worker les lirait avec web_fetch) ; robots.txt y bloque tout (piège). Les lignes d'audit sont DÉRIVÉES de ces pages par analyse (pas écrites à la main), et le
vérificateur rejoue la preuve de chaque ligne contre le fichier lu. Défaut semé : une première version des briefs affirme un volume de recherche inventé."""
import re

from common import claim, csv_rows, csv_text, plan_from_recipe, read_ws, register, write

BRIEF = ("Fais l'audit SEO complet de mon site atelier-papier.example (papeterie à Lausanne) : constats page par page avec preuve, priorités impact/effort, 5 briefs de contenu "
         "et plan de correction. Je n'ai pas accès à Search Console.")
RECIPE = "seoya/audit-seo-complet"
WORKER = "seoya"
BASE = "https://atelier-papier.example"

PAGES = {
    "index.html": ("/", """<!doctype html><html lang="fr"><head><meta charset="utf-8"><title>Accueil</title></head><body><header><h1>Atelier Papier Lausanne</h1></header>
<main><p>Papeterie de création au centre de Lausanne : carnets cousus main, papiers japonais et stylos.</p><img src="a.jpg"><a href="/produits.html">Nos produits</a></main></body></html>"""),
    "produits.html": ("/produits.html", """<!doctype html><html lang="fr"><head><meta charset="utf-8"><title>Accueil</title><meta name="description" content="Nos produits">
<link rel="canonical" href="https://atelier-papier.example/produits.html"></head><body><h1>Produits</h1><h1>Papeterie</h1><p>Carnets, papiers, stylos.</p></body></html>"""),
    "carnets.html": ("/carnets.html", """<!doctype html><html lang="fr"><head><meta charset="utf-8"><title>Carnets cousus main à Lausanne | Atelier Papier</title>
<meta name="description" content="Carnets cousus main à Lausanne : papier recyclé ou japonais, couvertures en toile ou en cuir. Découvrez la collection de l'Atelier Papier.">
<link rel="canonical" href="https://atelier-papier.example/carnets.html"></head><body><h1>Carnets cousus main</h1><p>Chaque carnet est cousu à la main dans notre atelier lausannois.</p>
<img src="carnet.jpg" alt="Carnet cousu main à couverture en toile"></body></html>"""),
    "blog-reliure.html": ("/blog-reliure.html", """<!doctype html><html lang="fr"><head><meta charset="utf-8"><title>Comment relier un carnet à la main : guide complet pour débuter la reliure japonaise chez soi</title>
<meta name="description" content="Apprenez à relier un carnet à la main."></head><body><h1>Relier un carnet à la main</h1><p>La reliure japonaise est accessible aux débutants.</p></body></html>"""),
    "contact.html": ("/contact.html", """<!doctype html><html lang="fr"><head><meta charset="utf-8"><title>Contact | Atelier Papier</title></head><body><p>Écrivez-nous.</p></body></html>"""),
}
ROBOTS = "User-agent: *\nDisallow: /\n"


def plan(inp):
    return plan_from_recipe(RECIPE, BRIEF, steps_patch={}, extra_assumptions=["Aucune donnée Search Console : volumes de recherche et positions NON mesurés (étiquetés ainsi).",
                                                                               "Les pages sont lues par instantané ; l'audit ne couvre que ce qui a été lu."])


def parse(html):
    g = lambda pat: (re.search(pat, html, re.I | re.S).group(1).strip() if re.search(pat, html, re.I | re.S) else "")  # noqa: E731
    return {"title": g(r"<title>(.*?)</title>"), "h1": re.findall(r"<h1[^>]*>(.*?)</h1>", html, re.I | re.S), "desc": g(r'<meta name="description" content="(.*?)"'),
            "canonical": g(r'<link rel="canonical" href="(.*?)"'), "noalt": len(re.findall(r"<img(?![^>]*\balt=)", html, re.I))}


def audit_rows(inp):
    rows = []
    for fn, (path, _html) in PAGES.items():
        html = read_ws(inp, "data/pages/" + fn) or ""
        p = parse(html)
        issues, proofs = [], []
        if p["title"].lower() == "accueil" and fn != "index.html":
            issues.append("Titre dupliqué avec l'accueil")
            proofs.append("<title>%s</title>" % p["title"])
        if p["title"].lower() == "accueil" and fn == "index.html":
            issues.append("Titre générique « Accueil » (aucun mot-clé ni nom de ville)")
            proofs.append("<title>Accueil</title>")
        if len(p["title"]) > 60:
            issues.append("Titre trop long (%d caractères, coupé dans les résultats)" % len(p["title"]))
            proofs.append("<title>%s" % p["title"][:30])
        if not p["desc"]:
            issues.append("Méta description absente")
            proofs.append("balise meta description absente de " + fn)
        elif len(p["desc"]) < 70:
            issues.append("Méta description trop courte (%d caractères)" % len(p["desc"]))
            proofs.append('content="%s"' % p["desc"])
        if len(p["h1"]) == 0:
            issues.append("Aucun h1")
            proofs.append("aucune balise <h1> dans " + fn)
        elif len(p["h1"]) > 1:
            issues.append("%d balises h1" % len(p["h1"]))
            proofs.append("<h1>%s</h1>" % p["h1"][1])
        if not p["canonical"]:
            issues.append("Balise canonical absente")
            proofs.append("balise canonical absente de " + fn)
        if p["noalt"]:
            issues.append("%d image(s) sans texte alternatif" % p["noalt"])
            proofs.append("<img src=\"a.jpg\">")
        rows.append({"url": BASE + path, "statut": "200", "titre": p["title"], "h1": p["h1"][0] if p["h1"] else "", "meta_description": p["desc"], "canonical": p["canonical"],
                     "constat": " ; ".join(issues) or "Aucun problème relevé sur les balises lues", "preuve": "data/pages/%s : %s" % (fn, " | ".join(proofs) or "balises conformes")})
    rows.append({"url": BASE + "/robots.txt", "statut": "200", "titre": "", "h1": "", "meta_description": "", "canonical": "",
                 "constat": "robots.txt interdit l'exploration de TOUT le site (Disallow: /)", "preuve": "data/robots.txt : Disallow: /"})
    return rows


AUDIT_COLS = ["url", "statut", "titre", "h1", "meta_description", "canonical", "constat", "preuve"]


def briefs(with_invented_volume):
    topics = [("carnets cousus main Lausanne", "transactionnelle", "page catégorie « Carnets »"), ("papier japonais washi achat", "transactionnelle", "page catégorie « Papiers »"),
              ("relier un carnet japonaise tutoriel", "informationnelle", "article de blog"), ("papeterie créative Lausanne", "locale", "accueil"),
              ("offrir un carnet personnalisé", "commerciale", "page guide cadeau")]
    out = ["# Briefs de contenu\n"]
    for i, (q, intent, kind) in enumerate(topics, 1):
        out.append("## Brief %d — %s\n" % (i, q))
        out.append("- Requête principale : %s\n- Intention : %s\n- Type de page : %s\n- Plan : introduction (promesse), 3 à 4 sections H2 répondant aux questions fréquentes, appel à l'action.\n"
                   "- Mots et expressions à couvrir : %s\n- Maillage : liens vers les pages produits liées et vers l'accueil.\n" % (q, intent, kind, ", ".join(q.split() + ["atelier", "fait main"])))
        if with_invented_volume and i == 1:
            out.append("- Volume de recherche : 1 900 recherches/mois (très concurrentiel)\n")
        else:
            out.append("- Volume de recherche : non mesuré (aucun outil de mots-clés connecté ; à confirmer avec Search Console)\n")
    return "\n".join(out)


def execute(inp, sid, attempt, fix):
    if sid == "S1":
        acts = [write("data/pages/" + fn, html) for fn, (_p, html) in PAGES.items()] + [write("data/robots.txt", ROBOTS)]
        acts.append(write("data/urls.txt", "\n".join(BASE + p for _f, (p, _h) in PAGES.items()) + "\n" + BASE + "/robots.txt\n"))
        return {"actions": acts, "complete": {"status": "DONE", "summary": "5 pages et robots.txt lus (instantanés) ; liste d'URL établie.", "deliverables": [{"path": "data/urls.txt", "title": "URL explorées"}],
                                              "criteriaClaims": [claim("C1", "data/urls.txt")], "summaryUpdate": "Pages lues.", "handoffNote": "data/pages/*.html, data/robots.txt"}}
    if sid == "S2":
        rows = audit_rows(inp)
        return {"actions": [write("deliverables/audit.csv", csv_text(AUDIT_COLS, rows)), register("deliverables/audit.csv", "Audit page par page")],
                "complete": {"status": "DONE", "summary": "%d lignes d'audit, chacune avec la preuve lue." % len(rows), "deliverables": [{"path": "deliverables/audit.csv", "title": "Audit page par page"}],
                             "criteriaClaims": [claim("C1", "deliverables/audit.csv"), claim("C5", "deliverables/audit.csv")], "summaryUpdate": "audit.csv écrit.", "handoffNote": "deliverables/audit.csv"}}
    if sid == "S3":
        md = ("# Audit SEO — synthèse\n\n## Priorité absolue\nLe fichier robots.txt contient `Disallow: /` : **aucun moteur ne peut explorer le site**. Tant que ce n'est pas corrigé, aucune autre optimisation ne produit d'effet.\n\n"
              "## Problèmes classés par impact et effort\n| Problème | Impact | Effort |\n|---|---|---|\n| robots.txt bloque tout le site | Très élevé | Faible (une ligne) |\n"
              "| Titres « Accueil » en double ou génériques | Élevé | Faible |\n| Méta descriptions absentes ou trop courtes | Moyen | Faible |\n| Deux h1 / aucun h1 | Moyen | Faible |\n"
              "| Titre de l'article de blog trop long | Faible | Faible |\n| Images sans texte alternatif | Moyen | Faible |\n\n## Non mesuré\nNon mesuré : volumes de recherche, positions, trafic, vitesse réelle, liens entrants (aucune donnée Search Console ni outil de mots-clés).\n")
        return {"actions": [write("deliverables/audit.md", md), register("deliverables/audit.md", "Synthèse de l'audit")],
                "complete": {"status": "DONE", "summary": "Synthèse classée par impact et effort ; le blocage robots.txt est la priorité 1.", "deliverables": [{"path": "deliverables/audit.md", "title": "Synthèse"}],
                             "criteriaClaims": [claim("C2", "deliverables/audit.md"), claim("C5", "deliverables/audit.csv")], "summaryUpdate": "Synthèse écrite.", "handoffNote": "deliverables/audit.md"}}
    if sid == "S4":
        return {"actions": [write("deliverables/briefs.md", briefs(with_invented_volume=True)), register("deliverables/briefs.md", "Briefs de contenu")],
                "complete": {"status": "DONE", "summary": "5 briefs de contenu rédigés.", "deliverables": [{"path": "deliverables/briefs.md", "title": "Briefs"}],
                             "criteriaClaims": [claim("C3", "deliverables/briefs.md")], "summaryUpdate": "Briefs écrits.", "handoffNote": "deliverables/briefs.md"}}
    if sid == "S5":
        plan_md = ("# Plan de correctifs\n\n| Correctif | Page | Balise exacte à coller | Propriétaire |\n|---|---|---|---|\n"
                   "| Autoriser l'exploration | /robots.txt | `User-agent: *` puis `Allow: /` | Hébergeur ou webmaster |\n"
                   "| Titre de l'accueil | / | `<title>Papeterie créative à Lausanne | Atelier Papier</title>` | Client |\n"
                   "| Titre de la page produits | /produits.html | `<title>Carnets, papiers et stylos | Atelier Papier Lausanne</title>` | Client |\n"
                   "| Méta description de l'accueil | / | `<meta name=\"description\" content=\"Papeterie de création à Lausanne : carnets cousus main, papiers japonais et stylos. Venez nous rencontrer à l'atelier.\">` | Client |\n"
                   "| Un seul h1 | /produits.html | supprimer `<h1>Papeterie</h1>` ou le passer en `<h2>` | Webmaster |\n| Texte alternatif | / | `<img src=\"a.jpg\" alt=\"Vitrine de l'Atelier Papier\">` | Client |\n")
        report = ("# Rapport SEO — Atelier Papier\n\nCinq pages et le fichier robots.txt ont été lus. Le point décisif est le robots.txt qui interdit tout le site ; le reste est classé dans audit.md.\n\n"
                  "## Sources et limites\nTout constat renvoie à une ligne de audit.csv et à l'instantané lu dans data/pages/. Non mesuré : volumes de recherche, positions, trafic, vitesse, liens entrants ; "
                  "aucun outil de mots-clés ni Search Console n'est connecté. Seules 5 pages ont été explorées. Le plan de correctifs n'a pas été appliqué au site.\n")
        return {"actions": [write("deliverables/plan-correctifs.md", plan_md), write("deliverables/rapport-seo.md", report), register("deliverables/plan-correctifs.md", "Plan de correctifs"),
                            register("deliverables/rapport-seo.md", "Rapport SEO"),
                            {"tool": "request_approval", "input": {"kind": "connector", "connectorId": "wordpress", "operation": "CREATE_DRAFT", "title": "Brouillon : article « relier un carnet à la main »",
                                                                    "what": "Crée un brouillon WordPress à partir du brief 3 ; rien n'est publié.", "why": "Le brief 3 vise une requête informationnelle sans page dédiée.",
                                                                    "params": {"Title": "Relier un carnet à la main : le guide", "Content": "<p>[À RÉDIGER d'après le brief 3 de briefs.md]</p>", "Status": "draft"}}},
                            {"tool": "request_approval", "input": {"kind": "manual", "title": "Corriger le robots.txt chez l'hébergeur", "what": "Remplacer `Disallow: /` par `Allow: /` dans le fichier robots.txt à la racine du site.",
                                                                    "why": "Sans cela le site n'est pas exploré par les moteurs de recherche.", "risk": "medium"}}],
                "complete": {"status": "DONE", "summary": "Plan de correctifs et rapport écrits ; deux actions préparées en approbation (rien n'est appliqué).",
                             "deliverables": [{"path": "deliverables/plan-correctifs.md", "title": "Plan de correctifs"}, {"path": "deliverables/rapport-seo.md", "title": "Rapport SEO"}],
                             "criteriaClaims": [claim("C4", "deliverables/plan-correctifs.md"), claim("CH", "deliverables/rapport-seo.md")], "summaryUpdate": "Plan et rapport écrits.", "handoffNote": "deliverables/"}}
    return None


def fix(inp, criteria_ids):
    acts = []
    if "C5" in criteria_ids or "C3" in criteria_ids:
        acts += [write("deliverables/briefs.md", briefs(with_invented_volume=False)), register("deliverables/briefs.md", "Briefs de contenu")]
    return {"actions": acts, "complete": {"status": "DONE", "summary": "Volume de recherche inventé retiré des briefs : « non mesuré » à la place.", "deliverables": [{"path": "deliverables/briefs.md", "title": "Briefs"}],
                                          "criteriaClaims": [claim(c, "deliverables/briefs.md") for c in criteria_ids if c in ("C3", "C5")], "summaryUpdate": "Briefs corrigés."}}


def verify(inp, scope):
    # C5 : (a) chaque ligne d'audit cite une preuve présente dans l'instantané lu ; (b) aucun volume de recherche chiffré dans les briefs.
    problems = []
    for r in csv_rows(read_ws(inp, "deliverables/audit.csv")):
        m = re.match(r"(data/[\w./-]+) : (.*)", r["preuve"])
        if not m or read_ws(inp, m.group(1)) is None:
            problems.append("preuve introuvable pour " + r["url"])
            continue
        src = read_ws(inp, m.group(1))
        for frag in m.group(2).split(" | "):
            if frag.startswith("<") or frag.startswith("Disallow") or frag.startswith("content="):
                needle = frag.rstrip("…")
                if needle.replace('content="', "").rstrip('"') not in src and needle not in src:
                    problems.append("preuve non retrouvée dans %s : %s" % (m.group(1), frag[:50]))
    briefs_t = read_ws(inp, "deliverables/briefs.md") or ""
    if re.search(r"Volume de recherche\s*:\s*[\d\s]+\s*(recherches|requêtes)", briefs_t):
        problems.append("briefs.md : volume de recherche chiffré alors qu'aucune donnée de recherche n'est disponible")
    if problems:
        return {"C5": ("FAIL", "; ".join(problems)[:550], "Remplacer tout volume chiffré par « non mesuré » dans briefs.md.")}
    return {"C5": ("PASS", "Chaque constat renvoie à un extrait lu ; aucun volume inventé.", "")}
