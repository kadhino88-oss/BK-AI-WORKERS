# -*- coding: utf-8 -*-
"""BK-AI-WORKERS — Pages statiques reelles pour l'indexation (2026-09-24).
Avant ce fichier, Workers/Tarifs/FAQ/CGV/Mentions/Cookies n'existaient
que comme sections masquees (`hidden`, basculees en JS) DANS index.html
— Google ne voit alors qu'une seule page indexable. Ces fonctions
generent de VRAIES pages a leur propre URL, avec le contenu deja reel
(CGV, mentions, FAQ deja ecrits dans index.html — recopie ici, jamais
invente) plus les donnees reelles Workers/Tarifs (memes sources que
l'API : WORKER_CATEGORIES, build_worker_summary, memes plans que
PRICING_PLANS dans app.js). Chaque page garde un lien vers l'app
interactive complete (index.html) pour l'usage reel du produit.
"""


NAV_LINKS = [
    ("/", "Accueil"),
    ("/demarrer.html", "Démarrer"),
    ("/workers.html", "Workers"),
    ("/automatisations.html", "Automatisations"),
    ("/analytics.html", "Analytics"),
    ("/tarifs.html", "Tarifs"),
    ("/facturation.html", "Facturation"),
    ("/chloe.html", "Chloé"),
    ("/faq.html", "FAQ"),
    ("/cgv.html", "CGV"),
    ("/mentions-legales.html", "Mentions légales"),
    ("/confidentialite.html", "Confidentialité"),
    ("/cookies.html", "Cookies"),
]

# Pages de confiance (dashboard/trust_pages.py) : pied de page seulement, l'en-tete est deja charge.
FOOTER_TRUST_LINKS = [
    ("/securite.html", "Sécurité et confiance"),
    ("/status.html", "Statut du service"),
]

import re

# Palette et typo alignees sur dashboard/style.css (:root) — avant ce
# correctif (2026-09-24) ces pages statiques utilisaient des teintes
# proches mais pas identiques (#b8862e vs --gold #a5761f, etc.), une
# incoherence visible pour qui passe de l'une a l'autre.
_SHARED_STYLE = (
    ":root{--ink:#16171c;--ink-muted:#6b6f7b;--gold:#a5761f;--gold-light:#c9973a;"
    "--bg:#f7f6f3;--card-border:rgba(20,20,25,.09);--radius:18px;--radius-sm:10px;"
    "--glow-gold:rgba(201,151,58,.4);--dark-muted:#a7a9b3}"
    "body{margin:0;background:var(--bg);color:var(--ink);font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif;line-height:1.65}"
    "h1,h2{font-family:'Fraunces',Georgia,serif}"
    "header{background:#fff;border-bottom:1px solid var(--card-border);padding:16px}"
    "header .in{max-width:960px;margin:0 auto;display:flex;flex-wrap:wrap;justify-content:space-between;align-items:center;gap:10px}"
    "header a.brand{color:var(--ink);font-weight:800;text-decoration:none;font-size:1.05rem}"
    "nav.topnav{display:flex;flex-wrap:wrap;gap:14px}"
    "nav.topnav a{color:var(--ink-muted);text-decoration:none;font-size:13.5px}"
    "nav.topnav a:hover{color:var(--gold)}"
    ".page-hero{position:relative;background:var(--ink);overflow:hidden;padding:38px 16px 34px;text-align:center}"
    ".page-hero-glow{position:absolute;top:-170px;left:50%;transform:translateX(-50%);width:640px;height:340px;"
    "background:radial-gradient(circle,var(--glow-gold) 0%,rgba(165,118,31,0) 70%);pointer-events:none}"
    ".page-hero-in{position:relative;max-width:760px;margin:0 auto}"
    ".page-hero h1{color:#fff;font-size:1.9rem;margin:0 0 8px}"
    ".page-hero p.u{color:var(--dark-muted);margin:0}"
    "main{max-width:960px;margin:32px auto;padding:0 16px}"
    "article{background:#fff;border:1px solid var(--card-border);border-radius:var(--radius);padding:28px}"
    "h1{font-size:1.7rem;margin:0 0 6px}"
    "h2{font-size:1.15rem;margin:26px 0 8px;border-left:4px solid var(--gold);padding-left:10px}"
    "h3{font-size:1rem;margin:18px 0 6px}"
    "a{color:var(--gold)}"
    ".u{color:var(--ink-muted)}"
    "footer{text-align:center;color:var(--ink-muted);padding:24px;font-size:13px}"
    "footer nav{display:flex;flex-wrap:wrap;justify-content:center;gap:12px;margin-bottom:10px}"
    ".cta-row{display:flex;flex-wrap:wrap;gap:12px;margin-top:22px}"
    ".btn{display:inline-block;padding:10px 18px;border-radius:999px;text-decoration:none;font-weight:700;font-size:13.5px;"
    "transition:transform .15s ease,box-shadow .15s ease,color .15s ease,border-color .15s ease}"
    ".btn-gold{background:linear-gradient(135deg,var(--gold-light),var(--gold));color:#fff;box-shadow:0 4px 14px rgba(165,118,31,.28)}"
    ".btn-gold:hover{transform:translateY(-2px);box-shadow:0 8px 22px rgba(165,118,31,.38)}"
    ".btn-ghost{border:1px solid var(--card-border);color:var(--ink)}"
    ".btn-ghost:hover{border-color:var(--gold);color:var(--gold);transform:translateY(-2px)}"
    "nav.topnav a{transition:color .15s ease}"
    "footer nav a{transition:color .15s ease}"
    ".worker-list{display:grid;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));gap:16px;margin-top:18px}"
    ".worker-card{background:#14151a;border-radius:var(--radius-sm);overflow:hidden;color:#fff;"
    "transition:transform .15s ease,box-shadow .15s ease}"
    ".worker-card:hover{transform:translateY(-3px);box-shadow:0 10px 28px rgba(20,20,25,.22)}"
    ".worker-card .portrait{width:100%;aspect-ratio:4/5;object-fit:cover;display:block;background:#22242c}"
    ".worker-card .body{padding:12px 14px 14px}"
    ".worker-card .name{font-weight:800;font-size:1.02rem}"
    ".worker-card .cat{color:var(--gold-light);font-size:12.5px;font-weight:700;margin:2px 0 6px}"
    ".worker-card .role{color:#c7c9cf;font-size:13px}"
    ".plans-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));gap:16px;margin-top:18px}"
    ".plan-card{border:1px solid var(--card-border);border-radius:var(--radius-sm);padding:18px;"
    "transition:transform .15s ease,box-shadow .15s ease}"
    ".plan-card:hover{transform:translateY(-3px);box-shadow:0 10px 24px rgba(20,20,25,.08)}"
    ".plan-card.popular{border-color:var(--gold);box-shadow:0 0 0 2px rgba(165,118,31,.15)}"
    ".plan-card .pname{font-weight:800;font-size:1.1rem}"
    ".plan-card .paud{color:var(--ink-muted);font-size:12.5px;margin-bottom:10px}"
    ".plan-card .pprice{font-size:1.6rem;font-weight:800}"
    ".plan-card .pprice span{font-size:.9rem;font-weight:400;color:var(--ink-muted)}"
    ".plan-card ul{padding-left:18px;margin:12px 0 0;font-size:13px;color:var(--ink-muted)}"
    "details.faq-item{border:1px solid var(--card-border);border-radius:var(--radius-sm);padding:12px 16px;margin-bottom:10px}"
    "details.faq-item summary{font-weight:700;cursor:pointer}"
    "details.faq-item p{margin:10px 0 0;color:var(--ink-muted);font-size:14px}"
    "a:focus-visible,button:focus-visible,summary:focus-visible{outline:2px solid var(--gold);outline-offset:2px}"
)


def _head(title, description, canonical_path):
    return (
        "<!DOCTYPE html>\n"
        '<html lang="fr"><head><meta charset="UTF-8">'
        '<meta name="viewport" content="width=device-width, initial-scale=1.0">'
        f"<title>{title}</title>\n"
        f'<meta name="description" content="{description}">\n'
        f'<link rel="canonical" href="https://bk-ai-workers.com{canonical_path}">\n'
        '<meta name="theme-color" content="#14151a">\n'
        '<meta property="og:type" content="website"><meta property="og:site_name" content="BK-AI-WORKERS">\n'
        f'<meta property="og:title" content="{title}"><meta property="og:description" content="{description}">\n'
        f'<meta property="og:url" content="https://bk-ai-workers.com{canonical_path}">\n'
        '<meta property="og:image" content="https://bk-ai-workers.com/portraits/chloe.jpg">\n'
        '<meta name="twitter:card" content="summary_large_image">\n'
        '<link rel="icon" type="image/svg+xml" href="/favicon.svg">\n'
        '<link rel="apple-touch-icon" href="/favicon.svg">\n'
        '<link rel="preconnect" href="https://fonts.googleapis.com">\n'
        '<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>\n'
        '<link href="https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,500;9..144,600&display=swap" rel="stylesheet">\n'
        f"<style>{_SHARED_STYLE}</style>\n"
        "</head><body>"
    )


def _header():
    links = "".join(f'<a href="{href}">{label}</a>' for href, label in NAV_LINKS[1:])
    return (
        '<header><div class="in">'
        '<a class="brand" href="/">BK-AI-WORKERS</a>'
        f'<nav class="topnav">{links}</nav>'
        '<button id="lang-toggle" type="button" data-no-i18n="1" style="margin-left:12px;background:none;border:1px solid rgba(255,255,255,.35);'
        'color:#fff;border-radius:999px;padding:4px 11px;font:600 12px inherit;cursor:pointer">EN</button>'
        "</div></header>"
    )


def _footer():
    links = "".join(f'<a href="{href}">{label}</a>' for href, label in NAV_LINKS + FOOTER_TRUST_LINKS)
    return (
        "<footer>"
        f"<nav>{links}</nav>"
        "© 2026 BK-ENTREPRISE — BK-AI-WORKERS"
        "</footer>"
    )


# Chaque render_* passe un body_html qui commence par <h1>...</h1> puis,
# souvent, un <p class="u">...</p> de sous-titre : on les detache pour
# les afficher dans une bande sombre premium (meme traitement que le
# .page-band de l'app interactive), sans devoir reecrire chaque fonction
# render_* individuellement.
_HERO_RE = re.compile(r'\s*(<h1>.*?</h1>)\s*(<p class="u">.*?</p>)?', re.S)


def _page(title, description, canonical_path, body_html, extra_scripts=""):
    hero_html = ""
    rest = body_html
    m = _HERO_RE.match(body_html)
    if m:
        hero_html = (
            '<div class="page-hero"><div class="page-hero-glow"></div>'
            f'<div class="page-hero-in">{m.group(1)}{m.group(2) or ""}</div></div>'
        )
        rest = body_html[m.end():]
    return (
        _head(title, description, canonical_path)
        + _header()
        + hero_html
        + f"<main><article>{rest}</article></main>"
        + _footer()
        + '<script src="/particles.js" defer></script>'
        + '<script src="/i18n-en.js"></script><script src="/i18n-en-legal.js"></script><script src="/i18n.js"></script>'
        + extra_scripts
        + "</body></html>"
    )


def render_workers_page(workers):
    """workers : liste de dicts issus de build_worker_summary() — memes
    donnees reelles que /api/workers, jamais un doublon invente."""
    cards = "".join(
        f'<div class="worker-card"><img class="portrait" src="{w["portraitUrl"]}" alt="{w["name"]}" loading="lazy">'
        f'<div class="body"><div class="name">{w["name"]}</div>'
        f'<div class="cat">{w["category"]}</div>'
        f'<div class="role">{w["role"]}</div></div></div>'
        for w in workers
    )
    body = f"""
      <h1>Les {len(workers)} Workers de BK-AI-WORKERS</h1>
      <p class="u">Un agent IA spécialisé par métier, orchestré par Chloé.</p>
      <p>Chaque Worker est un agent IA entraîné pour un métier précis — prospection, contenu, design,
      développement web, SEO, automatisation, administration, RH, gestion de projet, IT, support,
      finance, data, juridique, veille, e-commerce. Vous décrivez votre objectif à Chloé, l'agent
      orchestrateur ; elle compose l'équipe de Workers pertinente et coordonne leur travail jusqu'au
      résultat.</p>
      <div class="worker-list">{cards}</div>
      <div class="cta-row">
        <a class="btn btn-gold" href="/#nav-onboarding">Construire mon équipe</a>
        <a class="btn btn-ghost" href="/tarifs.html">Voir les tarifs</a>
      </div>
    """
    return _page(
        "Workers IA — 17 agents spécialisés | BK-AI-WORKERS",
        "Découvrez les 17 Workers IA de BK-AI-WORKERS : prospection, contenu, design, développement, "
        "SEO, automatisation, RH, finance, support et plus — orchestrés par Chloé.",
        "/workers.html",
        body,
    )


PRICING_PLANS = [
    {"name": "Essai", "audience": "Pour tester sans risque", "price": "0", "period": "3 jours",
     "features": ["Crédits d'essai limités", "Missions limitées", "Quelques Workers", "Aucune carte bancaire"]},
    {"name": "Starter", "audience": "Indépendants & petites structures", "price": "39", "annual": "390", "period": "/mois",
     "features": ["Chloé + Workers essentiels", "Missions individuelles", "Mémoire de base", "Historique des missions", "Support standard"]},
    {"name": "Business", "audience": "PME", "price": "99", "annual": "990", "period": "/mois", "popular": True,
     "features": ["Tout Starter", "Équipe de Workers", "Missions multi-agents", "Automatisations", "Rapports & support prioritaire"]},
    {"name": "Pro", "audience": "Entreprises, usage régulier", "price": "139", "annual": "1390", "period": "/mois",
     "features": ["Tout Business", "Équipes avancées", "Missions complexes", "Quotas supérieurs", "Analytics & contrôles avancés"]},
    {"name": "Scale", "audience": "Entreprises, volume important", "price": "449", "annual": "4490", "period": "/mois",
     "features": ["Tout Pro", "Capacité supérieure", "Équipes multiples", "Gouvernance avancée", "Accompagnement renforcé"]},
    {"name": "Enterprise", "audience": "Grands comptes, besoins spécifiques", "price": None, "period": "Sur devis",
     "features": ["Intégrations métier", "Gouvernance avancée", "Déploiement personnalisé", "Exigences contractuelles & conformité"]},
]


def render_tarifs_page():
    cards = ""
    for p in PRICING_PLANS:
        price_html = (
            f'<div class="pprice">{p["price"]} CHF <span>{p["period"]}</span></div>'
            if p["price"] is not None else f'<div class="pprice">{p["period"]}</div>'
        )
        annual = f'<div class="u" style="font-size:12px;">{p["annual"]} CHF/an</div>' if p.get("annual") else ""
        feats = "".join(f"<li>{f}</li>" for f in p["features"])
        cards += (
            f'<div class="plan-card{" popular" if p.get("popular") else ""}">'
            f'<div class="pname">{p["name"]}</div><div class="paud">{p["audience"]}</div>'
            f"{price_html}{annual}<ul>{feats}</ul></div>"
        )
    body = f"""
      <h1>Tarifs BK-AI-WORKERS</h1>
      <p class="u">Des plans par crédits — 1 mission réellement traitée = 1 crédit consommé.</p>
      <p>Essai gratuit de 3 jours sans carte bancaire. Changement de plan, recharge de crédits et
      annulation possibles à tout moment depuis votre compte, sans engagement minimum. Prix en CHF (devise de facturation), hors taxes.
      Disponible dans le monde entier.</p>
      <div class="plans-grid">{cards}</div>
      <div class="cta-row">
        <a class="btn btn-gold" href="/#nav-onboarding">Démarrer l'essai gratuit</a>
        <a class="btn btn-ghost" href="/cgv.html">Voir les CGV</a>
      </div>
    """
    return _page(
        "Tarifs — Plans Essai, Starter, Business, Pro, Scale, Enterprise | BK-AI-WORKERS",
        "Tarifs BK-AI-WORKERS : essai gratuit 3 jours, puis plans Starter (39 CHF), "
        "Business (99 CHF), Pro (139 CHF), Scale (449 CHF) ou Enterprise sur devis.",
        "/tarifs.html",
        body,
    )


FAQ_ITEMS = [
    ("Un Worker peut-il vraiment envoyer un email ou publier à ma place ?",
     "Un Worker prépare toujours le travail (texte, analyse, brouillon) avec une vraie IA. La diffusion "
     "réelle vers un outil externe (envoi d'email, publication, mise à jour CRM) n'a lieu que pour les "
     "outils que vous connectez vous-même à votre compte — tant qu'un outil n'est pas connecté, son "
     "résultat reste une préparation, jamais un envoi. Le paiement de votre abonnement, lui, est traité "
     "réellement par Stripe dès la souscription."),
    ("Un Worker peut-il envoyer un email ou publier quelque chose sans mon accord ?",
     "Non. Toute action sensible (envoi, publication, suppression, exécution) passe systématiquement par "
     "une vérification de Chloé avant d'avoir lieu — jamais directement depuis la fiche d'un Worker. "
     "C'est une règle appliquée au niveau du code, pas juste une bonne intention."),
    ("Comment les Workers se connectent-ils à mes outils (Slack, CRM, etc.) ?",
     "Chaque connexion se fait avec votre propre compte (« Se connecter avec Google », Microsoft…), et vos accès sont stockés chiffrés — jamais "
     "vus en clair, jamais partagés entre plusieurs comptes. Rien n'est connecté par défaut : vous "
     "choisissez quels outils brancher, et quand."),
    ("Comment fonctionne la facturation ?",
     "Chaque plan inclut un quota de crédits par cycle (1 mission réellement traitée = 1 crédit consommé). "
     "La consommation est visible en temps réel, une alerte apparaît à 80% du quota, et aucune facturation "
     "supplémentaire automatique n'a lieu si vous dépassez — une recharge reste toujours volontaire, "
     "jamais imposée."),
    ("Où sont stockées mes données ?",
     "Les missions, l'historique et les identifiants restent sur l'infrastructure du produit — pas "
     "partagés avec des tiers en dehors des outils que vous connectez vous-même. Voir la page "
     "Confidentialité pour le détail."),
    ("Puis-je changer ou annuler mon plan à tout moment ?",
     "Oui, depuis la page Facturation — changement de plan, recharge de crédits et annulation sont "
     "accessibles à tout moment, sans engagement minimum."),
]


def render_faq_page():
    items = "".join(f"<details class='faq-item'><summary>{q}</summary><p>{a}</p></details>" for q, a in FAQ_ITEMS)
    body = f"""
      <h1>Questions fréquentes</h1>
      <p class="u">Comment ça marche, concrètement — sans jargon.</p>
      {items}
      <div class="cta-row">
        <a class="btn btn-gold" href="/#nav-onboarding">Démarrer</a>
        <a class="btn btn-ghost" href="/confidentialite.html">Voir la confidentialité</a>
      </div>
    """
    return _page(
        "FAQ — Questions fréquentes | BK-AI-WORKERS",
        "Réponses aux questions fréquentes sur BK-AI-WORKERS : sécurité, connexion de vos outils, "
        "facturation, stockage des données, gestion de votre abonnement.",
        "/faq.html",
        body,
    )


def render_cgv_page():
    body = """
      <h1>Conditions générales de vente</h1>
      <p class="u">Dernière mise à jour : 21 septembre 2026</p>
      <h3>1. Éditeur et champ d'application</h3>
      <p>Les présentes conditions générales de vente (CGV) régissent l'accès et l'utilisation de la plateforme BK-AI-WORKERS, éditée par <strong>BK-ENTREPRISE</strong> (entreprise individuelle, activité entièrement en ligne), Rue Joseph-Pasquier 1, 1203 Genève, Suisse. Elles s'appliquent à tout client professionnel (entreprise, indépendant) qui souscrit un plan. Le service est destiné aux professionnels ; il n'est pas proposé aux consommateurs.</p>
      <h3>2. Description du service</h3>
      <p>BK-AI-WORKERS met à disposition Chloé, agent orchestrateur, et une équipe d'agents IA spécialisés (les « Workers ») qui préparent des livrables métier (textes, analyses, plans, brouillons). Les Workers <strong>préparent</strong> ; ils n'exécutent aucune action à risque (envoi, publication, suppression, paiement) sans validation explicite du client. La diffusion réelle d'un livrable vers un outil externe (email, réseau social, CRM...) nécessite que le client connecte lui-même cet outil à son compte ; sans cette connexion, le résultat reste une préparation. Le paiement de l'abonnement, lui, est traité réellement dès la souscription (voir article 5).</p>
      <h3>3. Essai gratuit</h3>
      <p>Le plan Essai est gratuit, sans carte bancaire, limité à 3 jours et à un quota de crédits. À son terme, aucun prélèvement n'a lieu : le client choisit librement de souscrire un plan payant ou d'arrêter.</p>
      <h3>4. Plans, crédits et prix</h3>
      <p>Les plans, prix et quotas de crédits sont ceux affichés sur la page Tarifs au moment de la souscription, en francs suisses (CHF), hors taxes le cas échéant. Une mission consomme des crédits ; un crédit non utilisé à la fin de la période de facturation n'est pas reporté, sauf mention contraire sur la page Tarifs. Le client peut recharger des crédits à tout moment. BK-ENTREPRISE n'étant pas assujettie à la TVA en dessous du seuil légal suisse (CHF 100'000 de chiffre d'affaires annuel), aucune TVA n'est facturée à ce jour ; ce point sera mis à jour ici en cas d'assujettissement.</p>
      <h3>5. Paiement</h3>
      <p>Le paiement est dû d'avance, par carte bancaire via notre prestataire de paiement Stripe. BK-ENTREPRISE ne voit ni ne conserve les données de carte. En cas d'échec de paiement, l'accès aux fonctions payantes peut être suspendu jusqu'à régularisation.</p>
      <h3>6. Durée, renouvellement et résiliation</h3>
      <p>Les abonnements sont mensuels et se renouvellent automatiquement pour une période équivalente. Le client peut résilier à tout moment depuis la page Facturation, avec effet à la fin de la période en cours : la période déjà payée reste due et n'est pas remboursée au prorata. Aucune pénalité de sortie n'est appliquée.</p>
      <h3>7. Remboursement</h3>
      <p>Sauf disposition légale impérative, les sommes versées ne sont pas remboursables. En cas de défaut avéré du service imputable à BK-ENTREPRISE (indisponibilité prolongée, erreur de facturation), le client peut adresser une demande motivée à contact@bk-entreprise.com ; elle est examinée au cas par cas, sous 10 jours ouvrables.</p>
      <h3>8. Modification des prix et des CGV</h3>
      <p>BK-ENTREPRISE peut modifier ses prix et les présentes CGV. Toute modification est communiquée au client au moins 30 jours à l'avance et ne s'applique qu'au renouvellement suivant ; le client peut résilier avant son entrée en vigueur. Les prix d'un abonnement en cours ne sont pas augmentés en cours de période.</p>
      <h3>9. Utilisation acceptable</h3>
      <p>Le client s'engage à utiliser le service conformément au droit applicable, à fournir des informations exactes, à ne pas partager ses accès, et à ne pas utiliser les Workers pour des contenus illicites, trompeurs, discriminatoires ou portant atteinte aux droits de tiers, ni pour du spam. Toute revente ou sous-licence du service est interdite sans accord écrit.</p>
      <h3>10. Résultats produits par l'IA</h3>
      <p>Les réponses sont générées par des modèles d'intelligence artificielle et peuvent contenir des erreurs ou des approximations. Le client est seul responsable de la vérification et de l'usage des résultats avant toute action réelle, en particulier pour les décisions financières, juridiques, fiscales, médicales ou de communication externe. Les Workers ne remplacent pas un conseil professionnel. Le client conserve la propriété des contenus qu'il fournit et des livrables qu'il obtient.</p>
      <h3>11. Responsabilité</h3>
      <p>BK-ENTREPRISE fournit le service avec la diligence requise mais ne garantit ni un résultat commercial ou financier, ni une disponibilité ininterrompue. Dans les limites permises par le droit suisse, sa responsabilité est exclue pour les dommages indirects (perte de revenus, de données, d'opportunités) et, pour les autres dommages, limitée aux montants payés par le client au cours des 12 derniers mois. La responsabilité en cas d'intention ou de négligence grave demeure réservée (art. 100 CO).</p>
      <h3>12. Suspension</h3>
      <p>BK-ENTREPRISE peut suspendre ou résilier l'accès en cas de non-paiement, de violation des présentes CGV ou d'usage illicite, après information du client lorsque les circonstances le permettent.</p>
      <h3>13. Support et maintenance</h3>
      <p>Le support est assuré par courriel à contact@bk-entreprise.com, en jours ouvrables. Des opérations de maintenance peuvent entraîner des interruptions brèves ; elles sont annoncées lorsque c'est possible.</p>
      <h3>14. Force majeure</h3>
      <p>Aucune partie n'est responsable d'un manquement causé par un cas de force majeure (panne d'un fournisseur d'infrastructure ou d'IA, cyberattaque, événement naturel, décision d'autorité). Si l'événement dure plus de trois mois, chaque partie peut résilier sans pénalité.</p>
      <h3>15. Protection des données</h3>
      <p>Le traitement des données est décrit sur la page <a href="/confidentialite.html">Confidentialité</a>, qui fait partie intégrante des présentes CGV.</p>
      <h3>16. Droit applicable et for</h3>
      <p>Les présentes CGV sont soumises au droit suisse, à l'exclusion des règles de conflit de lois. Le for exclusif est Genève, Suisse. Si une clause est invalide, les autres restent applicables.</p>
    """
    return _page(
        "Conditions générales de vente (CGV) | BK-AI-WORKERS",
        "Conditions générales de vente de BK-AI-WORKERS, édité par BK-ENTREPRISE (Genève, Suisse) : "
        "essai gratuit, plans, paiement, résiliation, responsabilité, droit suisse.",
        "/cgv.html",
        body,
    )


def render_mentions_page():
    body = """
      <h1>Mentions légales</h1>
      <ul>
        <li><strong>Éditeur :</strong> BK-ENTREPRISE — BK-AI-WORKERS est un produit exploité par BK-ENTREPRISE</li>
        <li><strong>Forme juridique :</strong> Entreprise individuelle (raison individuelle, activité 100% en ligne)</li>
        <li><strong>Siège :</strong> Rue Joseph-Pasquier 1, 1203 Genève, Suisse</li>
        <li><strong>Contact :</strong> contact@bk-entreprise.com — +41 79 934 99 46</li>
        <li><strong>Responsable de la publication :</strong> M. Christ Kader Berte, fondateur</li>
        <li><strong>Propriété intellectuelle :</strong> la plateforme, ses textes, visuels, portraits des Workers et sa marque sont la propriété exclusive de BK-ENTREPRISE ; toute reproduction sans autorisation écrite est interdite.</li>
      </ul>
      <h2>Hébergement</h2>
      <p>L'hébergement est assuré par OVHcloud (France).</p>
    """
    return _page(
        "Mentions légales | BK-AI-WORKERS",
        "Mentions légales de BK-AI-WORKERS, produit édité par BK-ENTREPRISE, Genève, Suisse.",
        "/mentions-legales.html",
        body,
    )


HOW_IT_WORKS_STEPS = [
    ("Vous décrivez la mission", "À Chloé ou directement à un Worker — pas de configuration, pas de script."),
    ("Le ou les Workers exécutent", "Chacun selon son rôle et les outils auxquels il a accès."),
    ("Chloé vérifie", "Avant tout envoi, publication ou suppression — automatiquement."),
    ("Vous validez le financier", "Seuls les paiements et transactions vous reviennent directement."),
]


def render_demarrer_page():
    steps = "".join(
        f'<div class="worker-card"><div class="name">{i}. {t}</div><div class="role">{d}</div></div>'
        for i, (t, d) in enumerate(HOW_IT_WORKS_STEPS, 1)
    )
    body = f"""
      <h1>Démarrer avec BK-AI-WORKERS</h1>
      <p class="u">De l'objectif au résultat, en quatre temps.</p>
      <p>Aucune configuration technique, aucun script à écrire. Vous décrivez ce que vous voulez
      accomplir dans vos mots — Chloé, l'agent orchestrateur, compose l'équipe de Workers pertinente
      et coordonne leur travail jusqu'au résultat.</p>
      <div class="worker-list">{steps}</div>
      <h2>Essai gratuit, sans carte bancaire</h2>
      <p>Le plan Essai est gratuit, limité à 3 jours et à un quota de crédits. À son terme, aucun
      prélèvement n'a lieu : vous choisissez librement de souscrire un plan payant ou d'arrêter.</p>
      <div class="cta-row">
        <a class="btn btn-gold" href="/#nav-onboarding">Démarrer l'essai gratuit</a>
        <a class="btn btn-ghost" href="/workers.html">Découvrir les Workers</a>
      </div>
    """
    return _page(
        "Démarrer — Comment ça marche | BK-AI-WORKERS",
        "Comment démarrer avec BK-AI-WORKERS : décrivez votre objectif, Chloé compose l'équipe de "
        "Workers, ils exécutent, elle vérifie avant tout envoi. Essai gratuit 3 jours sans carte.",
        "/demarrer.html",
        body,
    )


def render_chloe_page():
    body = """
      <h1>Chloé — l'agent orchestrateur</h1>
      <p class="u">Interface principale & orchestration de l'équipe de Workers.</p>
      <p>Chloé est l'agent que vous rencontrez en premier : vous lui confiez un objectif, dans vos
      mots, et elle traduit ce besoin en mission concrète. Elle choisit les Workers pertinents parmi
      les 17 profils spécialisés, distribue le travail, puis contrôle systématiquement le résultat
      avant qu'il ne vous parvienne — aucun envoi, publication ou suppression n'a lieu sans être
      passé par cette vérification.</p>
      <h2>Ce qu'elle ne fait jamais</h2>
      <p>Chloé ne prétend jamais avoir un accès direct à une donnée qu'elle n'a pas réellement sous
      les yeux. Les décisions financières (paiements, transactions) reviennent toujours directement
      à vous, jamais à elle ni à un Worker.</p>
      <div class="cta-row">
        <a class="btn btn-gold" href="/#nav-onboarding">Confier un objectif à Chloé</a>
        <a class="btn btn-ghost" href="/workers.html">Voir les 17 Workers</a>
      </div>
    """
    return _page(
        "Chloé — Agent orchestrateur | BK-AI-WORKERS",
        "Chloé compose votre équipe de Workers IA à partir de votre objectif, coordonne leur travail "
        "et vérifie chaque résultat avant tout envoi, publication ou suppression réelle.",
        "/chloe.html",
        body,
    )


def render_automatisations_page():
    body = """
      <h1>Automatisations</h1>
      <p class="u">Des missions récurrentes, planifiées, sans intervention manuelle répétée.</p>
      <p>Une automatisation confie à un Worker précis un objectif fixe, exécuté selon une fréquence
      que vous choisissez (par exemple toutes les heures, tous les jours, toutes les semaines ou tous
      les mois). Chaque passage est journalisé — statut et résultat réel, jamais un résumé inventé.</p>
      <h2>Notification Slack en option</h2>
      <p>Si vous connectez votre propre Slack et activez la notification sur une automatisation, un
      message réel résumant la mission (Worker, objectif, statut, extrait du résultat) est posté dans
      votre canal à chaque exécution.</p>
      <h2>Comme le reste de la plateforme</h2>
      <p>Une automatisation reste soumise aux mêmes règles que toute mission : les actions sensibles
      passent par la vérification de Chloé avant d'avoir lieu.</p>
      <div class="cta-row">
        <a class="btn btn-gold" href="/#nav-onboarding">Créer ma première automatisation</a>
        <a class="btn btn-ghost" href="/analytics.html">Voir l'Analytics</a>
      </div>
    """
    return _page(
        "Automatisations — Missions récurrentes | BK-AI-WORKERS",
        "Planifiez des missions récurrentes confiées à un Worker précis, avec notification Slack "
        "optionnelle et le même contrôle de sécurité que toute mission BK-AI-WORKERS.",
        "/automatisations.html",
        body,
    )


def render_analytics_page():
    body = """
      <h1>Analytics</h1>
      <p class="u">Le suivi réel de votre activité — pas d'avis fabriqués, pas de chiffres inventés.</p>
      <p>Votre tableau de bord Analytics agrège les vraies données d'usage de votre compte : nombre
      de missions traitées, répartition par statut, Workers les plus sollicités, automatisations
      actives, et une estimation prudente du temps gagné (explicitement identifiée comme estimation,
      jamais présentée comme une mesure).</p>
      <h2>Propre à votre compte</h2>
      <p>Ces données ne concernent que vos propres missions — jamais mélangées avec celles d'un autre
      compte. Elles sont accessibles une fois connecté, depuis votre tableau de bord.</p>
      <div class="cta-row">
        <a class="btn btn-gold" href="/#nav-onboarding">Voir mon Analytics</a>
        <a class="btn btn-ghost" href="/automatisations.html">Découvrir les automatisations</a>
      </div>
    """
    return _page(
        "Analytics — Suivi réel de votre activité | BK-AI-WORKERS",
        "Suivez vos missions réelles, la répartition par Worker et par statut, et une estimation "
        "prudente du temps gagné — propre à votre compte BK-AI-WORKERS.",
        "/analytics.html",
        body,
    )


def render_facturation_page():
    body = """
      <h1>Facturation</h1>
      <p class="u">Des crédits, un usage transparent, aucun engagement forcé.</p>
      <p>Chaque plan inclut un quota de crédits par cycle — une mission réellement traitée consomme
      un crédit. Votre consommation est visible en temps réel depuis votre compte, une alerte apparaît
      à 80% du quota, et aucune facturation supplémentaire automatique n'a lieu si vous dépassez :
      une recharge reste toujours volontaire, jamais imposée.</p>
      <h2>Paiement</h2>
      <p>Le paiement est traité par carte bancaire via Stripe, dû d'avance. BK-ENTREPRISE ne voit ni
      ne conserve les données de carte.</p>
      <h2>Changement et résiliation</h2>
      <p>Changement de plan, recharge de crédits et annulation sont accessibles à tout moment depuis
      votre compte, sans engagement minimum ni pénalité de sortie. Voir le détail complet dans les
      <a href="/cgv.html">CGV</a>.</p>
      <div class="cta-row">
        <a class="btn btn-gold" href="/tarifs.html">Voir les plans</a>
        <a class="btn btn-ghost" href="/cgv.html">Lire les CGV</a>
      </div>
    """
    return _page(
        "Facturation — Crédits & paiement | BK-AI-WORKERS",
        "Comment fonctionne la facturation BK-AI-WORKERS : crédits par cycle, paiement Stripe, "
        "changement de plan et annulation à tout moment, sans engagement.",
        "/facturation.html",
        body,
    )


def render_cookies_page():
    body = """
      <h1>Cookies</h1>
      <p>La plateforme n'utilise que des cookies techniques strictement nécessaires (session de connexion) et un stockage local du navigateur pour mémoriser votre langue. Aucun cookie publicitaire ni de suivi n'est utilisé : aucun consentement n'est donc requis.</p>
    """
    return _page(
        "Cookies | BK-AI-WORKERS",
        "Politique de cookies de BK-AI-WORKERS : uniquement des cookies techniques nécessaires, aucun cookie publicitaire.",
        "/cookies.html",
        body,
    )
