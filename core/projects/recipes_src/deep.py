# -*- coding: utf-8 -*-
"""Recettes PROFONDES (familles phares du contrat, docs/AUTONOMY-ENGINE.md 9.3)."""
from lib import *  # noqa: F401,F403

LEGAL_PROSPECT = ("Prospection par message : le moteur ne fournit pas un avis juridique. En Suisse, l'envoi de publicité de masse par moyen de télécommunication "
                  "(e-mail, SMS) est encadré par l'art. 3 al. 1 lit. o de la loi contre la concurrence déloyale (LCD / UWG) ; le texte officiel sur fedlex.admin.ch n'a "
                  "PAS pu être relu par le moteur le 2026-11-02 : a faire confirmer par un juriste avant tout envoi. Dans l'UE, la directive ePrivacy (art. 13) et les lois "
                  "nationales fixent le consentement préalable, avec des régimes B2B différents selon les pays ; le RGPD art. 21 al. 2-3 donne un droit d'opposition "
                  "immédiat à la prospection. Le Worker prépare des BROUILLONS ; le client decide et envoie, et reste responsable de la base légale.")


def recipes():
    out = []

    # ------------------------------------------------------------------ Lucas : site vitrine
    out.append(build(
        "site-vitrine-pro", "lucas", "Site vitrine professionnel (FR/EN)",
        "Un site de 5 pages (accueil, prestations, à propos, tarifs, contact) en français et en anglais, contrôle, avec aperçu, zip et guide de mise en ligne.",
        ["brouillons-wordpress-webflow", "accessibilite-web", "core-web-vitals-performance"],
        ["site web", "site vitrine", "créer mon site", "landing page", "site professionnel", "site internet", "refonte de site"],
        ["Crée le site vitrine de mon cabinet, en français et en anglais", "Je veux un site web professionnel pour mon entreprise de menuiserie"],
        [A("C1", "Toutes les pages prévues existent en FR et EN, sans lien casse", {"type": "site_check", "profile": "vitrine", "must": ["links", "i18n", "html"]}),
         A("C2", "Meta, Open Graph, sitemap, robots et canonical présents", {"type": "site_check", "must": ["meta", "seo"]}),
         A("C3", "Accessibilité de base et poids de page respectés", {"type": "site_check", "must": ["a11y", "perf", "img"]}),
         A("C4", "Aucun traceur ni ressource externe non déclarée", {"type": "site_check", "must": ["privacy"]}),
         A("C5", "Aucun fait, chiffre, avis ou certification inventé ; les données manquantes sont des [À COMPLÉTER] listés", {"type": "site_check", "must": ["content"]}),
         Rb("C6", "Ton, orthographe et cohérence de marque entre pages et langues", "Ton adapté au secteur ; vouvoiement ; typographie francaise ; mêmes noms, prix et coordonnées partout ; EN naturel et non litteral."),
         A("C7", "Guide de mise en ligne livre", fe("deliverables/MISE-EN-LIGNE.md", 800))],
        [S("S1", "Cadrage, arborescence, ton", "lucas", "Lire le profil et les fichiers du client ; fixer les 5 pages, les langues, le ton, la liste des faits connus et des [À COMPLÉTER] ; écrire site/site.json et site/ARBORESCENCE.md.", crit=["C1"], est=6, out=["site/site.json", "site/ARBORESCENCE.md"]),
         S("S2", "Charte et styles", "lea", "Définir couleurs (contraste AA), typographie système, logo SVG typographique et la feuille de style unique.", ["S1"], ["C3"], 10, ["site/src/assets/style.css", "site/src/assets/img/logo.svg"]),
         S("S3", "Textes FR", "emma", "Rédiger les textes français des 5 pages à partir des seuls faits du client ; tout fait absent reste [À COMPLÉTER: ...].", ["S1"], ["C5", "C6"], 12, ["site/src/pages/fr/"]),
         S("S4", "Pages HTML FR et construction", "lucas", "Assembler les pages avec site_scaffold puis site_build ; ne jamais écrire dans site/dist/.", ["S2", "S3"], ["C1", "C2", "C3"], 18, ["site/dist/index.html"]),
         S("S5", "Version EN et parité", "emma", "Traduire naturellement chaque page (pas littéralement) ; mêmes prix, mêmes coordonnées ; hreflang par la construction.", ["S4"], ["C1", "C6"], 8, ["site/src/pages/en/"], "bulk"),
         S("S6", "SEO de base et balisage", "seoya", "Titres uniques de 30 à 60 caractères, descriptions de 70 à 160, balisage JSON-LD limite aux valeurs de site.json.", ["S5"], ["C2"], 8, [], "normal"),
         S("S7", "Contrôles, corrections, paquet et guide de mise en ligne", "lucas", "Lancer site_check, corriger jusqu'à zéro erreur, produire site_package et MISE-EN-LIGNE.md (guide manuel, enregistrements DNS réels seulement si le domaine est donne).", ["S6"], ["C4", "C5", "C7"], 10, ["deliverables/MISE-EN-LIGNE.md"])],
        [D("deliverables/site-site.zip", "Site complet (zip)", "site"), D("deliverables/MISE-EN-LIGNE.md", "Guide de mise en ligne")],
        "deliverables/rapport-site.md",
        "Un site de 5 pages. Construire par site_scaffold puis site_build ; ne jamais écrire dans site/dist/. Aucun script tiers, aucune police externe, aucun formulaire sans traitement défini. Publication : toujours un guide manuel ; la route WordPress ne crée que des BROUILLONS de pages. Les contenus manquants restent [À COMPLÉTER].",
        support=["lea", "emma", "seoya"], min_plan="equipe", languages=["fr", "en"],
        needs=[Q("Q1", "Raison sociale, adresse, téléphone, horaires, prestations et tarifs exacts ?", "champs [À COMPLÉTER]"), Q("Q2", "Logo et photos existants ?", "logo SVG typographique, pas de photos")],
        approvals=[AP("wordpress", "CREATE_DRAFT", "low", "le client demande la mise en ligne sur son WordPress (brouillons de pages)")],
        optional=["wordpress"], forbidden=["avis ou témoignages inventés", "chiffres de clientèle", "police ou script externe", "formulaire sans traitement défini"],
        sources=["wcag22", "seo-starter", "title-link", "spam-policies"], credits=[70, 140], hours=[1.5, 4],
        variants={"essentiel": {"drop": ["S6"], "creditsRange": [55, 110], "label": "Sans passe SEO dédiée, une seule langue"}},
        scenarios=["S1-physio-lausanne", "S2-menuisier"]))

    # ------------------------------------------------------------------ Alex : gestion de prospects
    out.append(build(
        "gestion-prospects", "alex", "Gestion de prospects : 30 prospects qualifiés et brouillons d'approche",
        "Une liste de 30 prospects réels, chacun avec sa source publique, une grille de qualification, un brouillon d'approche par prospect et une note de conformité. Rien n'est envoyé.",
        ["prospection-sortante", "suivi-crm-opportunites"],
        ["prospects", "prospection", "liste de prospects", "trouver des clients", "leads", "approche commerciale", "gestion des prospects"],
        ["Trouve-moi 30 prospects pour mon logiciel comptable a Genève et prépare les messages", "Gere mes prospects : liste qualifiée et premiers e-mails en brouillon"],
        [A("C1", "prospects.csv : au moins 30 lignes, colonnes entreprise, site, source_url, role_contact, score, motif, chaque ligne avec une source_url", csvc("deliverables/prospects.csv", ["entreprise", "site", "source_url", "role_contact", "score", "motif"], 30, "entreprise", ["entreprise", "source_url", "score", "motif"])),
         A("C2", "Grille de qualification écrite (critères, poids, seuils)", fc("deliverables/grille.md", ["Criteres", "Seuil"])),
         A("C3", "Un brouillon d'approche par prospect", cm("deliverables/brouillons.md", "^## Prospect", 30)),
         A("C4", "Aucune boîte privée ni profil personnel dans la liste (coordonnées professionnelles publiques uniquement)", fc("deliverables/prospects.csv", mustnot=["re:linkedin\\.com/in/", "re:@(gmail|hotmail|outlook|yahoo|bluewin|icloud)\\."])),
         Rb("C5", "Contrôle par échantillon : 5 source_url tirées au hasard sont ouvertes et confirment l'entreprise et le rôle", "Ouvrir 5 source_url au hasard (preview_fetch/web_fetch). FAIL si une page est morte ou ne mentionne pas l'entreprise ; UNVERIFIABLE si la lecture web est indisponible."),
         A("C6", "Note de conformité : base légale documentée, désinscription, aucun envoi automatique", fc("deliverables/conformite-prospection.md", ["Base légale", "Desinscription", "juriste"])),
         Rb("C7", "Brouillons personnalisés et honnêtes", "Chaque brouillon cite un fait vérifiable de la source du prospect, propose une valeur concrète, est court, sans fausse urgence ni fausse relation ('suite a notre echange' interdit), avec identité de l'expéditeur et moyen de ne plus être contacte.")],
        [S("S1", "Cadrage : cible, offre, grille", "alex", "Fixer le profil de client idéal (secteur, taille, région, rôle), la proposition de valeur, les critères de qualification et le seuil ; écrire grille.md.", crit=["C2"], est=8, out=["deliverables/grille.md"]),
         S("S2", "Recherche des prospects", "amina", "Chercher sur le web public des entreprises correspondant au profil ; pour chacune : site, page source qui prouve l'existence et le rôle du contact. Entreprises seulement, coordonnées professionnelles publiques. Éliminer sites morts et doublons.", ["S1"], ["C1", "C4"], 24, ["data/prospects-bruts.csv"], "bulk"),
         S("S3", "Qualification et score", "alex", "Appliquer la grille à chaque prospect ; écrire score et motif factuel ; produire prospects.csv trié.", ["S2"], ["C1"], 14, ["deliverables/prospects.csv"]),
         S("S4", "Brouillons d'approche", "emma", "Rédiger un brouillon par prospect, personnalisé sur un fait de sa source ; ton sobre ; identité de l'expéditeur ; lien ou phrase de désinscription.", ["S3"], ["C3", "C7"], 22, ["deliverables/brouillons.md"], "bulk"),
         S("S5", "Contrôle par échantillon, conformité, CRM et rapport", "alex", "Vérifier 5 sources au hasard ; écrire conformite-prospection.md ; préparer les articles d'approbation : brouillons Gmail/Outlook (DRAFT_MESSAGE) et tâches CRM (CREATE_TASK) ; jamais d'envoi.", ["S4"], ["C4", "C5", "C6"], 16, ["deliverables/conformite-prospection.md", "deliverables/rapport-prospection.md"])],
        [D("deliverables/prospects.csv", "Liste de prospects", "table"), D("deliverables/grille.md", "Grille de qualification"), D("deliverables/brouillons.md", "Brouillons d'approche"), D("deliverables/conformite-prospection.md", "Note de conformité")],
        "deliverables/rapport-prospection.md",
        "Chaque ligne du CSV porte sa source_url ouverte et lue par un Worker ; si la recherche web est indisponible, ne rien inventer : bloquer l'étape et demander une liste au client. Uniquement des entreprises et des coordonnées professionnelles publiques ; jamais d'adresse privée ni de profil personnel. Les brouillons sont déposés, jamais envoyes ; chaque envoi reste une decision du client.",
        support=["amina", "emma"], min_plan="solo",
        needs=[Q("Q1", "Votre offre en une phrase, votre cible (secteur, taille, région) et vos 3 meilleurs clients actuels (sans noms si confidentiel) ?", "cible déduite du profil, hypothèses listées", True), Q("Q2", "Ton souhaité et signature (nom, fonction) ?", "ton sobre, signature [À COMPLÉTER]")],
        approvals=[AP("gmail", "DRAFT_MESSAGE", "low", "un brouillon par prospect, déposé dans Gmail"), AP("outlook_mail", "DRAFT_MESSAGE", "low", "idem pour Outlook"), AP("hubspot", "CREATE_TASK", "low", "une tâche de relance par prospect")],
        optional=["gmail", "outlook_mail", "hubspot", "pipedrive"], sources=["gdpr-art21", "uwg-fedlex", "eprivacy-edpb"], legal=LEGAL_PROSPECT,
        forbidden=["adresse e-mail privée ou profil personnel", "coordonnée devinée ou reconstituée", "fausse relation ou fausse urgence dans un brouillon", "envoi automatique"],
        credits=[60, 120], hours=[1, 3], scenarios=["S3-prospects-comptables"]))

    # ------------------------------------------------------------------ Maya : publicites
    out.append(build(
        "publicites-meta-google", "maya", "Publicités Meta et Google : stratégie et jeu complet prêt à importer",
        "Stratégie, 3 angles x 3 variantes de textes dans les limites de caractères, spécifications de visuels, structure de campagne en CSV et plan de suivi. Aucune dépense lancee.",
        ["campagne-payante-plan-media", "go-to-market-lancement"],
        ["publicite", "publicites", "campagne meta", "facebook ads", "google ads", "annonces", "campagne payante", "créer des pubs"],
        ["Crée des publicités Meta pour ma boutique de the", "Prépare ma campagne Google Ads et Facebook, textes et structure"],
        [A("C1", "strategie.md : audience, offre, entonnoir, répartition du budget, KPI", fc("deliverables/strategie.md", ["Audience", "Entonnoir", "Budget", "KPI"])),
         A("C2", "copies.csv : 3 angles x 3 variantes pour chaque plateforme (au moins 18 lignes) avec longueur calculee", csvc("deliverables/copies.csv", ["plateforme", "emplacement", "angle", "variante", "texte", "longueur"], 18, None, ["texte", "longueur"])),
         Rb("C3", "Limites de caractères respectées pour chaque emplacement et chaque plateforme", "Google RSA : titres <= 30, descriptions <= 90 caractères. Meta fil : titre ~27, texte principal 50 à 150 recommandes. Recompter 6 lignes au hasard ; FAIL si une depasse."),
         A("C4", "Aucune promesse chiffrée de résultat ni superlatif non prouvé", fc("deliverables/copies.csv", mustnot=["re:garanti", "re:resultats? assures", "re:\\d+ ?% (de )?(ventes|clients|conversions|croissance)", "re:le meilleur|n[°o] ?1", "re:(augmentez|boostez|multipliez|doublez)[^;\\n]{0,40}\\d+ ?%"])),
         A("C5", "visuels-specs.md : formats, ratios, texte dans l'image, par emplacement", fc("deliverables/visuels-specs.md", ["Format", "Ratio"])),
         A("C6", "campagnes.csv : structure prête à importer (campagne, ensemble/groupe, annonce, ciblage, budget, statut en pause)", csvc("deliverables/campagnes.csv", ["campagne", "groupe", "annonce", "ciblage", "budget_jour", "statut"], 3, None, ["statut"])),
         A("C7", "suivi.md : UTM, événements de conversion, plan de test et règles d'arret", fc("deliverables/suivi.md", ["UTM", "Evenement", "Test"]))],
        [S("S1", "Cadrage et stratégie", "maya", "Lire le profil et les offres ; fixer audience, offre, entonnoir, budget (montant fourni par le client, sinon hypothèse étiquetée), KPI ; écrire strategie.md.", crit=["C1"], est=14, out=["deliverables/strategie.md"], effort="deep"),
         S("S2", "Textes des annonces", "emma", "Écrire 3 angles x 3 variantes par plateforme ; compter les caractères avec un script ; aucun chiffre non fourni par le client ; écrire copies.csv avec la colonne longueur.", ["S1"], ["C2", "C3", "C4"], 18, ["deliverables/copies.csv"], "normal"),
         S("S3", "Spécifications de visuels", "lea", "Pour chaque emplacement : format, ratio, zone de sécurité, texte dans l'image limite, brief creatif et variantes.", ["S1"], ["C5"], 10, ["deliverables/visuels-specs.md"]),
         S("S4", "Structure de campagne importable", "maya", "Construire campagnes.csv (statut en pause), nomenclature, ciblages explicites (jamais d'attribut personnel sensible), budgets et calendrier de test.", ["S2"], ["C6"], 12, ["deliverables/campagnes.csv"]),
         S("S5", "Suivi, contrôles et rapport", "maya", "Écrire suivi.md (UTM, événements, mesure de réussite), relire les limites de caractères, rédiger le rapport avec Sources et limites ; rappeler que l'activation et la dépense restent decisions du client.", ["S3", "S4"], ["C7"], 10, ["deliverables/suivi.md", "deliverables/rapport-publicites.md"])],
        [D("deliverables/strategie.md", "Strategie"), D("deliverables/copies.csv", "Textes d'annonces", "table"), D("deliverables/visuels-specs.md", "Spécifications de visuels"), D("deliverables/campagnes.csv", "Structure de campagne", "table"), D("deliverables/suivi.md", "Plan de suivi")],
        "deliverables/rapport-publicites.md",
        "Limites vérifiées le 2026-11-02 : Google RSA jusqu'à 15 titres de 30 caractères et 4 descriptions de 90 ; Meta fil d'actualite : texte principal 50 à 150 caractères et titre court recommandes. Relire ces limites dans l'outil de la plateforme avant import. Toute campagne est créée EN PAUSE par le client ; aucune opération d'ecriture sur Meta ou Google n'existe dans le moteur. Interdits : promesse de résultat, avant/apres sur la santé ou le corps, ciblage sur des attributs personnels. Lire d'abord les standards publicitaires de la plateforme.",
        support=["emma", "lea"], min_plan="equipe", optional=["meta_ads", "google_ads"],
        needs=[Q("Q1", "Budget total ou journalier, durée et objectif (ventes, prospects, visites) ?", "hypothèse : 20 CHF/jour sur 14 jours, objectif visites qualifiées, étiquetée"), Q("Q2", "Offre, prix, page de destination, preuves réelles disponibles ?", "[À COMPLÉTER], aucune preuve inventée")],
        sources=["gads-rsa", "gads-editorial", "meta-feed-specs", "meta-ad-standards"], credits=[50, 110], hours=[1.5, 3],
        forbidden=["promesse chiffrée de résultat", "témoignage ou avis inventé", "activation d'une campagne ou dépense sans decision du client"],
        scenarios=["S4-pub-boutique"]))

    # ------------------------------------------------------------------ Seoya : audit SEO complet
    out.append(build(
        "audit-seo-complet", "seoya", "Audit SEO complet d'un site, avec preuve par URL et plan de correction",
        "Exploration de 25 pages au plus, constats prouvés URL par URL, priorités impact x effort, 5 briefs de contenu et plan de correction.",
        ["mission-seo-geo-complete", "audit-on-page", "article-optimise-complet"],
        ["audit seo", "seo", "referencement", "audit de mon site", "visibilité google", "améliorer mon référencement", "mots-cles"],
        ["Fais un audit SEO complet de mon site et dis-moi quoi corriger", "Je veux être mieux classe sur Google : audit et plan d'action"],
        [A("C1", "audit.csv : une ligne par page explorée (25 au plus), avec statut, titre, h1, description, canonical et la preuve", csvc("deliverables/audit.csv", ["url", "statut", "titre", "h1", "meta_description", "canonical", "constat", "preuve"], 5, "url", ["url", "statut", "preuve"])),
         A("C2", "audit.md : synthèse, problèmes classes par impact et effort, ce qui n'a pas pu être mesuré", fc("deliverables/audit.md", ["Impact", "Effort", "Non mesure"])),
         A("C3", "5 briefs de contenu complets (requête, intention, plan, mots à couvrir, maillage)", cm("deliverables/briefs.md", "^## Brief", 5)),
         A("C4", "plan-correctifs.md : chaque correctif avec page, balise exacte à coller et propriétaire", fc("deliverables/plan-correctifs.md", ["Correctif", "Page"])),
         Rb("C5", "Aucun constat sans preuve ; aucun volume de recherche inventé", "Chaque constat renvoie a une URL lue (champ preuve). Les volumes de recherche, positions et trafic sont absents sauf données Search Console fournies ; dire 'non disponible' sinon.")],
        [S("S1", "Cadrage et liste des pages", "seoya", "Lire le sitemap et robots.txt ; choisir au plus 25 URLs représentatives ; noter les pages inaccessibles.", crit=["C1"], est=8, out=["data/urls.txt"]),
         S("S2", "Exploration et constats par URL", "lucas", "Lire chaque page (web_fetch) : statut, titre, H1, meta, canonical, maillage, images, hreflang, données structurées ; écrire audit.csv avec la preuve (extrait).", ["S1"], ["C1", "C5"], 24, ["deliverables/audit.csv"], "bulk"),
         S("S3", "Analyse et priorités", "seoya", "Classer les problèmes par impact et effort ; distinguer observe / a vérifier ; écrire audit.md.", ["S2"], ["C2", "C5"], 14, ["deliverables/audit.md"], "deep"),
         S("S4", "Briefs de contenu", "emma", "Écrire 5 briefs complets à partir des lacunes constatees (requêtes réelles seulement si Search Console fournie).", ["S3"], ["C3"], 14, ["deliverables/briefs.md"]),
         S("S5", "Plan de correction et rapport", "seoya", "Écrire plan-correctifs.md ; préparer les brouillons WordPress seulement si le client l'a demandé ; rapport avec Sources et limites.", ["S3", "S4"], ["C4"], 12, ["deliverables/plan-correctifs.md", "deliverables/rapport-seo.md"])],
        [D("deliverables/audit.csv", "Audit par URL", "table"), D("deliverables/audit.md", "Synthèse de l'audit"), D("deliverables/briefs.md", "Briefs de contenu"), D("deliverables/plan-correctifs.md", "Plan de correction")],
        "deliverables/rapport-seo.md",
        "Sans lecture web disponible, ne pas auditer de memoire : bloquer l'étape et demander le HTML des pages. Positions et volumes : uniquement via Search Console du client, sinon 'non disponible'. Ne jamais conseiller cloaking, pages satellites en masse, contenu généré en masse, liens achetés (règles de spam de Google). Les corrections sur le site du client passent par des brouillons WordPress (a valider).",
        support=["lucas", "emma"], min_plan="solo", optional=["google_search_console", "wordpress"],
        approvals=[AP("wordpress", "UPDATE_DRAFT", "medium", "le client veut les correctifs déposés en brouillon sur son WordPress"), AP("wordpress", "CREATE_DRAFT", "low", "pages de contenu issues des briefs, en brouillon")],
        needs=[Q("Q1", "Adresse du site et des 2 ou 3 pages qui comptent le plus ?", "pages deduites du sitemap", True), Q("Q2", "Marché et langue visees, concurrents connus ?", "marché déduit du site")],
        sources=["seo-starter", "title-link", "spam-policies"], credits=[50, 110], hours=[1, 3], scenarios=["S5-audit-seo"]))

    # ------------------------------------------------------------------ Emma : calendrier social
    out.append(build(
        "calendrier-social-30j", "emma", "Calendrier de contenu social sur 30 jours (3 réseaux)",
        "90 publications (30 jours x 3 réseaux) avec texte, hashtags, appel à l'action, brief visuel et horaire. Rien n'est publie.",
        ["strategie-calendrier-editorial", "posts-a-la-demande", "publication-reseaux-sociaux"],
        ["calendrier éditorial", "calendrier de contenu", "réseaux sociaux", "posts", "linkedin", "instagram", "planning de publication", "contenu 30 jours"],
        ["Fais-moi un calendrier de publications sur 30 jours pour LinkedIn, Instagram et Facebook", "Planifie mon contenu réseaux sociaux du mois"],
        [A("C1", "calendrier.csv : 30 jours x 3 réseaux, avec texte, hashtags, appel à l'action, brief visuel et horaire", csvc("deliverables/calendrier.csv", ["jour", "reseau", "angle", "texte", "hashtags", "cta", "brief_visuel", "horaire", "longueur"], 90, None, ["jour", "reseau", "texte", "cta", "horaire", "longueur"])),
         A("C2", "Piliers de contenu et voix de marque ecrits", fc("deliverables/strategie-editoriale.md", ["Piliers", "Voix"])),
         Rb("C3", "Limites de caractères respectées par réseau et variété d'angles", "Recompter 8 lignes : X <= 280, LinkedIn <= 3000, Instagram légende <= 2200 (a reconfirmer dans l'editeur du réseau). Au moins 5 angles différents, jamais plus de 2 jours consécutifs sur le même."),
         A("C4", "Aucune statistique, avis ou promesse inventés", fc("deliverables/calendrier.csv", mustnot=["re:\\b\\d{2,3} ?% (des|de nos)", "re:selon une etude", "re:nos \\d+ clients", "re:garanti"])),
         A("C5", "briefs-visuels.md : un brief par visuel distinct", fc("deliverables/briefs-visuels.md", ["Brief"]))],
        [S("S1", "Voix, piliers, angles", "emma", "Lire le profil, l'offre et le ton ; définir 4 piliers, la voix, 8 angles, la cadence par réseau et les jours forts.", crit=["C2"], est=8, out=["deliverables/strategie-editoriale.md"]),
         S("S2", "Calendrier et textes", "emma", "Écrire les 90 publications adaptées à chaque réseau, avec longueur calculee par script ; aucun fait non fourni.", ["S1"], ["C1", "C3", "C4"], 24, ["deliverables/calendrier.csv"], "bulk"),
         S("S3", "Briefs visuels", "lea", "Un brief par visuel distinct (format, texte, ambiance), réutilisable sur plusieurs réseaux.", ["S2"], ["C5"], 8, ["deliverables/briefs-visuels.md"]),
         S("S4", "Relecture, articles et rapport", "emma", "Recompter les limites, retirer toute affirmation sans source, préparer les brouillons de publication SEULEMENT si le client le demande, rapport avec Sources et limites.", ["S3"], ["C3"], 8, ["deliverables/rapport-calendrier.md"])],
        [D("deliverables/calendrier.csv", "Calendrier de publication", "table"), D("deliverables/strategie-editoriale.md", "Stratégie éditoriale"), D("deliverables/briefs-visuels.md", "Briefs visuels")],
        "deliverables/rapport-calendrier.md",
        "Les limites par réseau changent : les re-verifier dans l'editeur du réseau. Une publication est une action sortante irréversible : jamais automatique ; chaque brouillon de publication est un article d'approbation (lots de 50 au plus). Ne citer aucune statistique, etude ou témoignage qui ne vient pas du client.",
        support=["lea"], min_plan="solo", optional=["linkedin", "facebook", "x_twitter", "tiktok"],
        approvals=[AP("linkedin", "CREATE_DRAFT_POST", "medium", "le client demande la mise en file des publications"), AP("facebook", "CREATE_DRAFT_POST", "medium", "idem Facebook"), AP("x_twitter", "CREATE_DRAFT_POST", "medium", "idem X")],
        needs=[Q("Q1", "Les 3 réseaux voulus, l'offre du mois, les dates cles (promos, événements) ?", "LinkedIn, Instagram, Facebook ; dates [À COMPLÉTER]"), Q("Q2", "Exemples de posts qui vous ressemblent ?", "voix déduite du profil")],
        credits=[25, 60], hours=[0.5, 1.5], scenarios=["S6-calendrier-boulangerie"]))

    # ------------------------------------------------------------------ Ines : rapport xlsx/docx/pdf
    out.append(build(
        "rapport-xlsx-docx-pdf", "ines", "Rapport d'analyse : classeur à formules vivantes, document et PDF",
        "À partir d'un fichier de données, un classeur Excel à formules vivantes avec graphiques, un rapport Word structure et sa version PDF, aux totaux rapprochés.",
        ["analyse-de-donnees", "audit-qualite-donnees", "tableau-de-bord-decisionnel"],
        ["rapport", "analyse de données", "excel", "tableau de bord", "fichier de ventes", "rapport de ventes", "xlsx", "bilan chiffre"],
        ["Fais-moi un rapport sur mes ventes à partir de ce CSV, avec Excel, Word et PDF", "Analyse ce fichier et livre un rapport"],
        [A("C1", "rapport.xlsx : formules vivantes (pas de valeurs figées), aucune cellule en erreur, feuilles Données et Synthèse", xl("deliverables/rapport.xlsx", ["Donnees", "Synthese"], 10)),
         A("C2", "rapport.docx : synthèse, méthode, constats, recommandations", dx("deliverables/rapport.docx", 400, ["Synthese", "Methode", "Constats", "Recommandations"])),
         A("C3", "rapport.pdf livre", fe("deliverables/rapport.pdf", 2000)),
         A("C4", "Journal de qualité des données : lignes écartées et pourquoi", fc("deliverables/qualite-donnees.md", ["Lignes écartées"])),
         Rb("C5", "Totaux rapprochés entre classeur, document et PDF ; aucun chiffre sans calcul", "Prendre 3 totaux du docx et les retrouver dans le xlsx (formule) ; FAIL si un écart ou si un chiffre ne vient d'aucune cellule.")],
        [S("S1", "Lecture et qualité des données", "ines", "Lire le fichier fourni, lister colonnes, types, doublons, lignes corrompues ; écrire qualite-donnees.md sans corriger en silence.", crit=["C4"], est=6, out=["deliverables/qualite-donnees.md"]),
         S("S2", "Classeur à formules vivantes", "ines", "Construire rapport.xlsx avec une feuille Données, une feuille Synthèse en formules (SOMME, SOMME.SI, MOYENNE...), des graphiques ; vérifier l'absence d'erreurs.", ["S1"], ["C1"], 10, ["deliverables/rapport.xlsx"]),
         S("S3", "Rapport Word et PDF", "ines", "Rédiger rapport.docx (synthèse, méthode, constats, recommandations) avec les chiffres tirés du classeur, puis exporter en PDF.", ["S2"], ["C2", "C3", "C5"], 10, ["deliverables/rapport.docx", "deliverables/rapport.pdf"]),
         S("S4", "Rapprochement et rapport final", "ines", "Rapprocher 3 totaux entre les fichiers ; rapport final avec Sources et limites ; si une finance est en jeu, signaler ce que Dario doit valider.", ["S3"], ["C5"], 5, ["deliverables/rapport-analyse.md"])],
        [D("deliverables/rapport.xlsx", "Classeur", "spreadsheet"), D("deliverables/rapport.docx", "Rapport Word", "document"), D("deliverables/rapport.pdf", "Rapport PDF", "document")],
        "deliverables/rapport-analyse.md",
        "Exige l'execution de code (openpyxl, python-docx) : sur un moteur sans cette capacite, livrer au moins le CSV de synthèse et le rapport texte et le dire clairement, sans prétendre avoir produit les fichiers Office. Toute valeur calculee doit être une formule. Ne jamais corriger une donnée en silence : l'ecarter et la lister.",
        support=["dario"], min_plan="solo", credits=[15, 40], hours=[0.3, 1],
        needs=[Q("Q1", "Le fichier de données et la question à laquelle répondre ?", "question déduite des colonnes", True)], scenarios=["S7-rapport-ventes"]))

    # ------------------------------------------------------------------ Chloe : lancement d'offre
    out.append(build(
        "lancement-offre", "chloe", "Lancement d'une offre : site, réseaux, publicités et SEO cohérents",
        "Chloe piloté Lucas, Lea, Emma, Seoya et Maya pour livrer un site, 30 jours de contenu, un jeu de publicités et un plan SEO cohérents entre eux.",
        ["coordination-multi-workers"],
        ["lancement", "lancer mon offre", "lance mon offre", "lancer ma boutique", "lance ma boutique", "lancement de produit", "plan de lancement", "nouvelle offre", "go to market complet", "site, réseaux", "site et réseaux", "site, contenu et pubs"],
        ["Lance ma boutique de bougies : site, réseaux, publicités et SEO", "Je lance une nouvelle offre, je veux tout : site, contenu et pubs"],
        [A("C1", "Fiche de faits unique (nom, offre, prix, ton, coordonnées) servant de référence à tous les livrables", fc("notes/fiche-faits.md", ["Prix", "Ton", "À COMPLÉTER"])),
         A("C2", "Site livre et contrôle", {"type": "site_check", "profile": "vitrine", "must": ["html", "links", "meta", "a11y", "privacy", "content"]}),
         A("C3", "Calendrier de 30 jours livre", csvc("deliverables/calendrier.csv", ["jour", "reseau", "texte"], 60)),
         A("C4", "Jeu de publicités livre", csvc("deliverables/copies.csv", ["plateforme", "texte"], 18)),
         A("C5", "Plan SEO livre", fc("deliverables/plan-seo.md", ["Requete", "Page"])),
         Rb("C6", "Cohérence entre site, réseaux et publicités", "Comparer prix, offre, promesses, noms, ton, couleurs : un même fait doit être identique partout. FAIL à la moindre contradiction ; indiquer les fichiers en cause."),
         A("C7", "Lancement : planning, responsables et approbations en attente listés", fc("deliverables/plan-lancement.md", ["Planning", "Approbations"]))],
        [S("S1", "Brief et fiche de faits", "chloe", "Fixer l'objectif, l'offre, les prix, le ton, la cible et les inconnues dans une fiche de faits que tous les Workers lisent.", crit=["C1"], est=14, out=["notes/fiche-faits.md"], effort="deep"),
         S("S2", "Identité visuelle", "lea", "Charte courte et logo typographique à partir de la fiche de faits.", ["S1"], [], 18, ["site/src/assets/style.css"]),
         S("S3", "Site", "lucas", "Construire et contrôler le site avec les outils du site ; textes de Emma en entree.", ["S2", "S1"], ["C2"], 60, ["site/dist/index.html"]),
         S("S4", "Textes du site", "emma", "Textes FR (puis EN si demande) bases sur la fiche de faits.", ["S1"], [], 25, ["site/src/pages/fr/"]),
         S("S5", "SEO", "seoya", "Plan de requêtes et de pages à partir du site réel, sans volumes inventés.", ["S3"], ["C5"], 30, ["deliverables/plan-seo.md"]),
         S("S6", "Calendrier de contenu 30 jours", "emma", "Calendrier sur 2 réseaux au moins, aligné sur la fiche de faits.", ["S1"], ["C3"], 40, ["deliverables/calendrier.csv"], "bulk"),
         S("S7", "Jeu de publicités", "maya", "Stratégie et textes d'annonces dans les limites des plateformes, en pause.", ["S1"], ["C4"], 40, ["deliverables/copies.csv"]),
         S("S8", "Relecture de cohérence", "chloe", "Comparer tous les livrables à la fiche de faits ; lister les contradictions ; créer des étapes de correction pour le Worker concerne.", ["S3", "S4", "S5", "S6", "S7"], ["C6"], 30, ["notes/coherence.md"], "deep"),
         S("S9", "Plan de lancement et consolidation", "chloe", "Planning de lancement, responsables, approbations en attente ; rapport final avec Sources et limites.", ["S8"], ["C7"], 20, ["deliverables/plan-lancement.md", "deliverables/rapport-lancement.md"])],
        [D("deliverables/plan-lancement.md", "Plan de lancement"), D("deliverables/calendrier.csv", "Calendrier de contenu", "table"), D("deliverables/copies.csv", "Textes d'annonces", "table"), D("deliverables/plan-seo.md", "Plan SEO")],
        "deliverables/rapport-lancement.md",
        "Chloe est cheffe de projet : une fiche de faits unique, un propriétaire par étape, une relecture de cohérence avant la fin. Les recettes de site, calendrier, publicités et SEO servent de guide aux étapes. Un Worker non inclus dans le forfait (Trio) : l'annoncer et proposer l'embauche, ne pas le contourner.",
        support=["lucas", "lea", "emma", "seoya", "maya"], min_plan="equipe", languages=["fr", "en"],
        needs=[Q("Q1", "Nom, offre, prix, public vise, ton, budget publicitaire ?", "champs [À COMPLÉTER] listés", True)],
        approvals=[AP("wordpress", "CREATE_DRAFT", "low", "pages du site en brouillon si demande"), AP("linkedin", "CREATE_DRAFT_POST", "medium", "publications si demande")],
        optional=["wordpress", "linkedin"], credits=[250, 450], hours=[4, 8], scenarios=["S8-lancement-bougies"]))
    return out
