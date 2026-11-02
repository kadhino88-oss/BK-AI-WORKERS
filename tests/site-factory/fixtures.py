# -*- coding: utf-8 -*-
"""Fixtures de l'atelier de sites : un « bon site » complet (FR/EN, 6 pages, zéro erreur attendue) fabriqué par les VRAIS outils
(site_factory.scaffold puis pages écrites comme le ferait un Worker), et des aides pour y semer un défaut à la fois.

Données entièrement fictives (cabinet imaginaire, domaine .example, téléphone de la plage de test suisse non attribuée) : aucune donnée personnelle."""
import json
import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(REPO, "dashboard"))
os.environ.setdefault("BK_ROOT", REPO)

import site_factory as sf  # noqa: E402

SCAFFOLD = {
    "profile": "vitrine", "languages": ["fr", "en"],
    "brand": {"name": "Atelier Lumen", "tagline": "Physiothérapie à Lausanne", "colors": {"primary": "#0e7490", "accent": "#b45309"}, "font": "humanist"},
    "contact": {"email": "contact@atelier-lumen.example", "phone": "+41 21 555 01 02", "address": "Rue du Lac 12, 1003 Lausanne", "hours": "Lundi au vendredi, 8 h à 18 h"},
    "legal": {"company": "Atelier Lumen Sàrl", "address": "Rue du Lac 12, 1003 Lausanne", "uid": "CHE-000.000.000", "responsible": "Direction d'Atelier Lumen",
              "host": "Hébergeur choisi par le client", "retention": "Les messages sont conservés douze mois au plus, puis supprimés."},
    "baseUrl": "https://atelier-lumen.example", "hosting": {"host": "infomaniak", "domain": "atelier-lumen.example"},
}

PAGES = {
    ("fr", "index"): ({"title": "Atelier Lumen — physiothérapie à Lausanne", "description": "Physiothérapie à Lausanne : bilan, rééducation et conseils pour bouger sans douleur. Prenez rendez-vous en ligne ou par téléphone."},
                      """<section class="hero" aria-labelledby="titre-principal"><div class="container hero__inner"><div>
<p class="eyebrow">Physiothérapie à Lausanne</p>
<h1 id="titre-principal">Retrouver le plaisir de bouger, pas à pas</h1>
<p class="hero__lead">Un bilan clair, des exercices adaptés à votre quotidien et un suivi attentif, au centre de Lausanne.</p>
<div class="actions"><a class="btn" href="{{page:contact}}">Prendre rendez-vous</a><a class="btn btn--ghost" href="{{page:services}}">Voir les soins</a></div>
</div><div class="hero__art">{{illustration}}</div></div></section>
<section class="section" aria-labelledby="titre-soins"><div class="container"><div class="section__head"><h2 id="titre-soins">Nos soins</h2><p>Chaque séance commence par vos objectifs.</p></div>
<div class="grid"><article class="card">{{icon:heart}}<h3>Rééducation</h3><p>Après une blessure ou une opération, nous reconstruisons force et mobilité.</p></article>
<article class="card">{{icon:users}}<h3>Dos et posture</h3><p>Des exercices simples pour soulager le dos au travail comme à la maison.</p></article>
<article class="card">{{icon:calendar}}<h3>Suivi sportif</h3><p>Reprendre le sport en confiance, avec un plan progressif.</p></article></div></div></section>
<section class="section section--alt faq" aria-labelledby="titre-faq"><div class="container prose"><h2 id="titre-faq">Questions fréquentes</h2>
<details><summary>Faut-il une prescription&nbsp;?</summary><p>Une prescription médicale permet le remboursement par l'assurance de base.</p></details>
<details><summary>Combien de temps dure une séance&nbsp;?</summary><p>Une séance dure en général trente minutes.</p></details></div></section>"""),
    ("fr", "services"): ({"title": "Soins de physiothérapie | Atelier Lumen", "description": "Rééducation, dos et posture, suivi sportif : les soins de physiothérapie proposés par Atelier Lumen à Lausanne, expliqués simplement."},
                         """<section class="section"><div class="container prose"><h1>Nos soins de physiothérapie</h1>
<p>Nous adaptons chaque traitement à votre situation et à vos objectifs.</p>
<h2>Rééducation</h2><p>Exercices progressifs et techniques manuelles pour retrouver vos capacités.</p>
<h2>Dos et posture</h2><p>Comprendre vos douleurs et apprendre des gestes qui soulagent.</p>
<p><a href="{{page:contact}}">Demander un rendez-vous</a></p></div></section>"""),
    ("fr", "a-propos"): ({"title": "À propos du cabinet | Atelier Lumen", "description": "Atelier Lumen est un cabinet de physiothérapie au centre de Lausanne : notre approche, notre manière de travailler et nos engagements."},
                         """<section class="section"><div class="container prose"><h1>À propos d'Atelier Lumen</h1>
<p>Un cabinet de quartier, au calme, où l'on prend le temps d'écouter.</p>
<h2>Notre méthode</h2><p>Un bilan, des objectifs partagés, puis des séances qui vous rendent autonome.</p></div></section>"""),
    ("fr", "contact"): ({"title": "Contact et rendez-vous | Atelier Lumen", "description": "Écrivez ou téléphonez à Atelier Lumen pour prendre rendez-vous : adresse à Lausanne, horaires d'ouverture et formulaire de contact."},
                        """<section class="section"><div class="container contact"><div><h1>Nous contacter</h1>
<dl><dt>E-mail</dt><dd>{{contact.email_link}}</dd><dt>Téléphone</dt><dd>{{contact.phone_link}}</dd><dt>Adresse</dt><dd>{{contact.address}}</dd><dt>Horaires</dt><dd>{{contact.hours}}</dd></dl></div>
<form class="form" action="{{contact.mailto}}" method="post" enctype="text/plain"><h2>Écrire un message</h2>
<div><label for="nom">Nom</label><input id="nom" name="nom" type="text" autocomplete="name" required></div>
<div><label for="message">Message</label><textarea id="message" name="message" required></textarea></div>
<p class="form__note">Ce formulaire ouvre votre messagerie : le site n'enregistre aucune donnée.</p>
<button class="btn" type="submit">Préparer le message</button></form></div></section>"""),
    ("en", "index"): ({"title": "Atelier Lumen — physiotherapy in Lausanne", "description": "Physiotherapy in Lausanne: assessment, rehabilitation and advice to move without pain. Book an appointment online or by phone."},
                      """<section class="hero" aria-labelledby="main-title"><div class="container hero__inner"><div>
<p class="eyebrow">Physiotherapy in Lausanne</p>
<h1 id="main-title">Enjoy moving again, step by step</h1>
<p class="hero__lead">A clear assessment, exercises that fit your daily life and attentive follow-up, in central Lausanne.</p>
<div class="actions"><a class="btn" href="{{page:contact}}">Book an appointment</a><a class="btn btn--ghost" href="{{page:services}}">See our care</a></div>
</div><div class="hero__art">{{illustration}}</div></div></section>
<section class="section"><div class="container"><h2>Our care</h2><div class="grid">
<article class="card">{{icon:heart}}<h3>Rehabilitation</h3><p>After an injury or surgery, we rebuild strength and mobility.</p></article>
<article class="card">{{icon:users}}<h3>Back and posture</h3><p>Simple exercises to relieve your back at work and at home.</p></article></div></div></section>"""),
    ("en", "services"): ({"title": "Physiotherapy care | Atelier Lumen", "description": "Rehabilitation, back and posture, sports follow-up: the physiotherapy care offered by Atelier Lumen in Lausanne, explained simply."},
                         """<section class="section"><div class="container prose"><h1>Our physiotherapy care</h1><p>Each treatment is adapted to your situation and goals.</p>
<h2>Rehabilitation</h2><p>Progressive exercises and manual techniques to regain your abilities.</p><p><a href="{{page:contact}}">Ask for an appointment</a></p></div></section>"""),
    ("en", "about"): ({"title": "About the practice | Atelier Lumen", "description": "Atelier Lumen is a physiotherapy practice in central Lausanne: our approach, the way we work and what we commit to for every patient."},
                      """<section class="section"><div class="container prose"><h1>About Atelier Lumen</h1><p>A neighbourhood practice where we take the time to listen.</p>
<h2>Our method</h2><p>An assessment, shared goals, then sessions that make you independent.</p></div></section>"""),
    ("en", "contact"): ({"title": "Contact and appointments | Atelier Lumen", "description": "Write to or call Atelier Lumen to book an appointment: address in Lausanne, opening hours and a contact form that opens your e-mail."},
                        """<section class="section"><div class="container contact"><div><h1>Contact us</h1>
<dl><dt>E-mail</dt><dd>{{contact.email_link}}</dd><dt>Phone</dt><dd>{{contact.phone_link}}</dd><dt>Address</dt><dd>{{contact.address}}</dd></dl></div></div></section>"""),
}
LEGAL_META = {
    ("fr", "mentions-legales"): {"title": "Mentions légales | Atelier Lumen Lausanne", "description": "Mentions légales du site d'Atelier Lumen : éditeur, numéro d'entreprise, hébergement, propriété intellectuelle et responsabilité."},
    ("fr", "confidentialite"): {"title": "Politique de confidentialité | Atelier Lumen", "description": "Comment Atelier Lumen traite vos données : aucun cookie, aucun traceur, vos messages servent uniquement à vous répondre."},
    ("en", "legal-notice"): {"title": "Legal notice | Atelier Lumen Lausanne", "description": "Legal notice of the Atelier Lumen website: publisher, company number, hosting, intellectual property and liability."},
    ("en", "privacy"): {"title": "Privacy policy | Atelier Lumen physiotherapy", "description": "How Atelier Lumen handles your data: no cookies, no trackers, your messages are only used to answer you."},
}


def write_page(ws, lang, slug, meta, body):
    path = os.path.join(ws, "site", "src", "pages", lang, slug + ".html")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("<!--meta " + json.dumps(meta, ensure_ascii=False) + " -->\n" + body.strip() + "\n")


def make_good_site(ws=None, build=True):
    ws = ws or tempfile.mkdtemp(prefix="bk-site-")
    sf.scaffold(ws, dict(SCAFFOLD))
    sj = os.path.join(ws, "site", "site.json")
    with open(sj, encoding="utf-8") as f:
        site = json.load(f)
    site["needsFromClient"] = []
    with open(sj, "w", encoding="utf-8") as f:
        json.dump(site, f, ensure_ascii=False, indent=2)
    for (lang, slug), (meta, body) in PAGES.items():
        write_page(ws, lang, slug, meta, body)
    for (lang, slug), meta in LEGAL_META.items():
        path = os.path.join(ws, "site", "src", "pages", lang, slug + ".html")
        text = open(path, encoding="utf-8").read()
        body = text.split("\n", 1)[1]
        write_page(ws, lang, slug, meta, body)
    if build:
        sf.build(ws)
    return ws


def edit_src(ws, lang, slug, fn):
    path = os.path.join(ws, "site", "src", "pages", lang, slug + ".html")
    text = open(path, encoding="utf-8").read()
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(fn(text))


def edit_dist(ws, rel, fn):
    path = os.path.join(ws, "site", "dist", *rel.split("/"))
    text = ""
    if os.path.isfile(path):
        with open(path, encoding="utf-8") as f:
            text = f.read()
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(fn(text))


def edit_site_json(ws, fn):
    sj = os.path.join(ws, "site", "site.json")
    with open(sj, encoding="utf-8") as f:
        site = json.load(f)
    fn(site)
    with open(sj, "w", encoding="utf-8") as f:
        json.dump(site, f, ensure_ascii=False, indent=2)


def cleanup(ws):
    shutil.rmtree(ws, ignore_errors=True)
