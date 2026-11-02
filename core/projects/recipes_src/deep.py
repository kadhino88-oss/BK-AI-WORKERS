# -*- coding: utf-8 -*-
"""Recettes PROFONDES (familles phares du contrat, docs/AUTONOMY-ENGINE.md 9.3)."""
from lib import *  # noqa: F401,F403

LEGAL_PROSPECT = ("Prospection par message : le moteur ne fournit pas un avis juridique. En Suisse, l'envoi de publicite de masse par moyen de telecommunication "
                  "(e-mail, SMS) est encadre par l'art. 3 al. 1 lit. o de la loi contre la concurrence deloyale (LCD / UWG) ; le texte officiel sur fedlex.admin.ch n'a "
                  "PAS pu etre relu par le moteur le 2026-11-02 : a faire confirmer par un juriste avant tout envoi. Dans l'UE, la directive ePrivacy (art. 13) et les lois "
                  "nationales fixent le consentement prealable, avec des regimes B2B differents selon les pays ; le RGPD art. 21 al. 2-3 donne un droit d'opposition "
                  "immediat a la prospection. Le Worker prepare des BROUILLONS ; le client decide et envoie, et reste responsable de la base legale.")


def recipes():
    out = []

    # ------------------------------------------------------------------ Lucas : site vitrine
    out.append(build(
        "site-vitrine-pro", "lucas", "Site vitrine professionnel (FR/EN)",
        "Un site de 5 pages (accueil, prestations, a propos, tarifs, contact) en francais et en anglais, controle, avec apercu, zip et guide de mise en ligne.",
        ["brouillons-wordpress-webflow", "accessibilite-web", "core-web-vitals-performance"],
        ["site web", "site vitrine", "creer mon site", "landing page", "site professionnel", "site internet", "refonte de site"],
        ["Cree le site vitrine de mon cabinet, en francais et en anglais", "Je veux un site web professionnel pour mon entreprise de menuiserie"],
        [A("C1", "Toutes les pages prevues existent en FR et EN, sans lien casse", {"type": "site_check", "profile": "vitrine", "must": ["links", "i18n", "html"]}),
         A("C2", "Meta, Open Graph, sitemap, robots et canonical presents", {"type": "site_check", "must": ["meta", "seo"]}),
         A("C3", "Accessibilite de base et poids de page respectes", {"type": "site_check", "must": ["a11y", "perf", "img"]}),
         A("C4", "Aucun traceur ni ressource externe non declaree", {"type": "site_check", "must": ["privacy"]}),
         A("C5", "Aucun fait, chiffre, avis ou certification invente ; les donnees manquantes sont des [A COMPLETER] listes", {"type": "site_check", "must": ["content"]}),
         Rb("C6", "Ton, orthographe et coherence de marque entre pages et langues", "Ton adapte au secteur ; vouvoiement ; typographie francaise ; memes noms, prix et coordonnees partout ; EN naturel et non litteral."),
         A("C7", "Guide de mise en ligne livre", fe("deliverables/MISE-EN-LIGNE.md", 800))],
        [S("S1", "Cadrage, arborescence, ton", "lucas", "Lire le profil et les fichiers du client ; fixer les 5 pages, les langues, le ton, la liste des faits connus et des [A COMPLETER] ; ecrire site/site.json et site/ARBORESCENCE.md.", crit=["C1"], est=6, out=["site/site.json", "site/ARBORESCENCE.md"]),
         S("S2", "Charte et styles", "lea", "Definir couleurs (contraste AA), typographie systeme, logo SVG typographique et la feuille de style unique.", ["S1"], ["C3"], 10, ["site/src/assets/style.css", "site/src/assets/img/logo.svg"]),
         S("S3", "Textes FR", "emma", "Rediger les textes francais des 5 pages a partir des seuls faits du client ; tout fait absent reste [A COMPLETER: ...].", ["S1"], ["C5", "C6"], 12, ["site/src/pages/fr/"]),
         S("S4", "Pages HTML FR et construction", "lucas", "Assembler les pages avec site_scaffold puis site_build ; ne jamais ecrire dans site/dist/.", ["S2", "S3"], ["C1", "C2", "C3"], 18, ["site/dist/index.html"]),
         S("S5", "Version EN et parite", "emma", "Traduire naturellement chaque page (pas litteralement) ; memes prix, memes coordonnees ; hreflang par la construction.", ["S4"], ["C1", "C6"], 8, ["site/src/pages/en/"], "bulk"),
         S("S6", "SEO de base et balisage", "seoya", "Titres uniques de 30 a 60 caracteres, descriptions de 70 a 160, balisage JSON-LD limite aux valeurs de site.json.", ["S5"], ["C2"], 8, [], "normal"),
         S("S7", "Controles, corrections, paquet et guide de mise en ligne", "lucas", "Lancer site_check, corriger jusqu'a zero erreur, produire site_package et MISE-EN-LIGNE.md (guide manuel, enregistrements DNS reels seulement si le domaine est donne).", ["S6"], ["C4", "C5", "C7"], 10, ["deliverables/MISE-EN-LIGNE.md"])],
        [D("deliverables/site-site.zip", "Site complet (zip)", "site"), D("deliverables/MISE-EN-LIGNE.md", "Guide de mise en ligne")],
        "deliverables/rapport-site.md",
        "Un site de 5 pages. Construire par site_scaffold puis site_build ; ne jamais ecrire dans site/dist/. Aucun script tiers, aucune police externe, aucun formulaire sans traitement defini. Publication : toujours un guide manuel ; la route WordPress ne cree que des BROUILLONS de pages. Les contenus manquants restent [A COMPLETER].",
        support=["lea", "emma", "seoya"], min_plan="equipe", languages=["fr", "en"],
        needs=[Q("Q1", "Raison sociale, adresse, telephone, horaires, prestations et tarifs exacts ?", "champs [A COMPLETER]"), Q("Q2", "Logo et photos existants ?", "logo SVG typographique, pas de photos")],
        approvals=[AP("wordpress", "CREATE_DRAFT", "low", "le client demande la mise en ligne sur son WordPress (brouillons de pages)")],
        optional=["wordpress"], forbidden=["avis ou temoignages inventes", "chiffres de clientele", "police ou script externe", "formulaire sans traitement defini"],
        sources=["wcag22", "seo-starter", "title-link", "spam-policies"], credits=[70, 140], hours=[1.5, 4],
        variants={"essentiel": {"drop": ["S6"], "creditsRange": [55, 110], "label": "Sans passe SEO dediee, une seule langue"}},
        scenarios=["S1-physio-lausanne", "S2-menuisier"]))

    # ------------------------------------------------------------------ Alex : gestion de prospects
    out.append(build(
        "gestion-prospects", "alex", "Gestion de prospects : 30 prospects qualifies et brouillons d'approche",
        "Une liste de 30 prospects reels, chacun avec sa source publique, une grille de qualification, un brouillon d'approche par prospect et une note de conformite. Rien n'est envoye.",
        ["prospection-sortante", "suivi-crm-opportunites"],
        ["prospects", "prospection", "liste de prospects", "trouver des clients", "leads", "approche commerciale", "gestion des prospects"],
        ["Trouve-moi 30 prospects pour mon logiciel comptable a Geneve et prepare les messages", "Gere mes prospects : liste qualifiee et premiers e-mails en brouillon"],
        [A("C1", "prospects.csv : au moins 30 lignes, colonnes entreprise, site, source_url, role_contact, score, motif, chaque ligne avec une source_url", csvc("deliverables/prospects.csv", ["entreprise", "site", "source_url", "role_contact", "score", "motif"], 30, "entreprise", ["entreprise", "source_url", "score", "motif"])),
         A("C2", "Grille de qualification ecrite (criteres, poids, seuils)", fc("deliverables/grille.md", ["Criteres", "Seuil"])),
         A("C3", "Un brouillon d'approche par prospect", cm("deliverables/brouillons.md", "^## Prospect", 30)),
         A("C4", "Aucune boite privee ni profil personnel dans la liste (coordonnees professionnelles publiques uniquement)", fc("deliverables/prospects.csv", mustnot=["re:linkedin\\.com/in/", "re:@(gmail|hotmail|outlook|yahoo|bluewin|icloud)\\."])),
         Rb("C5", "Controle par echantillon : 5 source_url tirees au hasard sont ouvertes et confirment l'entreprise et le role", "Ouvrir 5 source_url au hasard (preview_fetch/web_fetch). FAIL si une page est morte ou ne mentionne pas l'entreprise ; UNVERIFIABLE si la lecture web est indisponible."),
         A("C6", "Note de conformite : base legale documentee, desinscription, aucun envoi automatique", fc("deliverables/conformite-prospection.md", ["Base legale", "Desinscription", "juriste"])),
         Rb("C7", "Brouillons personnalises et honnetes", "Chaque brouillon cite un fait verifiable de la source du prospect, propose une valeur concrete, est court, sans fausse urgence ni fausse relation ('suite a notre echange' interdit), avec identite de l'expediteur et moyen de ne plus etre contacte.")],
        [S("S1", "Cadrage : cible, offre, grille", "alex", "Fixer le profil de client ideal (secteur, taille, region, role), la proposition de valeur, les criteres de qualification et le seuil ; ecrire grille.md.", crit=["C2"], est=8, out=["deliverables/grille.md"]),
         S("S2", "Recherche des prospects", "amina", "Chercher sur le web public des entreprises correspondant au profil ; pour chacune : site, page source qui prouve l'existence et le role du contact. Entreprises seulement, coordonnees professionnelles publiques. Eliminer sites morts et doublons.", ["S1"], ["C1", "C4"], 24, ["data/prospects-bruts.csv"], "bulk"),
         S("S3", "Qualification et score", "alex", "Appliquer la grille a chaque prospect ; ecrire score et motif factuel ; produire prospects.csv trie.", ["S2"], ["C1"], 14, ["deliverables/prospects.csv"]),
         S("S4", "Brouillons d'approche", "emma", "Rediger un brouillon par prospect, personnalise sur un fait de sa source ; ton sobre ; identite de l'expediteur ; lien ou phrase de desinscription.", ["S3"], ["C3", "C7"], 22, ["deliverables/brouillons.md"], "bulk"),
         S("S5", "Controle par echantillon, conformite, CRM et rapport", "alex", "Verifier 5 sources au hasard ; ecrire conformite-prospection.md ; preparer les articles d'approbation : brouillons Gmail/Outlook (DRAFT_MESSAGE) et taches CRM (CREATE_TASK) ; jamais d'envoi.", ["S4"], ["C4", "C5", "C6"], 16, ["deliverables/conformite-prospection.md", "deliverables/rapport-prospection.md"])],
        [D("deliverables/prospects.csv", "Liste de prospects", "table"), D("deliverables/grille.md", "Grille de qualification"), D("deliverables/brouillons.md", "Brouillons d'approche"), D("deliverables/conformite-prospection.md", "Note de conformite")],
        "deliverables/rapport-prospection.md",
        "Chaque ligne du CSV porte sa source_url ouverte et lue par un Worker ; si la recherche web est indisponible, ne rien inventer : bloquer l'etape et demander une liste au client. Uniquement des entreprises et des coordonnees professionnelles publiques ; jamais d'adresse privee ni de profil personnel. Les brouillons sont deposes, jamais envoyes ; chaque envoi reste une decision du client.",
        support=["amina", "emma"], min_plan="solo",
        needs=[Q("Q1", "Votre offre en une phrase, votre cible (secteur, taille, region) et vos 3 meilleurs clients actuels (sans noms si confidentiel) ?", "cible deduite du profil, hypotheses listees", True), Q("Q2", "Ton souhaite et signature (nom, fonction) ?", "ton sobre, signature [A COMPLETER]")],
        approvals=[AP("gmail", "DRAFT_MESSAGE", "low", "un brouillon par prospect, depose dans Gmail"), AP("outlook_mail", "DRAFT_MESSAGE", "low", "idem pour Outlook"), AP("hubspot", "CREATE_TASK", "low", "une tache de relance par prospect")],
        optional=["gmail", "outlook_mail", "hubspot", "pipedrive"], sources=["gdpr-art21", "uwg-fedlex", "eprivacy-edpb"], legal=LEGAL_PROSPECT,
        forbidden=["adresse e-mail privee ou profil personnel", "coordonnee devinee ou reconstituee", "fausse relation ou fausse urgence dans un brouillon", "envoi automatique"],
        credits=[60, 120], hours=[1, 3], scenarios=["S3-prospects-comptables"]))

    # ------------------------------------------------------------------ Maya : publicites
    out.append(build(
        "publicites-meta-google", "maya", "Publicites Meta et Google : strategie et jeu complet pret a importer",
        "Strategie, 3 angles x 3 variantes de textes dans les limites de caracteres, specifications de visuels, structure de campagne en CSV et plan de suivi. Aucune depense lancee.",
        ["campagne-payante-plan-media", "go-to-market-lancement"],
        ["publicite", "publicites", "campagne meta", "facebook ads", "google ads", "annonces", "campagne payante", "creer des pubs"],
        ["Cree des publicites Meta pour ma boutique de the", "Prepare ma campagne Google Ads et Facebook, textes et structure"],
        [A("C1", "strategie.md : audience, offre, entonnoir, repartition du budget, KPI", fc("deliverables/strategie.md", ["Audience", "Entonnoir", "Budget", "KPI"])),
         A("C2", "copies.csv : 3 angles x 3 variantes pour chaque plateforme (au moins 18 lignes) avec longueur calculee", csvc("deliverables/copies.csv", ["plateforme", "emplacement", "angle", "variante", "texte", "longueur"], 18, None, ["texte", "longueur"])),
         Rb("C3", "Limites de caracteres respectees pour chaque emplacement et chaque plateforme", "Google RSA : titres <= 30, descriptions <= 90 caracteres. Meta fil : titre ~27, texte principal 50 a 150 recommandes. Recompter 6 lignes au hasard ; FAIL si une depasse."),
         A("C4", "Aucune promesse chiffree de resultat ni superlatif non prouve", fc("deliverables/copies.csv", mustnot=["re:garanti", "re:resultats? assures", "re:\\d+ ?% (de )?(ventes|clients|conversions|croissance)", "re:le meilleur|n[°o] ?1", "re:(augmentez|boostez|multipliez|doublez)[^;\n]{0,40}\d+ ?%"])),
         A("C5", "visuels-specs.md : formats, ratios, texte dans l'image, par emplacement", fc("deliverables/visuels-specs.md", ["Format", "Ratio"])),
         A("C6", "campagnes.csv : structure prete a importer (campagne, ensemble/groupe, annonce, ciblage, budget, statut en pause)", csvc("deliverables/campagnes.csv", ["campagne", "groupe", "annonce", "ciblage", "budget_jour", "statut"], 3, None, ["statut"])),
         A("C7", "suivi.md : UTM, evenements de conversion, plan de test et regles d'arret", fc("deliverables/suivi.md", ["UTM", "Evenement", "Test"]))],
        [S("S1", "Cadrage et strategie", "maya", "Lire le profil et les offres ; fixer audience, offre, entonnoir, budget (montant fourni par le client, sinon hypothese etiquetee), KPI ; ecrire strategie.md.", crit=["C1"], est=14, out=["deliverables/strategie.md"], effort="deep"),
         S("S2", "Textes des annonces", "emma", "Ecrire 3 angles x 3 variantes par plateforme ; compter les caracteres avec un script ; aucun chiffre non fourni par le client ; ecrire copies.csv avec la colonne longueur.", ["S1"], ["C2", "C3", "C4"], 18, ["deliverables/copies.csv"], "normal"),
         S("S3", "Specifications de visuels", "lea", "Pour chaque emplacement : format, ratio, zone de securite, texte dans l'image limite, brief creatif et variantes.", ["S1"], ["C5"], 10, ["deliverables/visuels-specs.md"]),
         S("S4", "Structure de campagne importable", "maya", "Construire campagnes.csv (statut en pause), nomenclature, ciblages explicites (jamais d'attribut personnel sensible), budgets et calendrier de test.", ["S2"], ["C6"], 12, ["deliverables/campagnes.csv"]),
         S("S5", "Suivi, controles et rapport", "maya", "Ecrire suivi.md (UTM, evenements, mesure de reussite), relire les limites de caracteres, rediger le rapport avec Sources et limites ; rappeler que l'activation et la depense restent decisions du client.", ["S3", "S4"], ["C7"], 10, ["deliverables/suivi.md", "deliverables/rapport-publicites.md"])],
        [D("deliverables/strategie.md", "Strategie"), D("deliverables/copies.csv", "Textes d'annonces", "table"), D("deliverables/visuels-specs.md", "Specifications de visuels"), D("deliverables/campagnes.csv", "Structure de campagne", "table"), D("deliverables/suivi.md", "Plan de suivi")],
        "deliverables/rapport-publicites.md",
        "Limites verifiees le 2026-11-02 : Google RSA jusqu'a 15 titres de 30 caracteres et 4 descriptions de 90 ; Meta fil d'actualite : texte principal 50 a 150 caracteres et titre court recommandes. Relire ces limites dans l'outil de la plateforme avant import. Toute campagne est creee EN PAUSE par le client ; aucune operation d'ecriture sur Meta ou Google n'existe dans le moteur. Interdits : promesse de resultat, avant/apres sur la sante ou le corps, ciblage sur des attributs personnels. Lire d'abord les standards publicitaires de la plateforme.",
        support=["emma", "lea"], min_plan="equipe", optional=["meta_ads", "google_ads"],
        needs=[Q("Q1", "Budget total ou journalier, duree et objectif (ventes, prospects, visites) ?", "hypothese : 20 CHF/jour sur 14 jours, objectif visites qualifiees, etiquetee"), Q("Q2", "Offre, prix, page de destination, preuves reelles disponibles ?", "[A COMPLETER], aucune preuve inventee")],
        sources=["gads-rsa", "gads-editorial", "meta-feed-specs", "meta-ad-standards"], credits=[50, 110], hours=[1.5, 3],
        forbidden=["promesse chiffree de resultat", "temoignage ou avis invente", "activation d'une campagne ou depense sans decision du client"],
        scenarios=["S4-pub-boutique"]))

    # ------------------------------------------------------------------ Seoya : audit SEO complet
    out.append(build(
        "audit-seo-complet", "seoya", "Audit SEO complet d'un site, avec preuve par URL et plan de correction",
        "Exploration de 25 pages au plus, constats prouves URL par URL, priorites impact x effort, 5 briefs de contenu et plan de correction.",
        ["mission-seo-geo-complete", "audit-on-page", "article-optimise-complet"],
        ["audit seo", "seo", "referencement", "audit de mon site", "visibilite google", "ameliorer mon referencement", "mots-cles"],
        ["Fais un audit SEO complet de mon site et dis-moi quoi corriger", "Je veux etre mieux classe sur Google : audit et plan d'action"],
        [A("C1", "audit.csv : une ligne par page explorée (25 au plus), avec statut, titre, h1, description, canonical et la preuve", csvc("deliverables/audit.csv", ["url", "statut", "titre", "h1", "meta_description", "canonical", "constat", "preuve"], 5, "url", ["url", "statut", "preuve"])),
         A("C2", "audit.md : synthese, problemes classes par impact et effort, ce qui n'a pas pu etre mesure", fc("deliverables/audit.md", ["Impact", "Effort", "Non mesure"])),
         A("C3", "5 briefs de contenu complets (requete, intention, plan, mots a couvrir, maillage)", cm("deliverables/briefs.md", "^## Brief", 5)),
         A("C4", "plan-correctifs.md : chaque correctif avec page, balise exacte a coller et propriétaire", fc("deliverables/plan-correctifs.md", ["Correctif", "Page"])),
         Rb("C5", "Aucun constat sans preuve ; aucun volume de recherche invente", "Chaque constat renvoie a une URL lue (champ preuve). Les volumes de recherche, positions et trafic sont absents sauf donnees Search Console fournies ; dire 'non disponible' sinon.")],
        [S("S1", "Cadrage et liste des pages", "seoya", "Lire le sitemap et robots.txt ; choisir au plus 25 URLs representatives ; noter les pages inaccessibles.", crit=["C1"], est=8, out=["data/urls.txt"]),
         S("S2", "Exploration et constats par URL", "lucas", "Lire chaque page (web_fetch) : statut, titre, H1, meta, canonical, maillage, images, hreflang, donnees structurees ; ecrire audit.csv avec la preuve (extrait).", ["S1"], ["C1", "C5"], 24, ["deliverables/audit.csv"], "bulk"),
         S("S3", "Analyse et priorites", "seoya", "Classer les problemes par impact et effort ; distinguer observe / a verifier ; ecrire audit.md.", ["S2"], ["C2", "C5"], 14, ["deliverables/audit.md"], "deep"),
         S("S4", "Briefs de contenu", "emma", "Ecrire 5 briefs complets a partir des lacunes constatees (requetes reelles seulement si Search Console fournie).", ["S3"], ["C3"], 14, ["deliverables/briefs.md"]),
         S("S5", "Plan de correction et rapport", "seoya", "Ecrire plan-correctifs.md ; preparer les brouillons WordPress seulement si le client l'a demande ; rapport avec Sources et limites.", ["S3", "S4"], ["C4"], 12, ["deliverables/plan-correctifs.md", "deliverables/rapport-seo.md"])],
        [D("deliverables/audit.csv", "Audit par URL", "table"), D("deliverables/audit.md", "Synthese de l'audit"), D("deliverables/briefs.md", "Briefs de contenu"), D("deliverables/plan-correctifs.md", "Plan de correction")],
        "deliverables/rapport-seo.md",
        "Sans lecture web disponible, ne pas auditer de memoire : bloquer l'etape et demander le HTML des pages. Positions et volumes : uniquement via Search Console du client, sinon 'non disponible'. Ne jamais conseiller cloaking, pages satellites en masse, contenu genere en masse, liens achetes (regles de spam de Google). Les corrections sur le site du client passent par des brouillons WordPress (a valider).",
        support=["lucas", "emma"], min_plan="solo", optional=["google_search_console", "wordpress"],
        approvals=[AP("wordpress", "UPDATE_DRAFT", "medium", "le client veut les correctifs deposes en brouillon sur son WordPress"), AP("wordpress", "CREATE_DRAFT", "low", "pages de contenu issues des briefs, en brouillon")],
        needs=[Q("Q1", "Adresse du site et des 2 ou 3 pages qui comptent le plus ?", "pages deduites du sitemap", True), Q("Q2", "Marche et langue visees, concurrents connus ?", "marche deduit du site")],
        sources=["seo-starter", "title-link", "spam-policies"], credits=[50, 110], hours=[1, 3], scenarios=["S5-audit-seo"]))

    # ------------------------------------------------------------------ Emma : calendrier social
    out.append(build(
        "calendrier-social-30j", "emma", "Calendrier de contenu social sur 30 jours (3 reseaux)",
        "90 publications (30 jours x 3 reseaux) avec texte, hashtags, appel a l'action, brief visuel et horaire. Rien n'est publie.",
        ["strategie-calendrier-editorial", "posts-a-la-demande", "publication-reseaux-sociaux"],
        ["calendrier editorial", "calendrier de contenu", "reseaux sociaux", "posts", "linkedin", "instagram", "planning de publication", "contenu 30 jours"],
        ["Fais-moi un calendrier de publications sur 30 jours pour LinkedIn, Instagram et Facebook", "Planifie mon contenu reseaux sociaux du mois"],
        [A("C1", "calendrier.csv : 30 jours x 3 reseaux, avec texte, hashtags, appel a l'action, brief visuel et horaire", csvc("deliverables/calendrier.csv", ["jour", "reseau", "angle", "texte", "hashtags", "cta", "brief_visuel", "horaire", "longueur"], 90, None, ["jour", "reseau", "texte", "cta", "horaire", "longueur"])),
         A("C2", "Piliers de contenu et voix de marque ecrits", fc("deliverables/strategie-editoriale.md", ["Piliers", "Voix"])),
         Rb("C3", "Limites de caracteres respectees par reseau et variete d'angles", "Recompter 8 lignes : X <= 280, LinkedIn <= 3000, Instagram legende <= 2200 (a reconfirmer dans l'editeur du reseau). Au moins 5 angles differents, jamais plus de 2 jours consecutifs sur le meme."),
         A("C4", "Aucune statistique, avis ou promesse inventes", fc("deliverables/calendrier.csv", mustnot=["re:\\b\\d{2,3} ?% (des|de nos)", "re:selon une etude", "re:nos \\d+ clients", "re:garanti"])),
         A("C5", "briefs-visuels.md : un brief par visuel distinct", fc("deliverables/briefs-visuels.md", ["Brief"]))],
        [S("S1", "Voix, piliers, angles", "emma", "Lire le profil, l'offre et le ton ; definir 4 piliers, la voix, 8 angles, la cadence par reseau et les jours forts.", crit=["C2"], est=8, out=["deliverables/strategie-editoriale.md"]),
         S("S2", "Calendrier et textes", "emma", "Ecrire les 90 publications adaptees a chaque reseau, avec longueur calculee par script ; aucun fait non fourni.", ["S1"], ["C1", "C3", "C4"], 24, ["deliverables/calendrier.csv"], "bulk"),
         S("S3", "Briefs visuels", "lea", "Un brief par visuel distinct (format, texte, ambiance), reutilisable sur plusieurs reseaux.", ["S2"], ["C5"], 8, ["deliverables/briefs-visuels.md"]),
         S("S4", "Relecture, articles et rapport", "emma", "Recompter les limites, retirer toute affirmation sans source, preparer les brouillons de publication SEULEMENT si le client le demande, rapport avec Sources et limites.", ["S3"], ["C3"], 8, ["deliverables/rapport-calendrier.md"])],
        [D("deliverables/calendrier.csv", "Calendrier de publication", "table"), D("deliverables/strategie-editoriale.md", "Strategie editoriale"), D("deliverables/briefs-visuels.md", "Briefs visuels")],
        "deliverables/rapport-calendrier.md",
        "Les limites par reseau changent : les re-verifier dans l'editeur du reseau. Une publication est une action sortante irreversible : jamais automatique ; chaque brouillon de publication est un article d'approbation (lots de 50 au plus). Ne citer aucune statistique, etude ou temoignage qui ne vient pas du client.",
        support=["lea"], min_plan="solo", optional=["linkedin", "facebook", "x_twitter", "tiktok"],
        approvals=[AP("linkedin", "CREATE_DRAFT_POST", "medium", "le client demande la mise en file des publications"), AP("facebook", "CREATE_DRAFT_POST", "medium", "idem Facebook"), AP("x_twitter", "CREATE_DRAFT_POST", "medium", "idem X")],
        needs=[Q("Q1", "Les 3 reseaux voulus, l'offre du mois, les dates cles (promos, evenements) ?", "LinkedIn, Instagram, Facebook ; dates [A COMPLETER]"), Q("Q2", "Exemples de posts qui vous ressemblent ?", "voix deduite du profil")],
        credits=[25, 60], hours=[0.5, 1.5], scenarios=["S6-calendrier-boulangerie"]))

    # ------------------------------------------------------------------ Ines : rapport xlsx/docx/pdf
    out.append(build(
        "rapport-xlsx-docx-pdf", "ines", "Rapport d'analyse : classeur a formules vivantes, document et PDF",
        "A partir d'un fichier de donnees, un classeur Excel a formules vivantes avec graphiques, un rapport Word structure et sa version PDF, aux totaux rapproches.",
        ["analyse-de-donnees", "audit-qualite-donnees", "tableau-de-bord-decisionnel"],
        ["rapport", "analyse de donnees", "excel", "tableau de bord", "fichier de ventes", "rapport de ventes", "xlsx", "bilan chiffre"],
        ["Fais-moi un rapport sur mes ventes a partir de ce CSV, avec Excel, Word et PDF", "Analyse ce fichier et livre un rapport"],
        [A("C1", "rapport.xlsx : formules vivantes (pas de valeurs figees), aucune cellule en erreur, feuilles Donnees et Synthese", xl("deliverables/rapport.xlsx", ["Donnees", "Synthese"], 10)),
         A("C2", "rapport.docx : synthese, methode, constats, recommandations", dx("deliverables/rapport.docx", 400, ["Synthese", "Methode", "Constats", "Recommandations"])),
         A("C3", "rapport.pdf livre", fe("deliverables/rapport.pdf", 2000)),
         A("C4", "Journal de qualite des donnees : lignes ecartees et pourquoi", fc("deliverables/qualite-donnees.md", ["Lignes ecartees"])),
         Rb("C5", "Totaux rapproches entre classeur, document et PDF ; aucun chiffre sans calcul", "Prendre 3 totaux du docx et les retrouver dans le xlsx (formule) ; FAIL si un ecart ou si un chiffre ne vient d'aucune cellule.")],
        [S("S1", "Lecture et qualite des donnees", "ines", "Lire le fichier fourni, lister colonnes, types, doublons, lignes corrompues ; ecrire qualite-donnees.md sans corriger en silence.", crit=["C4"], est=6, out=["deliverables/qualite-donnees.md"]),
         S("S2", "Classeur a formules vivantes", "ines", "Construire rapport.xlsx avec une feuille Donnees, une feuille Synthese en formules (SOMME, SOMME.SI, MOYENNE...), des graphiques ; verifier l'absence d'erreurs.", ["S1"], ["C1"], 10, ["deliverables/rapport.xlsx"]),
         S("S3", "Rapport Word et PDF", "ines", "Rediger rapport.docx (synthese, methode, constats, recommandations) avec les chiffres tires du classeur, puis exporter en PDF.", ["S2"], ["C2", "C3", "C5"], 10, ["deliverables/rapport.docx", "deliverables/rapport.pdf"]),
         S("S4", "Rapprochement et rapport final", "ines", "Rapprocher 3 totaux entre les fichiers ; rapport final avec Sources et limites ; si une finance est en jeu, signaler ce que Dario doit valider.", ["S3"], ["C5"], 5, ["deliverables/rapport-analyse.md"])],
        [D("deliverables/rapport.xlsx", "Classeur", "spreadsheet"), D("deliverables/rapport.docx", "Rapport Word", "document"), D("deliverables/rapport.pdf", "Rapport PDF", "document")],
        "deliverables/rapport-analyse.md",
        "Exige l'execution de code (openpyxl, python-docx) : sur un moteur sans cette capacite, livrer au moins le CSV de synthese et le rapport texte et le dire clairement, sans pretendre avoir produit les fichiers Office. Toute valeur calculee doit etre une formule. Ne jamais corriger une donnee en silence : l'ecarter et la lister.",
        support=["dario"], min_plan="solo", credits=[15, 40], hours=[0.3, 1],
        needs=[Q("Q1", "Le fichier de donnees et la question a laquelle repondre ?", "question deduite des colonnes", True)], scenarios=["S7-rapport-ventes"]))

    # ------------------------------------------------------------------ Chloe : lancement d'offre
    out.append(build(
        "lancement-offre", "chloe", "Lancement d'une offre : site, reseaux, publicites et SEO coherents",
        "Chloe pilote Lucas, Lea, Emma, Seoya et Maya pour livrer un site, 30 jours de contenu, un jeu de publicites et un plan SEO coherents entre eux.",
        ["coordination-multi-workers"],
        ["lancement", "lancer mon offre", "lance mon offre", "lancer ma boutique", "lance ma boutique", "lancement de produit", "plan de lancement", "nouvelle offre", "go to market complet", "site, réseaux", "site et réseaux", "site, contenu et pubs"],
        ["Lance ma boutique de bougies : site, reseaux, publicites et SEO", "Je lance une nouvelle offre, je veux tout : site, contenu et pubs"],
        [A("C1", "Fiche de faits unique (nom, offre, prix, ton, coordonnees) servant de reference a tous les livrables", fc("notes/fiche-faits.md", ["Prix", "Ton", "A COMPLETER"])),
         A("C2", "Site livre et controle", {"type": "site_check", "profile": "vitrine", "must": ["html", "links", "meta", "a11y", "privacy", "content"]}),
         A("C3", "Calendrier de 30 jours livre", csvc("deliverables/calendrier.csv", ["jour", "reseau", "texte"], 60)),
         A("C4", "Jeu de publicites livre", csvc("deliverables/copies.csv", ["plateforme", "texte"], 18)),
         A("C5", "Plan SEO livre", fc("deliverables/plan-seo.md", ["Requete", "Page"])),
         Rb("C6", "Coherence entre site, reseaux et publicites", "Comparer prix, offre, promesses, noms, ton, couleurs : un meme fait doit etre identique partout. FAIL a la moindre contradiction ; indiquer les fichiers en cause."),
         A("C7", "Lancement : planning, responsables et approbations en attente listes", fc("deliverables/plan-lancement.md", ["Planning", "Approbations"]))],
        [S("S1", "Brief et fiche de faits", "chloe", "Fixer l'objectif, l'offre, les prix, le ton, la cible et les inconnues dans une fiche de faits que tous les Workers lisent.", crit=["C1"], est=14, out=["notes/fiche-faits.md"], effort="deep"),
         S("S2", "Identite visuelle", "lea", "Charte courte et logo typographique a partir de la fiche de faits.", ["S1"], [], 18, ["site/src/assets/style.css"]),
         S("S3", "Site", "lucas", "Construire et controler le site avec les outils du site ; textes de Emma en entree.", ["S2", "S1"], ["C2"], 60, ["site/dist/index.html"]),
         S("S4", "Textes du site", "emma", "Textes FR (puis EN si demande) bases sur la fiche de faits.", ["S1"], [], 25, ["site/src/pages/fr/"]),
         S("S5", "SEO", "seoya", "Plan de requetes et de pages a partir du site reel, sans volumes inventes.", ["S3"], ["C5"], 30, ["deliverables/plan-seo.md"]),
         S("S6", "Calendrier de contenu 30 jours", "emma", "Calendrier sur 2 reseaux au moins, aligne sur la fiche de faits.", ["S1"], ["C3"], 40, ["deliverables/calendrier.csv"], "bulk"),
         S("S7", "Jeu de publicites", "maya", "Strategie et textes d'annonces dans les limites des plateformes, en pause.", ["S1"], ["C4"], 40, ["deliverables/copies.csv"]),
         S("S8", "Relecture de coherence", "chloe", "Comparer tous les livrables a la fiche de faits ; lister les contradictions ; creer des etapes de correction pour le Worker concerne.", ["S3", "S4", "S5", "S6", "S7"], ["C6"], 30, ["notes/coherence.md"], "deep"),
         S("S9", "Plan de lancement et consolidation", "chloe", "Planning de lancement, responsables, approbations en attente ; rapport final avec Sources et limites.", ["S8"], ["C7"], 20, ["deliverables/plan-lancement.md", "deliverables/rapport-lancement.md"])],
        [D("deliverables/plan-lancement.md", "Plan de lancement"), D("deliverables/calendrier.csv", "Calendrier de contenu", "table"), D("deliverables/copies.csv", "Textes d'annonces", "table"), D("deliverables/plan-seo.md", "Plan SEO")],
        "deliverables/rapport-lancement.md",
        "Chloe est cheffe de projet : une fiche de faits unique, un proprietaire par etape, une relecture de coherence avant la fin. Les recettes de site, calendrier, publicites et SEO servent de guide aux etapes. Un Worker non inclus dans le forfait (Trio) : l'annoncer et proposer l'embauche, ne pas le contourner.",
        support=["lucas", "lea", "emma", "seoya", "maya"], min_plan="equipe", languages=["fr", "en"],
        needs=[Q("Q1", "Nom, offre, prix, public vise, ton, budget publicitaire ?", "champs [A COMPLETER] listes", True)],
        approvals=[AP("wordpress", "CREATE_DRAFT", "low", "pages du site en brouillon si demande"), AP("linkedin", "CREATE_DRAFT_POST", "medium", "publications si demande")],
        optional=["wordpress", "linkedin"], credits=[250, 450], hours=[4, 8], scenarios=["S8-lancement-bougies"]))
    return out
