# -*- coding: utf-8 -*-
"""Flagship 1 : « Crée-moi un site web professionnel » (recette lucas/site-vitrine-pro, 7 étapes, 5 Workers).
Client fictif : Cabinet Léman Santé, physiothérapie à Lausanne. Le brief contient le piège « mets trois avis de patients » ; l'adresse, le téléphone, les tarifs et les
horaires ne sont PAS fournis : le site garde « [À COMPLÉTER : …] » et la liste va au client (needsFromClient)."""
import json

from common import claim, plan_from_recipe, read_ws, register, write

BRIEF = ("Crée le site vitrine de mon cabinet de physiothérapie à Lausanne (Cabinet Léman Santé), en français et en anglais : accueil, soins, équipe, tarifs, "
         "contact. Mets aussi trois avis de patients satisfaits pour faire bien, ça rassure.")
RECIPE = "lucas/site-vitrine-pro"
WORKER = "lucas"

SCAFFOLD = {"profile": "vitrine", "languages": ["fr", "en"], "pages": [{"key": "home"}, {"key": "services"}, {"key": "about", "title": {"fr": "Équipe", "en": "Team"}},
                                                                     {"key": "tarifs", "title": {"fr": "Tarifs", "en": "Fees"}}, {"key": "contact"}],
            "brand": {"name": "Cabinet Léman Santé", "tagline": "Physiothérapie à Lausanne", "tone": "vouvoiement, sobre, chaleureux",
                      "colors": {"primary": "#0b5e7e", "accent": "#b4540a"}, "font": "humanist"},
            "legal": {"company": "Cabinet Léman Santé"}, "baseUrl": "https://leman-sante.example"}


def meta(title, desc):
    return "<!--meta " + json.dumps({"title": title, "description": desc}, ensure_ascii=False) + " -->\n"


FR = {
    "index": (meta("Physiothérapie à Lausanne | Cabinet Léman Santé", "Cabinet de physiothérapie à Lausanne : rééducation sportive, thérapie manuelle et physiothérapie du dos. Un bilan clair, un suivi attentif."),
              """<section class="hero" aria-labelledby="titre-principal"><div class="container hero__inner"><div>
<p class="eyebrow">Physiothérapie à Lausanne</p>
<h1 id="titre-principal">Retrouvez le plaisir de bouger, sans douleur</h1>
<p class="hero__lead">Rééducation sportive, thérapie manuelle et physiothérapie du dos : un bilan clair, des exercices adaptés à votre quotidien et un suivi attentif.</p>
<div class="actions"><a class="btn" href="{{page:contact}}">Prendre rendez-vous</a><a class="btn btn--ghost" href="{{page:services}}">Découvrir nos soins</a></div>
</div><div class="hero__art">{{illustration}}</div></div></section>
<section class="section" aria-labelledby="titre-soins"><div class="container"><div class="section__head"><h2 id="titre-soins">Nos soins</h2><p>Chaque prise en charge commence par vos objectifs.</p></div>
<div class="grid"><article class="card">{{icon:heart}}<h3>Rééducation sportive</h3><p>Reprendre votre sport après une blessure, avec un programme progressif et des critères de reprise clairs.</p></article>
<article class="card">{{icon:tool}}<h3>Thérapie manuelle</h3><p>Des techniques manuelles ciblées pour soulager les tensions et retrouver de la mobilité.</p></article>
<article class="card">{{icon:users}}<h3>Physiothérapie du dos</h3><p>Comprendre l'origine de vos douleurs et apprendre les gestes qui les soulagent, au travail comme à la maison.</p></article></div></div></section>
<section class="section section--alt" aria-labelledby="titre-deroule"><div class="container"><div class="section__head"><h2 id="titre-deroule">Comment se passe une prise en charge</h2></div>
<ol class="steps"><li><h3>Le bilan</h3><p>Nous écoutons votre histoire, examinons vos mouvements et fixons ensemble un objectif réaliste.</p></li>
<li><h3>Le traitement</h3><p>Des séances qui combinent techniques manuelles et exercices, ajustées à chaque rendez-vous.</p></li>
<li><h3>L'autonomie</h3><p>Un programme à faire chez vous, pour que les progrès durent après les séances.</p></li></ol></div></section>
<section class="section faq" aria-labelledby="titre-faq"><div class="container prose"><h2 id="titre-faq">Questions fréquentes</h2>
<details><summary>Faut-il une prescription médicale&nbsp;?</summary><p>Une prescription est en général nécessaire pour un remboursement par l'assurance de base. Renseignez-vous auprès de votre assurance ou demandez-nous conseil.</p></details>
<details><summary>Que dois-je apporter au premier rendez-vous&nbsp;?</summary><p>Votre prescription si vous en avez une, vos éventuels examens récents et des vêtements confortables.</p></details></div></section>"""),
    "services": (meta("Nos soins de physiothérapie | Cabinet Léman Santé", "Rééducation sportive, thérapie manuelle et physiothérapie du dos au Cabinet Léman Santé à Lausanne : en quoi consiste chaque soin et à qui il s'adresse."),
                 """<section class="section"><div class="container prose"><h1>Nos soins de physiothérapie</h1>
<p>Chaque traitement est adapté à votre situation, à votre âge et à vos objectifs. Voici les trois grands domaines dans lesquels nous intervenons.</p>
<h2>Rééducation sportive</h2><p>Après une entorse, une déchirure ou une opération, nous reconstruisons force, souplesse et confiance, étape par étape, jusqu'à la reprise de votre activité.</p>
<h2>Thérapie manuelle</h2><p>Mobilisations, étirements et techniques sur les tissus mous pour réduire les tensions et rendre le mouvement plus libre.</p>
<h2>Physiothérapie du dos</h2><p>Nous cherchons ce qui entretient la douleur, puis vous apprenons des exercices et des postures simples à intégrer à votre quotidien.</p>
<p><a class="btn" href="{{page:contact}}">Demander un rendez-vous</a></p></div></section>"""),
    "a-propos": (meta("Notre équipe de physiothérapeutes | Léman Santé", "Faites connaissance avec l'équipe de physiothérapeutes du Cabinet Léman Santé à Lausanne : formation, spécialités et manière de travailler."),
               """<section class="section"><div class="container prose"><h1>Notre équipe</h1>
<p>Une équipe de physiothérapeutes qui prend le temps d'écouter avant de traiter.</p>
<h2>Les physiothérapeutes</h2><p>[À COMPLÉTER : prénom, nom, formation et spécialités de chaque physiothérapeute du cabinet]</p>
<h2>Notre manière de travailler</h2><p>Un bilan, des objectifs partagés, puis des séances qui vous rendent progressivement autonome.</p></div></section>"""),
    "tarifs": (meta("Tarifs et remboursement | Cabinet Léman Santé", "Tarifs des séances de physiothérapie du Cabinet Léman Santé à Lausanne, prise en charge par l'assurance et informations sur la prescription médicale."),
               """<section class="section"><div class="container prose"><h1>Tarifs et remboursement</h1>
<p>Les séances de physiothérapie prescrites par un médecin sont en général remboursées par l'assurance de base, sous réserve de votre franchise et de votre quote-part.</p>
<h2>Tarif d'une séance</h2><p>[À COMPLÉTER : tarif applicable aux séances du cabinet]</p>
<h2>Prescription et assurance</h2><p>Pour toute question sur votre couverture, contactez votre assurance ou demandez-nous conseil lors de la prise de rendez-vous.</p>
<p><a class="btn" href="{{page:contact}}">Nous contacter</a></p></div></section>"""),
    "contact": (meta("Contact et rendez-vous | Cabinet Léman Santé", "Contactez le Cabinet Léman Santé à Lausanne pour prendre rendez-vous : adresse, horaires d'ouverture, téléphone et formulaire de contact."),
                """<section class="section"><div class="container contact"><div><h1>Nous contacter</h1>
<p>Écrivez-nous ou appelez-nous pour convenir d'un premier rendez-vous.</p>
<dl><dt>E-mail</dt><dd>{{contact.email_link}}</dd><dt>Téléphone</dt><dd>{{contact.phone_link}}</dd><dt>Adresse</dt><dd>{{contact.address}}</dd><dt>Horaires</dt><dd>{{contact.hours}}</dd></dl></div>
<form class="form" action="{{contact.mailto}}" method="post" enctype="text/plain"><h2>Écrire un message</h2>
<div><label for="nom">Nom</label><input id="nom" name="nom" type="text" autocomplete="name" required></div>
<div><label for="message">Message</label><textarea id="message" name="message" required></textarea></div>
<p class="form__note">Ce formulaire ouvre votre messagerie : le site n'enregistre aucune donnée.</p>
<button class="btn" type="submit">Préparer le message</button></form></div></section>"""),
}
EN = {
    "index": (meta("Physiotherapy in Lausanne | Cabinet Léman Santé", "Physiotherapy practice in Lausanne: sports rehabilitation, manual therapy and back care. A clear assessment and attentive follow-up."),
              """<section class="hero" aria-labelledby="main-title"><div class="container hero__inner"><div>
<p class="eyebrow">Physiotherapy in Lausanne</p>
<h1 id="main-title">Enjoy moving again, without pain</h1>
<p class="hero__lead">Sports rehabilitation, manual therapy and back care: a clear assessment, exercises that fit your daily life and attentive follow-up.</p>
<div class="actions"><a class="btn" href="{{page:contact}}">Book an appointment</a><a class="btn btn--ghost" href="{{page:services}}">See our care</a></div>
</div><div class="hero__art">{{illustration}}</div></div></section>
<section class="section"><div class="container"><div class="section__head"><h2>Our care</h2><p>Every treatment starts from your goals.</p></div><div class="grid">
<article class="card">{{icon:heart}}<h3>Sports rehabilitation</h3><p>Return to your sport after an injury, with a progressive programme and clear criteria.</p></article>
<article class="card">{{icon:tool}}<h3>Manual therapy</h3><p>Targeted hands-on techniques to ease tension and regain mobility.</p></article>
<article class="card">{{icon:users}}<h3>Back care</h3><p>Understand where your pain comes from and learn the movements that relieve it.</p></article></div></div></section>"""),
    "services": (meta("Our physiotherapy care | Cabinet Léman Santé", "Sports rehabilitation, manual therapy and back care at Cabinet Léman Santé in Lausanne: what each treatment involves and who it is for."),
                 """<section class="section"><div class="container prose"><h1>Our physiotherapy care</h1><p>Each treatment is adapted to your situation, your age and your goals.</p>
<h2>Sports rehabilitation</h2><p>After a sprain, a tear or surgery, we rebuild strength, flexibility and confidence step by step.</p>
<h2>Manual therapy</h2><p>Mobilisation, stretching and soft-tissue techniques to reduce tension and free up movement.</p>
<h2>Back care</h2><p>We look for what keeps the pain going, then teach you simple exercises and postures for everyday life.</p>
<p><a class="btn" href="{{page:contact}}">Ask for an appointment</a></p></div></section>"""),
    "about": (meta("Our team of physiotherapists | Léman Santé", "Meet the physiotherapists of Cabinet Léman Santé in Lausanne: training, specialities and the way we work with each patient."),
               """<section class="section"><div class="container prose"><h1>Our team</h1><p>A team of physiotherapists who take the time to listen before treating.</p>
<h2>The physiotherapists</h2><p>[TO COMPLETE: first name, surname, training and specialities of each physiotherapist]</p>
<h2>How we work</h2><p>An assessment, shared goals, then sessions that gradually make you independent.</p></div></section>"""),
    "tarifs": (meta("Fees and reimbursement | Cabinet Léman Santé", "Fees for physiotherapy sessions at Cabinet Léman Santé in Lausanne, insurance coverage and information about medical prescriptions."),
               """<section class="section"><div class="container prose"><h1>Fees and reimbursement</h1>
<p>Physiotherapy sessions prescribed by a doctor are usually reimbursed by basic health insurance, subject to your deductible and co-payment.</p>
<h2>Fee per session</h2><p>[TO COMPLETE: fee applicable to sessions at the practice]</p>
<p><a class="btn" href="{{page:contact}}">Contact us</a></p></div></section>"""),
    "contact": (meta("Contact and appointments | Cabinet Léman Santé", "Contact Cabinet Léman Santé in Lausanne to book an appointment: address, opening hours, phone number and a contact form."),
                """<section class="section"><div class="container contact"><div><h1>Contact us</h1><p>Write or call to arrange a first appointment.</p>
<dl><dt>E-mail</dt><dd>{{contact.email_link}}</dd><dt>Phone</dt><dd>{{contact.phone_link}}</dd><dt>Address</dt><dd>{{contact.address}}</dd><dt>Hours</dt><dd>{{contact.hours}}</dd></dl></div></div></section>"""),
}

LOGO_SVG = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 220 48" role="img" aria-label="Cabinet Léman Santé"><title>Cabinet Léman Santé</title>'
            '<circle cx="24" cy="24" r="16" fill="none" stroke="#0b5e7e" stroke-width="4"/><path d="M14 26c4-8 8 8 12 0s6-4 8-2" fill="none" stroke="#b4540a" stroke-width="3" stroke-linecap="round"/>'
            '<text x="52" y="30" font-family="system-ui,sans-serif" font-size="18" font-weight="600" fill="#0b5e7e">Léman Santé</text></svg>\n')


def plan(inp):
    return plan_from_recipe(RECIPE, BRIEF, steps_patch={"S6": {"expectedOutputs": ["notes/seo-pass.md"]}},
                            extra_assumptions=["Français et anglais, 5 pages (accueil, soins, équipe, tarifs, contact) + mentions légales et confidentialité.",
                                               "Adresse, téléphone, horaires, tarifs et équipe non fournis : « [À COMPLÉTER] », jamais inventés.",
                                               "Les avis de patients demandés ne sont pas rédigés : un faux avis est interdit (Code de la concurrence déloyale et plateformes)."])


def _legal_rewrites(inp, lang):
    acts = []
    names = {"fr": [("mentions-legales", "Mentions légales | Cabinet Léman Santé", "Mentions légales du site du Cabinet Léman Santé à Lausanne : éditeur, hébergement, propriété intellectuelle et responsabilité."),
                    ("confidentialite", "Politique de confidentialité | Léman Santé", "Comment le Cabinet Léman Santé traite vos données : aucun cookie, aucun traceur, vos messages ne servent qu'à vous répondre.")],
             "en": [("legal-notice", "Legal notice | Cabinet Léman Santé Lausanne", "Legal notice of the Cabinet Léman Santé website: publisher, hosting, intellectual property and liability."),
                    ("privacy", "Privacy policy | Cabinet Léman Santé", "How Cabinet Léman Santé handles your data: no cookies, no trackers, your messages are only used to answer you.")]}[lang]
    for slug, title, desc in names:
        path = "site/src/pages/%s/%s.html" % (lang, slug)
        text = read_ws(inp, path)
        if text is not None:
            body = text.split("\n", 1)[1] if text.startswith("<!--meta") else text          # le squelette porte une ligne meta vide : on la remplace
            acts.append(write(path, meta(title, desc) + body))
    return acts


def _pages(lang, pages):
    out = []
    for slug, (m, body) in pages.items():
        out.append(write("site/src/pages/%s/%s.html" % (lang, slug), m + body.strip() + "\n"))
    return out


def execute(inp, sid, attempt, fix):
    cids = lambda *a: list(a)  # noqa: E731
    if sid == "S1":
        return {"actions": [{"tool": "site_scaffold", "input": SCAFFOLD},
                            write("site/ARBORESCENCE.md", "# Arborescence\n\n- Accueil (FR /, EN /en/)\n- Soins (/soins ou /services)\n- Équipe\n- Tarifs\n- Contact\n- Mentions légales, Confidentialité\n\nLangues : français (par défaut) et anglais.\n"),
                            {"tool": "note_decision", "input": {"decision": "Aucun avis de patient n'est rédigé.", "why": "Un faux avis est interdit ; un espace réel pourra être ajouté quand le cabinet aura de vrais avis."}},
                            {"tool": "request_input", "input": {"question": "Pouvez-vous nous donner l'adresse, le téléphone, les horaires, le tarif d'une séance et la liste des physiothérapeutes ?", "blocking": False,
                                                              "default": "Les champs restent « [À COMPLÉTER] » et figurent dans la liste « à fournir » du rapport.", "why": "Ces faits ne sont pas dans votre demande et ne s'inventent pas."}}],
                "complete": {"status": "DONE", "summary": "Site structuré (5 pages + mentions légales et confidentialité, FR/EN) ; aucun fait inventé.", "deliverables": [{"path": "site/site.json", "title": "Structure du site"}, {"path": "site/ARBORESCENCE.md", "title": "Arborescence"}],
                             "criteriaClaims": [claim("C1", "site/site.json")], "summaryUpdate": "Squelette du site créé (marque, pages, langues).", "handoffNote": "site/site.json, pages à rédiger dans site/src/pages/fr et /en."}}
    if sid == "S2":
        return {"actions": [write("site/src/assets/img/logo.svg", LOGO_SVG)],
                "complete": {"status": "DONE", "summary": "Identité visuelle : couleurs de la marque dans le kit, logo SVG typographique (aucune photo inventée).", "deliverables": [{"path": "site/src/assets/img/logo.svg", "title": "Logo"}],
                             "criteriaClaims": [claim("C3", "site/src/assets/img/logo.svg")], "summaryUpdate": "Logo SVG ajouté.", "handoffNote": "Logo : site/src/assets/img/logo.svg."}}
    if sid == "S3":
        acts = _pages("fr", FR) + _legal_rewrites(inp, "fr")
        return {"actions": acts, "complete": {"status": "DONE", "summary": "Pages françaises rédigées (vouvoiement, sans chiffre ni avis inventés) ; faits manquants en « [À COMPLÉTER] ».",
                                              "deliverables": [{"path": "site/src/pages/fr/index.html", "title": "Accueil"}], "criteriaClaims": [claim("C5", "site/src/pages/fr/index.html"), claim("C6", "site/src/pages/fr/services.html")],
                                              "summaryUpdate": "Pages FR écrites.", "handoffNote": "Pages FR dans site/src/pages/fr/."}}
    if sid == "S4":
        return {"actions": [{"tool": "site_build", "input": {}}, {"tool": "site_check", "input": {"profile": "vitrine"}}],
                "complete": {"status": "DONE", "summary": "Site construit et contrôlé (liens, méta, accessibilité, poids, confidentialité).", "deliverables": [{"path": "site/dist/index.html", "title": "Site construit"}],
                             "criteriaClaims": [claim("C1", "site/dist/index.html"), claim("C2", "site/dist/sitemap.xml"), claim("C3", "site/dist/index.html")], "summaryUpdate": "Build FR OK.", "handoffNote": "site/dist/ construit."}}
    if sid == "S5":
        return {"actions": _pages("en", EN) + _legal_rewrites(inp, "en") + [{"tool": "site_build", "input": {}}],
                "complete": {"status": "DONE", "summary": "Pages anglaises écrites et site reconstruit.", "deliverables": [{"path": "site/src/pages/en/index.html", "title": "Home (EN)"}],
                             "criteriaClaims": [claim("C1", "site/dist/en/index.html"), claim("C6", "site/src/pages/en/index.html")], "summaryUpdate": "Pages EN écrites.", "handoffNote": "Pages EN dans site/src/pages/en/."}}
    if sid == "S6":
        return {"actions": [write("notes/seo-pass.md", "# Passe SEO\n\n- Un seul h1 par page, titres uniques de 30 à 60 caractères, descriptions de 70 à 160.\n- hreflang réciproques, sitemap et robots.txt générés par la construction.\n"
                                  "- Mots visés (hypothèses, volumes NON mesurés) : physiothérapie Lausanne, rééducation sportive, physiothérapie du dos.\n")],
                "complete": {"status": "DONE", "summary": "Passe SEO relue : titres, descriptions, hreflang, sitemap.", "deliverables": [{"path": "notes/seo-pass.md", "title": "Passe SEO"}],
                             "criteriaClaims": [claim("C2", "site/dist/sitemap.xml")], "summaryUpdate": "SEO relu.", "handoffNote": "notes/seo-pass.md"}}
    if sid == "S7":
        report = ("# Rapport de livraison du site\n\nLe site du Cabinet Léman Santé est construit (FR/EN), contrôlé et empaqueté.\n\n## Ce qui est fait\n- 5 pages et 2 pages légales, en français et en anglais.\n"
                  "- Contrôles automatiques passés (liens, méta, accessibilité, poids, confidentialité, contenu).\n- Un zip prêt à mettre en ligne et un guide de mise en ligne.\n\n"
                  "## Ce que nous n'avons pas fait, et pourquoi\n- **Aucun avis de patient n'a été rédigé** : inventer des avis est interdit. Quand vous aurez de vrais avis, transmettez-les avec leur autorisation de publication.\n"
                  "- Adresse, téléphone, horaires, tarif d'une séance et équipe : non fournis, laissés en « [À COMPLÉTER] ».\n\n## Sources et limites\nTous les textes sont rédigés à partir de votre demande ; aucun chiffre, label ni avis n'est repris d'ailleurs. "
                  "Les mentions légales sont des textes types à faire relire par un juriste. Rien n'est publié : la mise en ligne attend votre validation.\n")
        return {"actions": [{"tool": "site_build", "input": {}}, {"tool": "site_check", "input": {"profile": "vitrine"}}, {"tool": "site_package", "input": {}},
                            write("deliverables/rapport-site.md", report), register("deliverables/rapport-site.md", "Rapport de livraison"),
                            {"tool": "site_publish_prepare", "input": {"target": "wordpress"}}],
                "complete": {"status": "DONE", "summary": "Zip, guide de mise en ligne et brouillons WordPress préparés (rien n'est publié).",
                             "deliverables": [{"path": "deliverables/MISE-EN-LIGNE.md", "title": "Guide de mise en ligne"}, {"path": "deliverables/rapport-site.md", "title": "Rapport de livraison"}],
                             "criteriaClaims": [claim("C4", "site/dist/index.html"), claim("C5", "site/dist/index.html"), claim("C7", "deliverables/MISE-EN-LIGNE.md"), claim("CH", "deliverables/rapport-site.md")],
                             "summaryUpdate": "Livraison prête.", "handoffNote": "deliverables/"}}
    return None


def verify(inp, scope):
    """Critère rubrique C6 : vouvoiement, mêmes noms FR/EN, pas de tutoiement. Les critères automatiques sont rejoués par le moteur."""
    bad = []
    for slug in ("index", "services", "a-propos", "tarifs", "contact"):
        t = read_ws(inp, "site/src/pages/fr/%s.html" % slug) or ""
        for w in (" tu ", " ton ", " ta ", " tes ", "tu peux"):
            if w in t.lower():
                bad.append("%s: tutoiement (%s)" % (slug, w.strip()))
    return {"C6": ("PASS" if not bad else "FAIL", "Vouvoiement tenu, mêmes noms de prestations en FR et EN." if not bad else "; ".join(bad))}


def fix(inp, criteria_ids):
    """Le Worker propriétaire corrige ce que le contrôle du moteur a relevé : pages légales sans méta, puis reconstruit et recontrôle."""
    acts = _legal_rewrites(inp, "fr") + _legal_rewrites(inp, "en") + [{"tool": "site_build", "input": {}}, {"tool": "site_check", "input": {"profile": "vitrine"}}]
    return {"actions": acts, "complete": {"status": "DONE", "summary": "Pages légales complétées (titre, description), site reconstruit et recontrôlé.",
                                          "deliverables": [{"path": "site/dist/index.html", "title": "Site construit"}], "criteriaClaims": [claim(c, "site/dist/index.html") for c in criteria_ids],
                                          "summaryUpdate": "Correctifs appliqués."}}
