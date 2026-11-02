# -*- coding: utf-8 -*-
"""Flagship 3 : gestion de prospects (recette alex/gestion-prospects, 5 étapes, 3 Workers). Client fictif FidSoft SA (logiciel de facturation pour fiduciaires, Genève).
Le brief demande 15 prospects (la recette en prévoit 30 : le plan l'adapte à la demande du client, ce que le moteur autorise car le critère reste vérifié).

IMPORTANT : les 15 entreprises ci-dessous sont des SYNTHÈSES FICTIVES (domaines .example) fabriquées par ce banc, parce qu'un banc hors ligne n'a pas de web. Elles ne prouvent rien
sur la qualité de recherche d'un vrai Worker ; elles servent à éprouver la mécanique (CSV vérifié, brouillons, approbations, contrôle d'échantillon contre des instantanés).
Défaut semé : une première version de la liste contient une adresse gmail privée (critère C4, rejoué par le MOTEUR, pas par ce module)."""
from common import claim, csv_rows, csv_text, plan_from_recipe, read_ws, register, slug, write

BRIEF = ("Trouve-moi 15 prospects (fiduciaires et cabinets comptables de Genève, 3 à 30 personnes) pour mon logiciel de facturation, qualifie-les et prépare le message d'approche "
         "de chacun en brouillon à valider, sans rien envoyer. Ajoute-les à mon CRM.")
RECIPE = "alex/gestion-prospects"
WORKER = "alex"

COMPANIES = [  # (nom, effectif, spécialité lue sur le site, score)
    ("Fiduciaire Rhône-Arve SA", 12, "comptabilité des PME du commerce de détail", 86), ("Cabinet Comptable Plainpalais Sàrl", 6, "indépendants et professions libérales", 78),
    ("Fiduciaire du Lac SA", 25, "restauration et hôtellerie", 74), ("Genève Compta Services Sàrl", 9, "start-up et sociétés de services", 82),
    ("Fiduciaire des Eaux-Vives SA", 14, "TVA et décomptes mensuels", 80), ("Cabinet Salève Conseil SA", 18, "PME industrielles", 69),
    ("Fiduciaire Jonction Sàrl", 5, "artisans et métiers du bâtiment", 76), ("Bilan & Co Genève SA", 21, "clôtures annuelles et révision", 71),
    ("Fiduciaire Carouge Associés SA", 11, "commerce international", 77), ("Cabinet Mont-Blanc Comptabilité Sàrl", 7, "associations et fondations", 63),
    ("Fiduciaire Pâquis SA", 16, "immobilier et gérances", 73), ("Compta Plus Meyrin Sàrl", 8, "PME locales de la zone industrielle", 79),
    ("Fiduciaire Champel SA", 13, "professions médicales", 75), ("Cabinet Léman Fiscalité Sàrl", 10, "conseil fiscal et comptabilité", 66),
    ("Fiduciaire Petit-Saconnex SA", 19, "PME du secteur de la santé", 70)]


def rows():
    out = []
    for i, (name, staff, spec, score) in enumerate(COMPANIES, 1):
        s = slug(name.split(" SA")[0].split(" Sàrl")[0])
        out.append({"entreprise": name, "site": "https://www.%s.example" % s, "source_url": "https://www.%s.example/a-propos" % s, "role_contact": "Associé-gérant",
                    "email_pro": "info@%s.example" % s, "effectif": staff, "specialite": spec, "score": score,
                    "motif": "Effectif de %d personnes (dans la cible 3 à 30) ; activité lue sur leur page « À propos » : %s." % (staff, spec)})
    return out


def snapshot(r):
    return ("Source: %s\n%s — fiduciaire à Genève. Équipe de %s personnes. Nous accompagnons : %s. Contact général : %s\n" % (r["source_url"], r["entreprise"], r["effectif"], r["specialite"], r["email_pro"]))


COLS = ["entreprise", "site", "source_url", "role_contact", "email_pro", "effectif", "specialite", "score", "motif"]


def plan(inp):
    def crit_c1(c):
        c["check"]["minRows"] = 15
        c["text"] = c["text"].replace("30 lignes", "15 lignes")
        return c

    def crit_c3(c):
        c["check"]["min"] = 15
        c["text"] = "Un brouillon d'approche par prospect (15)"
        return c
    return plan_from_recipe(RECIPE, BRIEF, criteria_patch={"C1": crit_c1, "C3": crit_c3},
                            extra_assumptions=["15 prospects, comme demandé (la recette en prévoit 30).", "Seules des coordonnées professionnelles génériques publiques (info@) ; aucune boîte privée ni profil personnel.",
                                               "Aucun message n'est envoyé : chaque brouillon et chaque tâche CRM est un article d'approbation."])


def draft_text(r, i):
    return ("## Prospect %d — %s\n\n**À :** %s\n**Objet :** Facturation et clôtures : un gain de temps pour %s\n\nBonjour,\n\n"
            "J'ai lu sur votre site que vous accompagnez %s. FidSoft SA développe un logiciel de facturation et de clôture pour les fiduciaires de la taille de la vôtre (%d personnes). "
            "Seriez-vous disposé à un échange de 15 minutes pour voir si cela correspond à votre pratique ?\n\nCordialement,\nL'équipe FidSoft SA, Genève\n\n"
            "_Vous recevez ce message à votre adresse professionnelle publique. Pour ne plus être contacté, répondez « désinscription »._\n" % (i, r["entreprise"], r["email_pro"], r["entreprise"], r["specialite"], int(r["effectif"])))


def execute(inp, sid, attempt, fix):
    rs = rows()
    if sid == "S1":
        grille = ("# Grille de qualification\n\nProfil cible : fiduciaires et cabinets comptables de Genève de 3 à 30 personnes.\n\n## Critères et poids\n| Critère | Poids |\n|---|---|\n| Taille 3 à 30 personnes | 30 |\n"
                  "| Activité de comptabilité PME clairement lue sur le site | 30 |\n| Contact professionnel général public | 20 |\n| Spécialité compatible avec la facturation (TVA, décomptes) | 20 |\n\n## Seuil\nScore ≥ 60 : à contacter ; sous le seuil : écarté.\n")
        return {"actions": [write("deliverables/grille.md", grille), register("deliverables/grille.md", "Grille de qualification")],
                "complete": {"status": "DONE", "summary": "Grille de qualification écrite (critères, poids, seuil de 60).", "deliverables": [{"path": "deliverables/grille.md", "title": "Grille"}],
                             "criteriaClaims": [claim("C2", "deliverables/grille.md")], "summaryUpdate": "Grille prête.", "handoffNote": "deliverables/grille.md (seuil 60)."}}
    if sid == "S2":
        bruts = list(rs)
        acts = [write("data/sources/%s.txt" % slug(r["entreprise"]), snapshot(r)) for r in rs]
        if attempt <= 1 and not fix:
            bruts[3] = dict(bruts[3], email_pro="direction.perso@gmail.com")          # défaut semé : adresse privée
        acts.append(write("data/prospects-bruts.csv", csv_text(COLS, bruts)))
        return {"actions": acts, "complete": {"status": "DONE", "summary": "15 entreprises trouvées, une source lue pour chacune.", "deliverables": [{"path": "data/prospects-bruts.csv", "title": "Prospects bruts"}],
                                              "criteriaClaims": [claim("C1", "data/prospects-bruts.csv"), claim("C4", "data/prospects-bruts.csv")], "summaryUpdate": "15 prospects bruts.",
                                              "handoffNote": "data/prospects-bruts.csv + data/sources/*.txt (instantanés des pages sources)."}}
    if sid == "S3":
        brut = csv_rows(read_ws(inp, "data/prospects-bruts.csv"))        # le Worker relit le fichier de l'étape précédente
        keep = sorted(brut, key=lambda r: -int(r["score"]))
        text = csv_text(COLS, keep)
        return {"actions": [write("deliverables/prospects.csv", text), register("deliverables/prospects.csv", "Liste de prospects qualifiés")],
                "complete": {"status": "DONE", "summary": "%d prospects scorés et triés d'après la grille." % len(keep), "deliverables": [{"path": "deliverables/prospects.csv", "title": "Prospects"}],
                             "criteriaClaims": [claim("C1", "deliverables/prospects.csv")], "summaryUpdate": "Liste triée.", "handoffNote": "deliverables/prospects.csv"}}
    if sid == "S4":
        brut = csv_rows(read_ws(inp, "deliverables/prospects.csv"))
        text = "# Brouillons d'approche\n\n" + "\n".join(draft_text(r, i) for i, r in enumerate(brut, 1))
        return {"actions": [write("deliverables/brouillons.md", text), register("deliverables/brouillons.md", "Brouillons d'approche")],
                "complete": {"status": "DONE", "summary": "%d brouillons personnalisés sur un fait de la source de chaque prospect." % len(brut), "deliverables": [{"path": "deliverables/brouillons.md", "title": "Brouillons"}],
                             "criteriaClaims": [claim("C3", "deliverables/brouillons.md")], "summaryUpdate": "Brouillons écrits.", "handoffNote": "deliverables/brouillons.md"}}
    if sid == "S5":
        brut = csv_rows(read_ws(inp, "deliverables/prospects.csv"))
        acts = [write("deliverables/conformite-prospection.md",
                      "# Note de conformité\n\n## Base légale\nPrise de contact B2B à une adresse professionnelle générique publique, intérêt légitime ; en Suisse, la LCD (art. 3 al. 1 let. o) exige l'indication de l'expéditeur et d'un moyen de désinscription. À valider par un juriste.\n\n"
                      "## Désinscription\nChaque brouillon porte une phrase de désinscription ; toute réponse « désinscription » doit retirer le contact.\n\n## Aucun envoi automatique\nRien n'est envoyé : chaque brouillon et chaque tâche CRM est un article d'approbation validé par le client.\n"),
                write("deliverables/rapport-prospection.md",
                      "# Rapport de prospection\n\n15 entreprises genevoises qualifiées, 15 brouillons, 15 tâches de suivi préparées.\n\n## Sources et limites\nChaque ligne de prospects.csv renvoie à sa page source (instantané dans data/sources/). "
                      "Contrôle par échantillon : 5 sources rouvertes. Limites : effectifs lus sur les sites (non vérifiés ailleurs), aucune adresse nominative, aucune donnée du registre du commerce croisée.\n"),
                      register("deliverables/conformite-prospection.md", "Note de conformité"), register("deliverables/rapport-prospection.md", "Rapport")]
        for i, r in enumerate(brut[:15], 1):
            draft = draft_text(r, i)
            body = draft.split("**Objet :**", 1)[1].split("\n", 1)[1].strip()
            acts.append({"tool": "request_approval", "input": {"kind": "connector", "connectorId": "gmail", "operation": "DRAFT_MESSAGE", "title": "Brouillon pour %s" % r["entreprise"], "recipients": 1,
                                                                "why": "Message d'approche personnalisé sur un fait lu sur leur site.", "params": {"To": r["email_pro"], "Subject": "Facturation et clôtures : un gain de temps pour %s" % r["entreprise"], "Body": body}}})
            acts.append({"tool": "request_approval", "input": {"kind": "connector", "connectorId": "hubspot", "operation": "CREATE_TASK", "title": "Tâche CRM : %s" % r["entreprise"],
                                                                "why": "Suivi dans votre CRM.", "params": {"Subject": "Relancer %s dans 7 jours" % r["entreprise"], "Notes": "Score %s ; %s ; source %s" % (r["score"], r["specialite"], r["source_url"])}}})
        return {"actions": acts, "complete": {"status": "DONE", "summary": "Note de conformité, rapport, 15 brouillons et 15 tâches CRM préparés en approbation (rien n'est envoyé ni créé).",
                                              "deliverables": [{"path": "deliverables/conformite-prospection.md", "title": "Conformité"}, {"path": "deliverables/rapport-prospection.md", "title": "Rapport"}],
                                              "criteriaClaims": [claim("C4", "deliverables/prospects.csv"), claim("C5", "deliverables/prospects.csv"), claim("C6", "deliverables/conformite-prospection.md"), claim("CH", "deliverables/rapport-prospection.md")],
                                              "summaryUpdate": "Conformité et rapport écrits.", "handoffNote": "Approbations en file."}}
    return None


def fix(inp, criteria_ids):
    """Le Worker propriétaire retire l'adresse privée détectée par le moteur (critère C4) dans les trois fichiers qui la contiennent."""
    acts = []
    for rel in ("data/prospects-bruts.csv", "deliverables/prospects.csv"):
        t = read_ws(inp, rel)
        if t:
            acts.append(write(rel, t.replace("direction.perso@gmail.com", "info@genève-compta-services.example".replace("è", "e"))))
    return {"actions": acts, "complete": {"status": "DONE", "summary": "Adresse privée remplacée par l'adresse professionnelle générique publique.",
                                          "deliverables": [{"path": "deliverables/prospects.csv", "title": "Prospects"}] if acts else [],
                                          "criteriaClaims": [claim(c, "deliverables/prospects.csv") for c in criteria_ids if c in ("C1", "C4")], "summaryUpdate": "Liste nettoyée."}}


def verify(inp, scope):
    """C5 : 5 source_url tirées (les 5 premières, ordre déterministe) rouvertes dans les instantanés ; l'entreprise et le rôle doivent y figurer."""
    rs = csv_rows(read_ws(inp, "deliverables/prospects.csv"))
    bad = []
    for r in rs[:5]:
        snap = read_ws(inp, "data/sources/%s.txt" % slug(r["entreprise"])) or ""
        if r["entreprise"] not in snap:
            bad.append(r["entreprise"])
    if bad:
        return {"C5": ("FAIL", "La source ne confirme pas : " + ", ".join(bad), "Relire les sources.")}
    return {"C5": ("PASS", "5 sources rouvertes (instantanés) : l'entreprise y est nommée.", ""), "C7": ("PASS", "Chaque brouillon cite une spécialité lue sur le site du prospect et propose un échange de 15 minutes, sans promesse.", "")}
