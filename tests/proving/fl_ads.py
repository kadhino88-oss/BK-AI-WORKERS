# -*- coding: utf-8 -*-
"""Flagship 4 : campagne Meta Ads complète (recette maya/publicites-meta-google adaptée à Meta seul, 5 étapes, 3 Workers). Client fictif Thés des Alpes (boutique en ligne,
Lausanne), budget 600 CHF sur 30 jours. Le lancement NE PEUT PAS être un appel de connecteur : le connecteur meta_ads n'a que des opérations de LECTURE (READ_CAMPAIGN, READ_REPORT) ;
le lancement est donc un article d'approbation « manuel » guidé (constat de ce banc). Défaut semé : un titre de 45 caractères (limite Meta : 40, recommandé 27) que le vérificateur
recompte et fait corriger."""
from common import claim, csv_rows, csv_text, plan_from_recipe, read_ws, register, write

BRIEF = ("Prépare une campagne Meta (Facebook et Instagram) pour ma boutique de thé en ligne Thés des Alpes (thés bio de Suisse romande), budget 600 CHF sur 30 jours : stratégie, "
         "audiences, textes, spécifications de visuels, structure de campagne et un fichier prêt à importer. N'active et ne dépense rien.")
RECIPE = "maya/publicites-meta-google"
WORKER = "maya"
LIMITS = {"titre": 40, "texte principal": 125, "description": 30}
ANGLES = ["Terroir alpin", "Rituel du soir", "Offrir un coffret"]
COPY = {  # (angle) -> {emplacement: [3 variantes]}
    "Terroir alpin": {"titre": ["Thés bio des Alpes suisses", "Du thé cultivé près de chez vous", "Le terroir romand en tasse"],
                      "texte principal": ["Des thés bio sélectionnés en Suisse romande, expédiés depuis Lausanne. Découvrez nos mélanges de saison.",
                                          "Du thé vert aux infusions de verveine : une sélection bio pensée pour vos pauses. Livraison en Suisse.",
                                          "Nos thés et infusions viennent de producteurs de Suisse romande. Découvrez les origines de chaque mélange."],
                      "description": ["Livraison en Suisse", "Sélection bio de saison", "Découvrir la boutique"]},
    "Rituel du soir": {"titre": ["Une infusion pour finir la journée", "Votre pause du soir en douceur", "Verveine bio, tasse chaude"],
                       "texte principal": ["Prenez un moment pour vous : notre infusion à la verveine accompagne vos soirées. Commandez en ligne, livré chez vous.",
                                           "Après la journée, une tasse qui ralentit le rythme. Découvrez nos infusions bio de Suisse romande.",
                                           "Un rituel simple : de l'eau chaude, une infusion bio, cinq minutes pour souffler. À découvrir en ligne."],
                       "description": ["Infusions bio", "Commande en ligne", "Voir nos infusions"]},
    "Offrir un coffret": {"titre": ["Le coffret découverte à offrir", "Un cadeau qui a bon goût", "Offrez un voyage en thé"],
                          "texte principal": ["Le coffret découverte réunit nos thés bio de Suisse romande. Une idée de cadeau simple, prête à offrir.",
                                              "Vous cherchez un cadeau gourmand ? Notre coffret découverte permet de goûter plusieurs mélanges bio.",
                                              "Anniversaire, remerciement ou simple attention : le coffret découverte se commande en ligne et part de Lausanne."],
                          "description": ["Coffret découverte", "Idée cadeau", "Commander en ligne"]}}


def copy_rows(defect):
    rows = []
    for a in ANGLES:
        for emp, variants in COPY[a].items():
            for i, v in enumerate(variants, 1):
                if defect and a == "Rituel du soir" and emp == "titre" and i == 1:
                    v = "Une infusion bio de verveine pour finir votre journée"             # 52 caractères > 40
                rows.append({"plateforme": "Meta", "emplacement": emp, "angle": a, "variante": i, "texte": v, "longueur": len(v)})
    return rows


COPY_COLS = ["plateforme", "emplacement", "angle", "variante", "texte", "longueur"]
CAMP_COLS = ["campagne", "groupe", "annonce", "ciblage", "budget_jour", "statut"]


def camp_rows():
    return [{"campagne": "TDA-Découverte", "groupe": "Froid-intérêts", "annonce": "Terroir alpin v1-3", "ciblage": "Suisse romande, 25-55 ans, intérêts : thé, bien-être, produits bio", "budget_jour": "10", "statut": "En pause"},
            {"campagne": "TDA-Remarketing", "groupe": "Visiteurs-30j", "annonce": "Rituel du soir v1-3", "ciblage": "Visiteurs du site des 30 derniers jours (pixel avec consentement)", "budget_jour": "5", "statut": "En pause"},
            {"campagne": "TDA-Cadeau", "groupe": "Cadeau-large", "annonce": "Offrir un coffret v1-3", "ciblage": "Suisse romande, 28-60 ans, intérêts : cadeaux, gastronomie", "budget_jour": "5", "statut": "En pause"}]


def plan(inp):
    def c2(c):
        c["check"]["minRows"] = 9
        c["text"] = "copies.csv : 3 angles x 3 variantes x 3 emplacements Meta, avec longueur calculée"
        return c
    return plan_from_recipe(RECIPE, BRIEF, criteria_patch={"C2": c2},
                            extra_assumptions=["Meta (Facebook et Instagram) seulement, comme demandé ; Google non traité.", "600 CHF sur 30 jours = 20 CHF par jour, répartis sur trois campagnes.",
                                               "Aucun résultat passé n'est connu : aucune promesse de performance. Le pixel de suivi exige le consentement des visiteurs.",
                                               "Le connecteur Meta Ads ne sait que LIRE : le lancement est une action manuelle guidée, validée par le client."])


def execute(inp, sid, attempt, fix):
    if sid == "S1":
        md = ("# Stratégie Meta — Thés des Alpes\n\n## Audience\nHabitants de Suisse romande de 25 à 55 ans sensibles aux produits bio et au bien-être ; un second public d'acheteurs de cadeaux ; les visiteurs récents du site (remarketing).\n\n"
              "## Offre\nThés et infusions bio de Suisse romande, coffret découverte.\n\n## Entonnoir\nDécouverte (froid) → visite du site → remarketing du soir → achat ; cadeau en parallèle.\n\n"
              "## Budget\n600 CHF sur 30 jours, soit 20 CHF par jour : Découverte 10, Remarketing 5, Cadeau 5. Aucune dépense n'est lancée tant que vous n'avez pas validé.\n\n"
              "## KPI\nCoût par visite qualifiée, taux d'ajout au panier, coût par achat. Aucun objectif chiffré promis : aucun résultat passé n'est connu.\n")
        return {"actions": [write("deliverables/strategie.md", md), register("deliverables/strategie.md", "Stratégie")],
                "complete": {"status": "DONE", "summary": "Stratégie : audiences, offre, entonnoir, budget 20 CHF/jour, KPI.", "deliverables": [{"path": "deliverables/strategie.md", "title": "Stratégie"}],
                             "criteriaClaims": [claim("C1", "deliverables/strategie.md")], "summaryUpdate": "Stratégie écrite.", "handoffNote": "Budget 10/5/5 CHF par jour, 3 angles."}}
    if sid == "S2":
        text = csv_text(COPY_COLS, copy_rows(defect=attempt <= 1 and not fix))
        return {"actions": [write("deliverables/copies.csv", text), register("deliverables/copies.csv", "Textes publicitaires")],
                "complete": {"status": "DONE", "summary": "3 angles x 3 variantes x 3 emplacements, longueurs calculées.", "deliverables": [{"path": "deliverables/copies.csv", "title": "Textes"}],
                             "criteriaClaims": [claim("C2", "deliverables/copies.csv"), claim("C3", "deliverables/copies.csv"), claim("C4", "deliverables/copies.csv")], "summaryUpdate": "27 textes.", "handoffNote": "deliverables/copies.csv"}}
    if sid == "S3":
        md = ("# Spécifications des visuels\n\n| Emplacement | Format | Ratio | Poids | Texte dans l'image |\n|---|---|---|---|---|\n| Fil Facebook / Instagram | JPG ou PNG, 1080 x 1350 px | Ratio 4:5 | moins de 1 Mo | moins de 20 % de la surface, jamais de promesse |\n"
              "| Stories et Reels | 1080 x 1920 px | Ratio 9:16 | moins de 1 Mo | zone centrale libre (bords réservés à l'interface) |\n\nChaque visuel montre un vrai produit de la boutique ; aucune image d'avis ou de note.\n")
        return {"actions": [write("deliverables/visuels-specs.md", md), register("deliverables/visuels-specs.md", "Visuels")],
                "complete": {"status": "DONE", "summary": "Formats et ratios par emplacement.", "deliverables": [{"path": "deliverables/visuels-specs.md", "title": "Visuels"}],
                             "criteriaClaims": [claim("C5", "deliverables/visuels-specs.md")], "summaryUpdate": "Visuels spécifiés.", "handoffNote": "Formats 4:5 et 9:16."}}
    if sid == "S4":
        return {"actions": [write("deliverables/campagnes.csv", csv_text(CAMP_COLS, camp_rows())), register("deliverables/campagnes.csv", "Structure de campagne")],
                "complete": {"status": "DONE", "summary": "Structure en 3 campagnes, toutes en pause.", "deliverables": [{"path": "deliverables/campagnes.csv", "title": "Structure"}],
                             "criteriaClaims": [claim("C6", "deliverables/campagnes.csv")], "summaryUpdate": "Structure prête.", "handoffNote": "deliverables/campagnes.csv"}}
    if sid == "S5":
        suivi = ("# Plan de suivi\n\n## UTM\n`utm_source=meta&utm_medium=paid&utm_campaign=<campagne>&utm_content=<angle>-v<n>` sur chaque lien.\n\n## Événements de conversion\nVoir le contenu (ViewContent), ajout au panier (AddToCart), achat (Purchase) ; pixel installé seulement avec le consentement des visiteurs.\n\n"
                 "## Plan de test\nUn angle testé par ensemble de publicités, 7 jours de données avant toute décision.\n\n## Règles d'arrêt\nSuspendre une annonce dont le coût par visite est le double de la médiane des autres après 7 jours ; ne jamais augmenter le budget sans votre accord.\n")
        report = ("# Rapport — campagne Meta Thés des Alpes\n\nLe dossier est complet : stratégie, 27 textes, spécifications, structure en 3 campagnes (toutes en pause) et plan de suivi. Rien n'est lancé ni dépensé.\n\n"
                  "## Sources et limites\nAucune donnée de performance passée n'existe : les répartitions de budget sont des hypothèses à ajuster. Les limites de caractères sont celles publiées par Meta pour le fil (titre 40, texte 125, description 30) "
                  "et peuvent évoluer. Les images ne sont pas créées ici. Le lancement se fait dans le Gestionnaire de publicités après votre validation.\n")
        return {"actions": [write("deliverables/suivi.md", suivi), write("deliverables/rapport-publicites.md", report), register("deliverables/suivi.md", "Suivi"), register("deliverables/rapport-publicites.md", "Rapport"),
                            {"tool": "request_approval", "input": {"kind": "manual", "title": "Lancer la campagne Meta (600 CHF sur 30 jours)", "risk": "high", "reversible": True,
                                                                    "what": "Dans le Gestionnaire de publicités Meta : importer deliverables/campagnes.csv, ajouter les visuels et les textes de copies.csv, vérifier le budget de 20 CHF par jour, puis passer les campagnes de « En pause » à « Actif ». Cela dépense 600 CHF au plus.",
                                                                    "why": "Toute dépense publicitaire exige votre validation explicite ; le connecteur Meta Ads de la plateforme ne sait que lire, le lancement se fait donc chez vous."}},
                            {"tool": "request_approval", "input": {"kind": "manual", "title": "Installer le pixel Meta avec bandeau de consentement", "risk": "medium",
                                                                    "what": "Installer le pixel Meta sur la boutique et afficher un bandeau de consentement avant tout suivi (exigé pour le remarketing).", "why": "Sans pixel, le remarketing et la mesure des achats sont impossibles."}}],
                "complete": {"status": "DONE", "summary": "Suivi et rapport écrits ; lancement et pixel préparés en approbation (rien n'est dépensé).", "deliverables": [{"path": "deliverables/suivi.md", "title": "Suivi"}, {"path": "deliverables/rapport-publicites.md", "title": "Rapport"}],
                             "criteriaClaims": [claim("C7", "deliverables/suivi.md"), claim("CH", "deliverables/rapport-publicites.md")], "summaryUpdate": "Dossier complet.", "handoffNote": "Approbations en file."}}
    return None


def fix(inp, criteria_ids):
    text = csv_text(COPY_COLS, copy_rows(defect=False))
    return {"actions": [write("deliverables/copies.csv", text), register("deliverables/copies.csv", "Textes publicitaires")],
            "complete": {"status": "DONE", "summary": "Titre trop long remplacé par une variante de 32 caractères.", "deliverables": [{"path": "deliverables/copies.csv", "title": "Textes"}],
                         "criteriaClaims": [claim(c, "deliverables/copies.csv") for c in criteria_ids if c in ("C2", "C3", "C4")], "summaryUpdate": "Textes corrigés."}}


def verify(inp, scope):
    bad = []
    for r in csv_rows(read_ws(inp, "deliverables/copies.csv")):
        limit = LIMITS.get(r["emplacement"])
        n = len(r["texte"])
        if str(n) != str(r["longueur"]):
            bad.append("longueur déclarée fausse (%s au lieu de %d)" % (r["longueur"], n))
        if limit and n > limit:
            bad.append("%s « %s… » : %d caractères > limite %d" % (r["emplacement"], r["texte"][:30], n, limit))
    if bad:
        return {"C3": ("FAIL", "; ".join(bad)[:550], "Raccourcir chaque texte au-dessous de la limite de son emplacement et recalculer la colonne longueur.")}
    return {"C3": ("PASS", "Tous les textes recomptés sont sous la limite de leur emplacement (titre 40, texte 125, description 30).", "")}
