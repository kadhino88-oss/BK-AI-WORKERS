# -*- coding: utf-8 -*-
"""Recettes de couverture : Lucas, Alex, Maya, Séoya, Emma, Inès (en plus de leur recette profonde)."""
from lib import *  # noqa: F401,F403
from deep import LEGAL_PROSPECT


def recipes():
    o = []
    # ---------------------------------------------------------------- Lucas
    o.append(light(
        "audit-technique-site", "lucas", "Audit technique d'un site avec correctifs prêts à coller",
        "Audit SEO technique des pages clés : balises, canonical, robots, sitemap, contenus mixtes, données structurées, avec la balise exacte à coller pour chaque correctif.",
        ["audit-seo-technique", "core-web-vitals-performance"],
        ["audit technique", "seo technique", "balises", "canonical", "sitemap", "robots.txt", "indexation", "core web vitals"],
        ["Fais l'audit technique de mon site et donne-moi les correctifs à coller"],
        [("deliverables/audit-technique.md", "Rapport d'audit technique", ["Constats", "Impact", "Effort", "À vérifier"]),
         ("deliverables/correctifs.md", "Correctifs prêts à coller", ["Page", "Avant", "Après"])],
        ("Lire robots.txt, le sitemap et 5 à 10 pages clés (web_fetch) ; noter ce qui n'est pas observable (codes HTTP, redirections, vitesse mesurée).",
         "Pour chaque constat : URL, extrait lu, gravité, impact et effort ; pour chaque correctif la balise exacte avant/après.",
         "Marquer « À vérifier » tout ce qui n'a pas été observé et donner la méthode de test ; section Sources et limites."),
        ("Chaque constat est prouvé par une page lue ; aucune mesure de vitesse inventée", "Chaque constat cite une URL et un extrait réellement lus. FAIL si un score de vitesse, un code HTTP ou une position est donné sans mesure."),
        "Sans lecture web, ne pas auditer de mémoire. Les Core Web Vitals ne sont pas mesurables sans outil de mesure : les classer « À vérifier » avec la méthode (PageSpeed Insights, rapport Search Console).",
        est=(6, 22, 6), optional=["google_search_console"], sources=["seo-starter", "title-link", "spam-policies"], support=["seoya"]))
    o.append(light(
        "audit-accessibilite-wcag", "lucas", "Contrôle d'accessibilité de base (WCAG 2.2 AA)",
        "Contrôle des pages clés contre les critères WCAG 2.2 niveau AA vérifiables dans le HTML, avec correctifs.",
        ["accessibilite-web"],
        ["accessibilité", "wcag", "contraste", "lecteur d'écran", "alt", "accessible"],
        ["Vérifie l'accessibilité de mon site"],
        [("deliverables/audit-accessibilite.md", "Rapport d'accessibilité", ["Critère", "Conforme", "Non conforme", "Non vérifié"]),
         ("deliverables/correctifs-accessibilite.md", "Correctifs", ["Page", "Correction"])],
        ("Lister les pages clés et gabarits ; lire leur HTML et leurs variables de couleurs.",
         "Contrôler : alternatives textuelles, contrastes 4,5:1 (3:1 grand texte), étiquettes de formulaires, ordre des titres, navigation au clavier, focus visible, taille des cibles ; calculer les contrastes par script.",
         "Classer Conforme / Non conforme / Non vérifié ; ce qui demande un test humain (lecteur d'écran) reste « Non vérifié » ; section Sources et limites."),
        ("Chaque critère « Conforme » est justifié par un élément lu ; aucun contraste annoncé sans calcul", "Reprendre 3 contrastes et les recalculer ; FAIL si un écart ou si un « Conforme » n'a pas de preuve."),
        "Un contrôle automatique ne remplace pas un audit complet avec technologies d'assistance : le dire. Référence : WCAG 2.2 (W3C).",
        est=(5, 16, 5), sources=["wcag22"], support=["lea"]))
    o.append(light(
        "plan-migration-refonte", "lucas", "Plan de migration, refonte ou passage en HTTPS",
        "Plan de migration daté : inventaire des URLs, table de redirections, risques SEO, ordre des opérations, tests avant/après et retour arrière.",
        ["migration-refonte-https"],
        ["migration", "refonte", "https", "redirections 301", "changement de domaine", "nouveau site"],
        ["Prépare la migration de mon site vers un nouveau domaine sans perdre mon référencement"],
        [("deliverables/plan-migration.md", "Plan de migration", ["Inventaire", "Risques", "Retour arrière", "Tests"]),
         ("deliverables/redirections.csv", "Table de redirections", [])],
        ("Inventorier les URLs à partir du sitemap et des pages liées ; définir l'ancienne et la nouvelle structure.",
         "Construire la table de redirections ancienne URL -> nouvelle URL (une ligne par URL, 301 sauf exception), le calendrier, les risques, les tests avant/après et le retour arrière.",
         "Vérifier qu'aucune URL de l'inventaire n'est sans cible ; indiquer ce qui doit être fait par l'hébergeur ; section Sources et limites."),
        ("Chaque URL de l'inventaire a une cible ; aucune étape n'est « à faire par le Worker » sur le site en ligne", "Comparer inventaire et redirections ; FAIL si une URL n'a pas de cible. Les actions sur le site réel sont décrites pour le client ou l'hébergeur, jamais exécutées."),
        "Le Worker prépare ; il ne modifie jamais le site en ligne. Les redirections se mettent en œuvre chez l'hébergeur ou le CMS du client.",
        est=(6, 18, 5), sources=["seo-starter"], needs=[Q("Q1", "Ancienne et nouvelle adresse, CMS et hébergeur ?", "[À COMPLÉTER]", True)]))

    # ---------------------------------------------------------------- Alex
    o.append(light(
        "relance-pipeline-dormant", "alex", "Relance du pipeline dormant : brouillons de relance et réactivation",
        "Tri des opportunités sans nouvelle, séquence de relance personnalisée en brouillons, priorités et tâches CRM. Rien n'est envoyé.",
        ["relances-reactivation"],
        ["relance", "relancer", "pipeline dormant", "réactivation", "devis sans réponse", "prospects silencieux"],
        ["Relance mes devis restés sans réponse depuis un mois"],
        [("deliverables/opportunites-triees.csv", "Opportunités triées", []),
         ("deliverables/relances.md", "Brouillons de relance", ["Opportunité", "Objet", "Message"])],
        ("Lire l'export ou la liste fournie ; classer par ancienneté, montant, dernier échange.",
         "Écrire une relance par opportunité, adaptée à la dernière interaction connue, avec une seule demande claire et une sortie polie ; max 2 relances par contact dans la séquence.",
         "Contrôler qu'aucun fait n'est inventé (date d'échange, remise) ; préparer les brouillons et tâches CRM en approbation ; section Sources et limites."),
        ("Les relances ne mentionnent que des échanges réels de l'export et laissent une sortie au destinataire", "Chaque relance s'appuie sur un élément de l'export ; aucune urgence ou remise inventée ; lien ou phrase pour ne plus être relancé."),
        "Aucun envoi : brouillons uniquement. Ne relancer que des contacts avec qui une relation d'affaires existe dans les données du client ; respecter toute demande de désinscription.",
        est=(5, 14, 5), approvals=[AP("gmail", "DRAFT_MESSAGE", "low", "un brouillon de relance par opportunité"), AP("hubspot", "CREATE_TASK", "low", "une tâche de suivi")],
        optional=["gmail", "outlook_mail", "hubspot"], sources=["gdpr-art21", "uwg-fedlex"], legal=LEGAL_PROSPECT, needs=[Q("Q1", "L'export des opportunités (CSV) avec dernier contact ?", "bloquant sans données", True)]))
    o.append(light(
        "preparation-rendez-vous-decouverte", "alex", "Préparation d'un rendez-vous de découverte",
        "Fiche de préparation : contexte public du prospect, questions de découverte, réponses aux objections probables, proposition de prochaine étape.",
        ["preparation-rendez-vous"],
        ["préparer un rendez-vous", "rendez-vous commercial", "découverte", "objections", "appel de vente", "préparer un call"],
        ["Prépare mon rendez-vous de jeudi avec cette entreprise"],
        [("deliverables/fiche-rdv.md", "Fiche de rendez-vous", ["Contexte", "Questions", "Objections", "Prochaine étape"])],
        ("Lire les informations fournies et les pages publiques de l'entreprise (web_fetch) ; noter ce qui est sourcé.",
         "Écrire : contexte sourcé, 8 questions de découverte, 5 objections probables avec réponses honnêtes, 2 prochaines étapes possibles.",
         "Retirer toute affirmation non sourcée sur le prospect ; section Sources et limites ; proposer en approbation l'événement de calendrier si demandé."),
        ("Le contexte du prospect est sourcé et les réponses aux objections ne contiennent aucune promesse non tenable", "Chaque fait sur le prospect porte son URL ; aucune garantie de résultat."),
        "Informations professionnelles publiques seulement. L'invitation de calendrier passe par approbation.",
        est=(4, 8, 4), approvals=[AP("calendar", "CREATE_EVENT", "low", "le client demande l'événement de préparation")], optional=["calendar", "outlook_calendar"]))
    o.append(light(
        "qualification-leads-entrants", "alex", "Qualification des leads entrants et réponses prêtes",
        "Qualification d'une liste de demandes entrantes sur une grille, avec réponse en brouillon pour chacune.",
        ["qualification-lead-entrant"],
        ["lead entrant", "qualifier", "demandes reçues", "formulaire de contact", "répondre aux demandes"],
        ["Qualifie les demandes reçues cette semaine et prépare les réponses"],
        [("deliverables/leads-qualifies.csv", "Leads qualifiés", []),
         ("deliverables/reponses.md", "Réponses en brouillon", ["Lead", "Réponse"])],
        ("Lire les demandes fournies ; fixer la grille (budget, besoin, délai, adéquation) avec le client ou par défaut étiquetée.",
         "Noter chaque lead avec motif factuel ; écrire une réponse courte par lead, qui pose la bonne question suivante.",
         "Vérifier qu'aucune demande n'est sans réponse ni sans score ; section Sources et limites."),
        ("Chaque lead a un score justifié par ses propres mots et une réponse adaptée", "Aucun score sans motif tiré de la demande ; réponses sans engagement de prix non fourni."),
        "Brouillons uniquement, jamais d'envoi.", est=(4, 10, 4), approvals=[AP("gmail", "DRAFT_MESSAGE", "low", "brouillon de réponse")], optional=["gmail", "outlook_mail"]))

    # ---------------------------------------------------------------- Maya
    o.append(light(
        "plan-croissance-funnel", "maya", "Plan de croissance : audit du funnel et expériences priorisées",
        "Audit du parcours d'acquisition à conversion avec les données fournies, hypothèses, expériences classées ICE et feuille de route sur 90 jours.",
        ["plan-de-croissance", "go-to-market-lancement"],
        ["plan de croissance", "funnel", "acquisition", "conversion", "croissance", "stratégie marketing", "lancement"],
        ["Fais-moi un plan de croissance pour les 3 prochains mois"],
        [("deliverables/audit-funnel.md", "Audit du funnel", ["Étape", "Constat", "Donnée"]),
         ("deliverables/experiences.csv", "Expériences priorisées", []),
         ("deliverables/feuille-de-route.md", "Feuille de route 90 jours", ["Semaine", "Responsable"])],
        ("Lire profil, offres et données fournies (trafic, ventes) ; lister les étapes du funnel et ce qui est mesuré.",
         "Pour chaque étape : constat appuyé sur une donnée fournie ou marqué hypothèse ; 10 expériences notées (impact, confiance, facilité) ; feuille de route.",
         "Retirer tout chiffre de benchmark sans source ; section Sources et limites."),
        ("Chaque constat est soit une donnée fournie, soit une hypothèse étiquetée ; aucun benchmark inventé", "Repérer les chiffres : chacun doit venir des fichiers du client ou d'une source citée."),
        "Pas de promesse de croissance chiffrée. Les données manquantes deviennent des questions.", est=(5, 16, 5), support=["ines"], optional=["google_search_console", "meta_ads"]))
    o.append(light(
        "sequences-email-nurturing", "maya", "Séquences d'e-mails : bienvenue, nurturing, réactivation",
        "Trois séquences d'e-mails rédigées (objets, textes, délais, conditions d'arrêt) prêtes à charger dans l'outil d'envoi du client.",
        ["sequences-email-nurturing"],
        ["séquence d'emails", "e-mails de bienvenue", "nurturing", "newsletter", "réactivation", "automation email"],
        ["Écris-moi la séquence d'e-mails de bienvenue et de relance de ma boutique"],
        [("deliverables/sequences.md", "Séquences d'e-mails", ["Bienvenue", "Nurturing", "Réactivation", "Objet", "Délai"]),
         ("deliverables/sequences.csv", "Séquences (import)", [])],
        ("Lire l'offre, le public et le ton ; définir déclencheurs, délais et conditions d'arrêt.",
         "Rédiger chaque e-mail (objet, préheader, corps, appel à l'action) ; pied de page avec identité de l'expéditeur et lien de désinscription.",
         "Contrôler promesses, spam-words et cohérence de ton ; section Sources et limites."),
        ("Chaque e-mail a un objet, une désinscription et aucune fausse urgence ou fausse relation", "Vérifier 5 e-mails au hasard."),
        "Ne s'adresse qu'à des contacts ayant consenti ou clients existants : le dire au client. Le Worker ne charge ni n'envoie rien.",
        est=(4, 14, 4), sources=["gdpr-art21", "uwg-fedlex"], legal=LEGAL_PROSPECT))
    o.append(light(
        "bilan-campagnes-visibilite", "maya", "Bilan de campagnes et de visibilité",
        "Lecture des résultats de campagnes (export fourni ou lecture seule Meta/Search Console) : ce qui marche, ce qui coûte trop, décisions recommandées.",
        ["bilan-campagnes-visibilite"],
        ["bilan de campagne", "résultats pub", "retour sur investissement", "roas", "performance meta", "rapport de campagne"],
        ["Fais le bilan de mes campagnes Meta du mois"],
        [("deliverables/bilan.md", "Bilan de campagnes", ["Résultats", "Décisions", "Limites"]),
         ("deliverables/bilan.csv", "Tableau des campagnes", [])],
        ("Lire l'export fourni ou les rapports en lecture seule ; contrôler période, devise, définitions.",
         "Calculer coût par résultat et taux, par campagne, par script ; comparer à l'objectif du client ; 5 décisions classées.",
         "Signaler attribution et échantillons trop petits ; section Sources et limites."),
        ("Tous les chiffres viennent de l'export, avec leur calcul ; les petits échantillons sont signalés", "Recalculer 3 chiffres."),
        "Lecture seule : aucune modification de campagne.", est=(4, 12, 4), optional=["meta_ads", "google_search_console"], support=["ines"]))

    # ---------------------------------------------------------------- Séoya
    o.append(light(
        "article-seo-complet", "seoya", "Article de blog optimisé, rédigé en entier",
        "Un article complet (plan, texte, titre, méta, maillage, FAQ) sur une requête précise, original, sans bourrage de mots-clés.",
        ["article-optimise-complet"],
        ["article de blog", "rédiger un article", "article seo", "contenu optimisé", "billet de blog"],
        ["Rédige un article optimisé sur la pose de parquet pour mon blog"],
        [("deliverables/article.md", "Article complet", ["Titre", "Description", "Plan", "FAQ"]),
         ("deliverables/fiche-seo.md", "Fiche SEO de l'article", ["Requête", "Intention", "Maillage"])],
        ("Définir requête, intention de recherche et public ; lire 2 ou 3 pages concurrentes si la lecture web est disponible.",
         "Rédiger l'article en entier (1 000 à 1 500 mots), titre de 30 à 60 caractères, description de 70 à 160, maillage interne, FAQ réelle.",
         "Vérifier l'originalité, l'absence de chiffres sans source et de bourrage ; section Sources et limites ; brouillon WordPress en approbation si demandé."),
        ("Texte utile, original, sans statistique inventée ni bourrage de mots-clés", "Chaque chiffre est sourcé ; lecture fluide ; aucun passage répétitif."),
        "Pas de contenu produit en masse pour manipuler le classement (règles anti-spam de Google). Pas d'avis ni de chiffres inventés.",
        est=(4, 14, 4), approvals=[AP("wordpress", "CREATE_DRAFT", "low", "l'article déposé en brouillon")], optional=["wordpress"], sources=["seo-starter", "title-link", "spam-policies"]))
    o.append(light(
        "cluster-thematique", "seoya", "Cluster thématique : page pilier et pages satellites",
        "Architecture d'un cluster : page pilier, 6 à 10 satellites, maillage, intentions et briefs.",
        ["cluster-thematique"],
        ["cluster", "page pilier", "architecture de contenu", "maillage interne", "stratégie de contenu seo"],
        ["Construis un cluster de contenu autour du chauffage au bois"],
        [("deliverables/cluster.md", "Architecture du cluster", ["Pilier", "Satellite", "Maillage"]),
         ("deliverables/cluster.csv", "Pages du cluster", [])],
        ("Définir le sujet, le public et les intentions de recherche ; contrôler ce qui existe déjà sur le site.",
         "Définir pilier et satellites (titre, requête, intention, mots à couvrir), maillage bidirectionnel, ordre de publication.",
         "Contrôler les doublons d'intention (cannibalisation) ; section Sources et limites (aucun volume de recherche sans donnée)."),
        ("Chaque page a une intention distincte et le maillage est complet", "Aucune cannibalisation ; chaque satellite renvoie au pilier."),
        "Volumes de recherche : seulement si fournis ; sinon « non disponible ».", est=(4, 12, 4), sources=["seo-starter", "spam-policies"]))
    o.append(light(
        "visibilite-assistants-ia", "seoya", "Visibilité dans les réponses des assistants IA (GEO)",
        "Diagnostic de la présence de la marque et du contenu pour les moteurs de réponses, avec actions concrètes.",
        ["optimisation-geo"],
        ["geo", "assistants ia", "chatgpt", "visibilité ia", "moteurs de réponse", "citations"],
        ["Mon entreprise est-elle citée par les assistants IA, que corriger ?"],
        [("deliverables/diagnostic-geo.md", "Diagnostic GEO", ["Constat", "Actions", "Non mesurable"]),
         ("deliverables/faq-structuree.md", "FAQ structurée", ["Question", "Réponse"])],
        ("Lister 10 questions que poserait un client ; lire le site et les sources publiques de la marque.",
         "Évaluer clarté des faits, structure, FAQ, balisage ; écrire une FAQ factuelle à publier.",
         "Dire clairement qu'on ne peut pas mesurer les citations réelles des assistants sans outil dédié ; section Sources et limites."),
        ("Aucune affirmation de citation ou de classement dans un assistant IA sans preuve", "FAIL si un résultat « la marque est citée » n'est pas prouvé par une capture ou un texte fourni."),
        "Aucune garantie de citation ; recommander des contenus utiles et exacts, pas de manipulation.", est=(4, 12, 4), sources=["spam-policies", "seo-starter"]))

    # ---------------------------------------------------------------- Emma
    o.append(light(
        "scripts-videos-courtes", "emma", "Pack de scripts de vidéos courtes (Reels, TikTok, Shorts)",
        "10 scripts de vidéos de 15 à 45 secondes avec accroche, plans, texte à l'écran, appel à l'action et brief de tournage.",
        ["scripts-videos-courtes"],
        ["script vidéo", "reels", "tiktok", "shorts", "vidéo courte", "scénario vidéo"],
        ["Écris-moi 10 scripts de Reels pour mon salon de coiffure"],
        [("deliverables/scripts-videos.md", "Scripts vidéo", ["Accroche", "Plans", "Appel à l'action"]),
         ("deliverables/plan-tournage.md", "Plan de tournage", ["Matériel", "Lieu"])],
        ("Lire profil, offre, ton ; fixer 5 thèmes et la durée.", "Écrire 10 scripts avec accroche des 3 premières secondes, plans, texte à l'écran, sous-titres.", "Contrôler durée, absence de promesses et de faux avis ; section Sources et limites."),
        ("Scripts réalisables avec un téléphone, sans fait inventé", "Chaque script est tournable seul en moins d'une heure."),
        "Aucune statistique ou témoignage inventé.", est=(4, 12, 4), support=["lea"]))
    o.append(light(
        "recyclage-contenu-long", "emma", "Un contenu long transformé en micro-contenus",
        "À partir d'un article, d'un webinaire ou d'un document fourni : 12 posts, 3 e-mails et une newsletter.",
        ["recyclage-de-contenu"],
        ["recycler", "transformer un article", "micro-contenus", "découper un contenu", "réutiliser"],
        ["Transforme mon article en posts pour les réseaux"],
        [("deliverables/micro-contenus.md", "Micro-contenus", ["Post", "Réseau"]),
         ("deliverables/newsletter.md", "Newsletter", ["Objet", "Corps"])],
        ("Lire le contenu source fourni et extraire 12 idées.", "Écrire chaque post fidèle à la source, adapté au réseau, avec renvoi à la source.", "Vérifier que rien n'est ajouté qui ne soit dans la source ; section Sources et limites."),
        ("Fidélité à la source : aucun ajout factuel", "Comparer 5 posts à la source."),
        "Le contenu source du client est la seule source de faits.", est=(3, 10, 3)))
    o.append(light(
        "reponses-commentaires", "emma", "Réponses aux commentaires et messages, dans votre voix",
        "Lot de réponses prêtes pour des commentaires ou messages fournis, avec tri (à répondre, à escalader, à ignorer).",
        ["community-management"],
        ["répondre aux commentaires", "community management", "avis clients", "messages reçus", "modération"],
        ["Réponds à ces 25 commentaires sur ma page"],
        [("deliverables/reponses-commentaires.csv", "Réponses", []), ("deliverables/regles-moderation.md", "Règles de modération", ["Escalade", "Ton"])],
        ("Lire les commentaires fournis et la voix de marque.", "Trier puis répondre à chacun, brièvement, sans engagement non fourni ; escalader les réclamations à Nora.", "Contrôler ton et promesses ; section Sources et limites."),
        ("Chaque commentaire a une décision et une réponse ou une raison de ne pas répondre", "Aucune promesse de remboursement ou délai inventée."),
        "Aucune réponse n'est publiée par le Worker.", est=(3, 8, 3), support=["nora"]))

    # ---------------------------------------------------------------- Inès
    o.append(light(
        "audit-qualite-donnees", "ines", "Audit de qualité et nettoyage de données",
        "Audit d'un fichier : doublons, valeurs manquantes, formats, outliers ; fichier nettoyé et journal de chaque modification.",
        ["audit-qualite-donnees"],
        ["nettoyer les données", "qualité des données", "doublons", "fichier clients", "base de données propre"],
        ["Nettoie ce fichier clients et dis-moi ce qui était faux"],
        [("deliverables/audit-qualite.md", "Audit de qualité", ["Doublons", "Manquants", "Formats"]), ("deliverables/donnees-nettoyees.csv", "Données nettoyées", []),
         ("deliverables/journal-modifications.csv", "Journal des modifications", [])],
        ("Lire le fichier fourni, profiler chaque colonne.", "Appliquer des règles explicites (jamais de correction silencieuse) ; écrire chaque modification au journal.", "Rapprocher les nombres de lignes avant/après ; section Sources et limites."),
        ("Lignes avant = lignes après + écartées, chaque modification journalisée", "Recompter."),
        "Ne jamais inventer une valeur manquante.", est=(4, 10, 4), needs=[Q("Q1", "Le fichier à nettoyer ?", "bloquant", True)]))
    o.append(light(
        "analyse-test-ab", "ines", "Analyse d'un test A/B avec test de significativité",
        "Lecture d'un test A/B : effectifs, taux, intervalle de confiance, significativité, décision et limites.",
        ["test-ab-significativite"],
        ["test a/b", "ab test", "significativité", "variante gagnante", "p-value"],
        ["Analyse mon test A/B : quelle variante gagne ?"],
        [("deliverables/analyse-ab.md", "Analyse du test", ["Effectifs", "Significativité", "Décision", "Limites"])],
        ("Lire les effectifs et conversions par variante ; vérifier durée et répartition.", "Calculer taux, intervalle de confiance et test adapté par script ; conclure.", "Dire si le test est concluant ou s'il faut plus de données ; section Sources et limites."),
        ("La conclusion est cohérente avec le calcul et la taille d'échantillon", "Recalculer le test."),
        "« Pas concluant » est une réponse valable.", est=(3, 8, 3)))
    o.append(light(
        "kpi-conversion-cohortes", "ines", "KPI de conversion, acquisition et cohortes",
        "Tableau de KPI définis rigoureusement (conversion, CAC, valeur vie, rétention) calculés depuis les données fournies.",
        ["kpi-conversion-cohortes", "tableau-de-bord-decisionnel"],
        ["kpi", "cac", "ltv", "rétention", "cohortes", "taux de conversion"],
        ["Calcule mes KPI de conversion et de rétention"],
        [("deliverables/kpi.md", "Définitions et résultats", ["Définition", "Résultat"]), ("deliverables/kpi.csv", "KPI (table)", [])],
        ("Lire les données ; fixer les définitions avec dénominateurs explicites.", "Calculer par script, par période et cohorte.", "Signaler les dénominateurs faibles ; section Sources et limites."),
        ("Chaque KPI a sa définition, sa formule et son dénominateur", "Recalculer 2 KPI."),
        "Pas de benchmark sans source.", est=(3, 10, 3)))
    return o
