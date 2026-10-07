# -*- coding: utf-8 -*-
"""Pages de confiance : /securite.html, /status.html, /api/status, /api/health, /.well-known/security.txt.

Regle d'or (Kader, 2026-10-07) : credibilite SANS mensonge. Chaque phrase publiee ici doit etre
verifiable dans ce depot. Garde-fous mecaniques (tests/trust/) :
  - chaque ligne de la page portant data-claim="..." est reliee a une preuve dans
    tests/trust/claims-evidence.json (un motif qui doit etre present — ou absent — dans le code) ;
  - un script refuse tout mot de certification (SOC 2, ISO 27001, test d'intrusion...) qui ne
    serait pas une negation ou une mention "non fait" ;
  - toute chaine francaise de ces pages doit avoir sa traduction anglaise (i18n-en-trust.js,
    GENERE depuis ce fichier : python dashboard/trust_pages.py --write-i18n).

Le module ne depend de server.py que par trois crochets (voir TrustService.handle_get/handle_post/start).
"""
import datetime
import html
import json
import os
import re
import sys
import time

import seo_pages
import status_monitor

CONTACT_EMAIL = "contact@bk-entreprise.com"          # deja publie : mentions legales + confidentialite
REVIEW_DATE_FR, REVIEW_DATE_EN = "7 octobre 2026", "7 October 2026"
SITEMAP_PATHS = ["/securite.html", "/status.html"]
HERE = os.path.dirname(os.path.abspath(__file__))

# --------------------------------------------------------------------------- traductions
_EN = {}


def _norm(s):
    return re.sub(r"\s+", " ", s).strip()


def T(fr, en):
    """Declare un texte francais ET sa traduction ; renvoie le texte francais.
    Cle = texte normalise tel que i18n.js le lit dans un noeud texte."""
    key = _norm(fr)
    if _EN.get(key, en) != en:
        raise ValueError("traduction en conflit : " + key)
    _EN[key] = en
    return fr


def build_i18n_js():
    lines = [
        "/* Dictionnaire FR -> EN : pages Securite et Statut. GENERE par dashboard/trust_pages.py",
        "   (python dashboard/trust_pages.py --write-i18n) : ne pas modifier a la main. Traduction de courtoisie : la version francaise fait foi. */",
        "Object.assign(window.BK_EN = window.BK_EN || {}, {",
    ]
    items = sorted(_EN.items())
    for i, (fr, en) in enumerate(items):
        lines.append("  " + json.dumps(fr, ensure_ascii=False) + ": " + json.dumps(en, ensure_ascii=False) + ("," if i < len(items) - 1 else ""))
    lines.append("});")
    return "\n".join(lines) + "\n"


def h(s):
    return html.escape(s, quote=True)


# --------------------------------------------------------------------------- contenu : securite
# Chaque element : (texte FR, texte EN, "ids de preuves") — voir tests/trust/claims-evidence.json
def _li(fr, en, claims=""):
    T(fr, en)
    return (fr, claims)


CONTROLS = [
    ("Transport et exposition réseau", T("Transport et exposition réseau", "Transport and network exposure"), [
        _li("Le site est servi en HTTPS ; les certificats sont gérés automatiquement par le proxy Caddy.",
            "The site is served over HTTPS; certificates are managed automatically by the Caddy proxy.", "https"),
        _li("Dans la configuration Docker fournie, seul le proxy HTTPS publie des ports vers l'extérieur : l'application n'est joignable que depuis le serveur lui-même.",
            "In the supplied Docker configuration, only the HTTPS proxy publishes ports to the outside: the application can only be reached from the server itself.", "local-bind"),
    ], [
        _li("Entre le proxy et l'application, le trafic circule en HTTP sur le réseau privé Docker du serveur.",
            "Between the proxy and the application, traffic travels over HTTP on the server's private Docker network.", "https"),
        _li("Aucun en-tête HSTS ni politique CSP n'est configuré.",
            "No HSTS header or CSP policy is configured.", "no-sec-headers"),
    ]),
    ("Identifiants des outils que vous connectez", T("Identifiants des outils que vous connectez", "Credentials of the tools you connect"), [
        _li("Chiffrés au repos en AES-256-GCM, avec un nonce aléatoire par enregistrement, un enregistrement par client et par outil.",
            "Encrypted at rest with AES-256-GCM, using a random nonce per record, one record per client and per tool.", "aes-gcm"),
        _li("La clé maîtresse est lue dans une variable d'environnement du serveur : elle n'est ni dans le code source, ni dans le volume de données, ni dans les sauvegardes.",
            "The master key is read from a server environment variable: it is not in the source code, in the data volume or in the backups.", "key-env"),
        _li("Une fois enregistrée, une valeur n'est jamais renvoyée au navigateur, pas même à vous.",
            "Once saved, a value is never sent back to the browser, not even to you.", "secret-never-returned"),
    ], [
        _li("La clé n'est pas conservée dans un module matériel (HSM) ni dans un service de gestion de clés, et n'est pas renouvelée automatiquement.",
            "The key is not held in a hardware security module (HSM) or a key-management service, and is not rotated automatically.", "no-rotation"),
        _li("Le serveur doit pouvoir déchiffrer ces valeurs pour agir en votre nom : une personne ayant accès au serveur et à son environnement pourrait donc techniquement les lire.",
            "The server must be able to decrypt these values to act on your behalf: a person with access to the server and its environment could therefore technically read them.", "key-env"),
        _li("En interne, la valeur transite par un fichier temporaire supprimé aussitôt après usage.",
            "Internally, the value passes through a temporary file that is deleted right after use.", "temp-file"),
    ]),
    ("Comptes et mots de passe", T("Comptes et mots de passe", "Accounts and passwords"), [
        _li("Mots de passe hachés avec PBKDF2-HMAC-SHA256 (200 000 itérations, sel aléatoire de 16 octets), comparés en temps constant ; jamais stockés ni journalisés en clair.",
            "Passwords are hashed with PBKDF2-HMAC-SHA256 (200,000 iterations, random 16-byte salt), compared in constant time; never stored or logged in clear text.", "passwords"),
        _li("Longueur minimale : 8 caractères.", "Minimum length: 8 characters.", "passwords"),
        _li("Réinitialisation par un lien à usage unique valable 1 heure ; la réponse est identique que le compte existe ou non.",
            "Reset through a single-use link valid for 1 hour; the response is identical whether or not the account exists.", "reset-flow"),
        _li("Une adresse e-mail confirmée est exigée pour souscrire un plan payant.",
            "A confirmed e-mail address is required to subscribe to a paid plan.", "email-verify"),
    ], [
        _li("Pas d'authentification à deux facteurs (2FA), pas de connexion SSO/SAML.",
            "No two-factor authentication (2FA), no SSO/SAML sign-in.", "no-mfa"),
        _li("Pas de contrôle des mots de passe déjà compromis, ni de règle de complexité au-delà de la longueur.",
            "No check against already-leaked passwords, and no complexity rule beyond length.", "no-breach-check"),
    ]),
    ("Sessions", T("Sessions", "Sessions"), [
        _li("Jeton de session aléatoire de 256 bits dans un cookie HttpOnly, SameSite=Lax, et Secure en HTTPS.",
            "Random 256-bit session token in an HttpOnly, SameSite=Lax cookie, and Secure over HTTPS.", "sessions"),
        _li("Seule l'empreinte SHA-256 du jeton est écrite sur le disque, dans un fichier en lecture réservée.",
            "Only the SHA-256 fingerprint of the token is written to disk, in an owner-only file.", "sessions"),
        _li("Durée de session de 30 jours pour un compte client. Toutes les sessions d'un compte sont fermées lors d'une réinitialisation de mot de passe ou d'une suppression du compte.",
            "Session lifetime of 30 days for a customer account. All of an account's sessions are closed when the password is reset or the account is deleted.", "sessions session-invalidation"),
    ], [
        _li("Pas de jeton anti-CSRF dédié : la protection repose sur SameSite=Lax.",
            "No dedicated anti-CSRF token: protection relies on SameSite=Lax.", "no-csrf"),
        _li("Pas de limite d'inactivité ni de liste des appareils connectés.",
            "No inactivity timeout and no list of signed-in devices.", "no-idle-timeout"),
    ]),
    ("Isolation entre clients", T("Isolation entre clients", "Isolation between customers"), [
        _li("Chaque compte a son propre espace (identifiant CLI-CUST-…) : identifiants d'outils, profil, facturation, missions, clé API et webhook sont stockés séparément par client.",
            "Each account has its own space (identifier CLI-CUST-…): tool credentials, profile, billing, missions, API key and webhook are stored separately per customer.", "tenant-isolation"),
        _li("Les routes qui touchent à vos données exigent une session de compte ; une action en attente de validation n'est exécutable que par le client pour lequel elle a été proposée ; une clé API ne donne accès qu'aux missions de son propre client.",
            "The routes that touch your data require an account session; a pending action can only be executed by the customer it was proposed for; an API key only gives access to the missions of its own customer.", "tenant-isolation"),
    ], [
        _li("L'isolation est logique (mêmes serveur, processus et volume), pas une infrastructure dédiée par client.",
            "Isolation is logical (same server, process and volume), not dedicated infrastructure per customer.", "tenant-isolation"),
        _li("Elle n'a fait l'objet d'aucun test d'intrusion externe.",
            "It has not been the subject of any external penetration test.", "no-pentest"),
    ]),
    ("Limites d'usage et protection contre les abus", T("Limites d'usage et protection contre les abus", "Usage limits and abuse protection"), [
        _li("Connexion : 8 échecs par compte et par adresse IP, et 40 par adresse IP, sur 15 minutes, puis blocage temporaire.",
            "Sign-in: 8 failures per account and IP address, and 40 per IP address, over 15 minutes, then a temporary block.", "rate-limits"),
        _li("Inscription : 10 par adresse IP et par heure. Mot de passe oublié : 6 par adresse IP et 3 par e-mail et par heure. Demande de démo : 4 par adresse IP et par heure.",
            "Sign-up: 10 per IP address per hour. Forgotten password: 6 per IP address and 3 per e-mail per hour. Demo request: 4 per IP address per hour.", "rate-limits"),
        _li("Enregistrement d'identifiants d'outils : 40 par heure et par client. API publique : 20 requêtes par minute et par client.",
            "Saving tool credentials: 40 per hour per customer. Public API: 20 requests per minute per customer.", "rate-limits"),
    ], [
        _li("Ces compteurs sont gardés en mémoire : ils repartent à zéro au redémarrage du serveur.",
            "These counters are kept in memory: they reset to zero when the server restarts.", "rate-in-memory"),
    ]),
    ("Connexion guidée de vos outils", T("Connexion guidée de vos outils", "Guided connection of your tools"), [
        _li("Toute adresse de site saisie est réduite à un nom d'hôte public : pas d'adresse IP, pas de réseau interne, et la résolution DNS doit être publique.",
            "Any site address you enter is reduced to a public host name: no IP address, no internal network, and DNS resolution must be public.", "ssrf-guard"),
        _li("Les sous-domaines (Zendesk, Shopify, BambooHR) sont rattachés à un domaine fixe du fournisseur.",
            "Sub-domains (Zendesk, Shopify, BambooHR) are tied to a fixed vendor domain.", "ssrf-guard"),
        _li("Le test de connexion n'utilise qu'un appel de lecture ; si le fournisseur refuse les identifiants, ils sont supprimés aussitôt.",
            "The connection test only uses a read call; if the vendor rejects the credentials, they are deleted immediately.", "verify-removes"),
    ], [
        _li("La vérification DNS est faite à l'enregistrement, pas à chaque appel ultérieur.",
            "The DNS check is made when the tool is saved, not on every later call.", "ssrf-guard"),
        _li("L'adresse de webhook sortant que vous configurez vous-même n'est pas soumise à ce contrôle : point identifié, non corrigé.",
            "The outgoing webhook address that you configure yourself is not subject to this check: a known point, not yet fixed.", "ssrf-webhook-gap"),
    ]),
    ("Appels entrants, webhooks et paiements", T("Appels entrants, webhooks et paiements", "Incoming calls, webhooks and payments"), [
        _li("Appels Twilio (agent téléphonique) : rien n'est traité sans une signature Twilio valide (HMAC-SHA1, comparaison en temps constant). L'appelant n'a accès à aucune donnée de client ni à aucun outil, seulement à une fiche publique.",
            "Twilio calls (phone agent): nothing is processed without a valid Twilio signature (HMAC-SHA1, constant-time comparison). The caller has no access to any customer data or tool, only to a public fact sheet.", "twilio-sig phone-no-access"),
        _li("Messages WhatsApp (Meta) : signature HMAC-SHA256 obligatoire.",
            "WhatsApp messages (Meta): HMAC-SHA256 signature required.", "meta-sig"),
        _li("Webhooks que nous vous envoyons : signés en HMAC-SHA256 (en-tête X-BK-Signature) avec un secret propre à chaque client.",
            "Webhooks we send you: signed with HMAC-SHA256 (X-BK-Signature header) using a secret specific to each customer.", "outgoing-webhook-sig"),
        _li("Paiements : la carte est saisie chez Stripe ; un plan payant n'est activé qu'après vérification, côté serveur, que Stripe a bien encaissé.",
            "Payments: the card is entered at Stripe; a paid plan is only activated after the server has checked that Stripe actually collected the payment.", "stripe-hosted"),
    ], [
        _li("Les canaux téléphone et WhatsApp ne fonctionnent que si leur compte (Twilio, Meta) est configuré sur le serveur.",
            "The phone and WhatsApp channels only work if their account (Twilio, Meta) is configured on the server.", "channels-optional"),
    ]),
    ("Validation humaine des actions sensibles", T("Validation humaine des actions sensibles", "Human approval of sensitive actions"), [
        _li("Lecture : un Worker peut consulter, sans validation, les outils que vous avez connectés.",
            "Reading: a Worker can consult the tools you have connected without approval.", "human-validation"),
        _li("Écriture (envoi, publication, création…) : l'action est seulement proposée ; elle ne s'exécute qu'après votre confirmation explicite dans l'application.",
            "Writing (sending, publishing, creating…): the action is only proposed; it runs only after your explicit confirmation in the application.", "human-validation"),
        _li("Les opérations financières (Stripe, PayPal, QuickBooks, Xero) ne peuvent pas être connectées par un client ; sur le compte du propriétaire, elles exigent toujours une confirmation manuelle.",
            "Financial operations (Stripe, PayPal, QuickBooks, Xero) cannot be connected by a customer; on the owner's account they always require manual confirmation.", "finance-manual"),
        _li("Avant chaque appel au modèle, la mission traverse une chaîne de contrôles d'autorisation (capacité du Worker, autorité, politique, identifiants, connecteurs) ; un échec bloque la mission.",
            "Before each call to the model, the mission goes through a chain of authorization checks (Worker capability, authority, policy, credentials, connectors); a failure blocks the mission.", "auth-chain"),
    ], [
        _li("Une option de pré-autorisation, désactivée par défaut et réversible, laisse les Workers exécuter les écritures sans confirmation : si vous l'activez, cette protection ne s'applique plus à votre compte.",
            "A pre-authorization option, off by default and reversible, lets Workers run writes without confirmation: if you turn it on, this protection no longer applies to your account.", "autoapprove-optin"),
        _li("Si vous cochez « Notifier sur Slack » sur une automatisation, un résumé de chaque exécution (objectif, statut, extrait de la réponse) est publié dans votre Slack sans confirmation à chaque fois.",
            "If you tick “Notify on Slack” on an automation, a summary of each run (objective, status, excerpt of the answer) is posted in your Slack without confirmation each time.", "automation-slack"),
        _li("Les contenus lus dans vos outils (e-mails, documents) sont transmis au modèle d'IA.",
            "Content read in your tools (e-mails, documents) is passed to the AI model.", "tool-results-to-model"),
    ]),
    ("Journaux et traçabilité", T("Journaux et traçabilité", "Logs and traceability"), [
        _li("Journal d'activité de la plateforme : inscriptions, connexions réussies (avec adresse IP), e-mails envoyés, connexions d'outils, suppressions de compte. Il n'est consultable que par le propriétaire.",
            "Platform activity log: sign-ups, successful sign-ins (with IP address), e-mails sent, tool connections, account deletions. Only the owner can view it.", "activity-log"),
        _li("Chaque mission est conservée avec son statut et son résultat : vous retrouvez votre historique dans l'application.",
            "Each mission is kept with its status and result: you find your history in the application.", "mission-history"),
    ], [
        _li("Le journal d'activité ne garde que les 1 000 derniers événements.",
            "The activity log only keeps the last 1,000 events.", "activity-log"),
        _li("Les échecs de connexion ne sont pas journalisés : ils sont seulement comptés pour la limitation d'essais.",
            "Failed sign-ins are not logged: they are only counted for attempt limiting.", "no-failed-login-log"),
        _li("Pas de journal infalsifiable, ni d'export vers un outil de supervision de sécurité (SIEM).",
            "No tamper-proof log, and no export to a security monitoring tool (SIEM).", "no-siem"),
    ]),
    ("Vos données : export, suppression, conservation", T("Vos données : export, suppression, conservation", "Your data: export, deletion, retention"), [
        _li("Export de vos données (compte, profil, facturation, missions, automatisations) au format JSON.",
            "Export of your data (account, profile, billing, missions, automations) in JSON format.", "export-delete"),
        _li("Suppression du compte en libre-service, avec votre mot de passe : elle efface le compte, les identifiants d'outils, le profil, les missions, les automatisations, la clé API et le webhook. Elle est refusée tant qu'un abonnement Stripe est actif.",
            "Self-service account deletion, with your password: it erases the account, tool credentials, profile, missions, automations, API key and webhook. It is refused while a Stripe subscription is active.", "export-delete"),
        _li("Transcriptions de l'agent téléphonique : supprimées automatiquement après 90 jours.",
            "Phone agent transcripts: deleted automatically after 90 days.", "phone-retention"),
    ], [
        _li("L'historique de facturation n'est pas effacé par la suppression du compte, et le journal d'activité garde ses 1 000 derniers événements.",
            "Billing history is not erased by account deletion, and the activity log keeps its last 1,000 events.", "delete-keeps-billing"),
        _li("Les missions et le profil sont stockés sur le disque du serveur sans chiffrement applicatif : seuls les identifiants d'outils sont chiffrés ; les mots de passe sont hachés.",
            "Missions and profile are stored on the server disk without application-level encryption: only tool credentials are encrypted; passwords are hashed.", "plain-missions"),
    ]),
    ("Sauvegardes", T("Sauvegardes", "Backups"), [
        _li("Un script sauvegarde le volume de données ; la procédure d'exploitation prévoit de le lancer chaque nuit à 3 h 30 et de garder 14 jours d'archives.",
            "A script backs up the data volume; the operating procedure plans to run it every night at 3:30 am and keep 14 days of archives.", "backup"),
    ], [
        _li("Le dépôt décrit cette planification mais ne peut pas prouver qu'elle est active sur le serveur.",
            "The repository describes this schedule but cannot prove that it is active on the server.", "backup-unproven"),
        _li("Les archives restent sur le même serveur : aucune copie hors site n'est automatisée par nos soins, et elles ne sont pas chiffrées en tant que telles.",
            "The archives stay on the same server: no off-site copy is automated by us, and they are not encrypted as such.", "backup-limits"),
        _li("La procédure d'exploitation mentionne aussi une sauvegarde quotidienne du serveur par l'hébergeur : elle ne dépend pas de notre script et le dépôt ne permet pas de la vérifier.",
            "The operating procedure also mentions a daily backup of the server by the hosting provider: it does not depend on our script and the repository cannot be used to verify it.", "host-backup"),
        _li("Aucune procédure ni aucun test de restauration n'est documenté.",
            "No restore procedure or restore test is documented.", "no-restore-doc"),
    ]),
    ("Exploitation et déploiement", T("Exploitation et déploiement", "Operations and deployment"), [
        _li("Déploiement automatisé à chaque mise à jour de la branche principale (GitHub Actions, connexion SSH par clé dédiée).",
            "Automated deployment on every update of the main branch (GitHub Actions, SSH connection with a dedicated key).", "deploy-ci"),
        _li("Les secrets (clés API, empreinte du mot de passe d'accès) sont dans le fichier d'environnement du serveur, exclu du dépôt de code.",
            "Secrets (API keys, access-password hash) are in the server's environment file, which is excluded from the code repository.", "secrets-env"),
    ], [
        _li("Une seule personne exploite et développe le service : pas de relecture de code par un second ingénieur, pas de séparation des tâches entre administrateurs.",
            "One person operates and develops the service: no code review by a second engineer, no separation of duties between administrators.", "solo-ops"),
        _li("Pas d'analyse automatique des dépendances, ni de tests qui bloquent le déploiement. Le conteneur de l'application s'exécute avec l'utilisateur root.",
            "No automatic dependency scanning, and no tests that block deployment. The application container runs as the root user.", "deploy-ci container-root"),
    ]),
    ("Disponibilité", T("Disponibilité", "Availability"), [
        _li("Mesure réelle toutes les 60 secondes (application, données, joignabilité du fournisseur d'IA), publiée sur la page de statut avec l'historique des jours réellement mesurés.",
            "Real measurement every 60 seconds (application, data, reachability of the AI provider), published on the status page with the history of the days actually measured.", "status-page"),
    ], [
        _li("Aucun engagement de disponibilité (SLA). Un seul serveur, sans redondance.",
            "No availability commitment (SLA). A single server, with no redundancy.", "single-server"),
        _li("La mesure tourne sur le serveur qu'elle mesure : elle ne remplace pas une surveillance externe indépendante, qui n'est pas en place.",
            "The measurement runs on the server it measures: it does not replace independent external monitoring, which is not in place.", "status-page"),
    ]),
]

SUMMARY_OK = [
    _li("Identifiants d'outils chiffrés (AES-256-GCM) et jamais renvoyés au navigateur.",
        "Tool credentials encrypted (AES-256-GCM) and never sent back to the browser.", "aes-gcm secret-never-returned"),
    _li("Mots de passe hachés (PBKDF2, 200 000 itérations) ; sessions en cookie HttpOnly.",
        "Passwords hashed (PBKDF2, 200,000 iterations); sessions in an HttpOnly cookie.", "passwords sessions"),
    _li("Espace séparé par client pour les identifiants, missions, facturation et clés API.",
        "Separate space per customer for credentials, missions, billing and API keys.", "tenant-isolation"),
    _li("Écritures dans vos outils : proposées, jamais exécutées sans votre validation (sauf option que vous activez).",
        "Writes in your tools: proposed, never executed without your approval (unless you turn on the option).", "human-validation autoapprove-optin"),
    _li("Webhooks Twilio et Meta vérifiés par signature ; limites anti-abus sur les points d'entrée publics.",
        "Twilio and Meta webhooks verified by signature; anti-abuse limits on public entry points.", "twilio-sig meta-sig rate-limits"),
    _li("Export et suppression de vos données en libre-service.",
        "Self-service export and deletion of your data.", "export-delete"),
]
SUMMARY_NOT = [
    _li("Aucun rapport SOC 2, aucune certification ISO/IEC 27001.",
        "No SOC 2 report, no ISO/IEC 27001 certification.", "no-soc2 no-iso"),
    _li("Aucun test d'intrusion réalisé par un tiers.",
        "No penetration test carried out by a third party.", "no-pentest"),
    _li("Pas d'authentification à deux facteurs.",
        "No two-factor authentication.", "no-mfa"),
    _li("Un seul serveur, une seule personne aux commandes, aucun SLA.",
        "A single server, one person in charge, no SLA.", "single-server solo-ops"),
]
SUMMARY_NEXT = [
    _li("Contrôle des adresses de webhook sortant, en-têtes de sécurité HTTP, authentification à deux facteurs, sauvegarde chiffrée hors serveur : identifiés, pas commencés.",
        "Outgoing-webhook address checks, HTTP security headers, two-factor authentication, encrypted off-server backup: identified, not started.", "roadmap"),
]

SUBPROCESSORS = [
    # (service, rôle, données, quand)
    (T("OVHcloud (France)", "OVHcloud (France)"), T("Hébergement du serveur, des données et des sauvegardes", "Hosting of the server, the data and the backups"),
     T("Toutes les données de la plateforme", "All platform data"), T("Toujours", "Always"), "hosting"),
    (T("Anthropic (États-Unis)", "Anthropic (United States)"), T("Modèle d'IA qui rédige les réponses des Workers", "AI model that writes the Workers' answers"),
     T("Contenu de vos missions, profil d'entreprise, résultats lus dans vos outils", "Content of your missions, company profile, results read in your tools"),
     T("À chaque mission", "On every mission"), "sp-anthropic"),
    (T("Stripe", "Stripe"), T("Paiement des abonnements", "Subscription payments"),
     T("Adresse e-mail, plan, identifiant client ; la carte est saisie chez Stripe", "E-mail address, plan, customer identifier; the card is entered at Stripe"),
     T("À la souscription", "When subscribing"), "stripe-hosted"),
    (T("Google (Gmail, Agenda, Drive, Search Console)", "Google (Gmail, Calendar, Drive, Search Console)"),
     T("Outils que vous connectez ; envoi des e-mails du service si aucun serveur SMTP dédié n'est configuré", "Tools you connect; sending of the service's e-mails if no dedicated SMTP server is configured"),
     T("Seulement les données des outils connectés", "Only the data of the connected tools"), T("Sur votre demande", "On your request"), "sp-google"),
    (T("Google Fonts", "Google Fonts"), T("Polices de caractères du site", "Site fonts"),
     T("Adresse IP des visiteurs", "Visitors' IP addresses"), T("À chaque visite", "On every visit"), "sp-fonts"),
    (T("Microsoft (Outlook, Teams, OneDrive)", "Microsoft (Outlook, Teams, OneDrive)"), T("Outils que vous connectez", "Tools you connect"),
     T("Seulement les données des outils connectés", "Only the data of the connected tools"), T("Sur votre demande", "On your request"), "sp-microsoft"),
    (T("Twilio (États-Unis)", "Twilio (United States)"), T("Agent téléphonique et appels sortants", "Phone agent and outgoing calls"),
     T("Numéro et propos de l'appelant (transcrits par Twilio)", "Caller's number and words (transcribed by Twilio)"),
     T("Seulement si un numéro est configuré", "Only if a number is configured"), "sp-twilio"),
    (T("Meta (WhatsApp Cloud API)", "Meta (WhatsApp Cloud API)"), T("Canal WhatsApp", "WhatsApp channel"),
     T("Votre numéro et vos messages", "Your number and your messages"), T("Seulement si vous liez WhatsApp", "Only if you link WhatsApp"), "sp-meta"),
    (T("Outils tiers que vous connectez (Slack, HubSpot, Asana…)", "Third-party tools you connect (Slack, HubSpot, Asana…)"),
     T("Les actions que vous demandez", "The actions you request"),
     T("Les données que ces outils échangent avec BK-AI-WORKERS", "The data these tools exchange with BK-AI-WORKERS"), T("Sur votre demande", "On your request"), "sp-tools"),
    (T("Serveur SMTP dédié", "Dedicated SMTP server"), T("Envoi des e-mails du service", "Sending of the service's e-mails"),
     T("Adresse e-mail du destinataire et contenu du message", "Recipient's e-mail address and message content"),
     T("Seulement s'il est configuré (sinon via Gmail, ci-dessus)", "Only if configured (otherwise via Gmail, above)"), "sp-smtp"),
    (T("OpenAI (États-Unis)", "OpenAI (United States)"), T("Modèle de secours", "Fallback model"),
     T("Même contenu que pour le modèle principal", "Same content as for the main model"),
     T("Seulement si aucune clé Anthropic n'est configurée", "Only if no Anthropic key is configured"), "sp-openai"),
    (T("GitHub", "GitHub"), T("Hébergement du code source et déploiement", "Source code hosting and deployment"),
     T("Aucune donnée client", "No customer data"), T("Lors des mises à jour", "During updates"), "deploy-ci"),
    (T("Cloudflare (cdnjs)", "Cloudflare (cdnjs)"), T("Bibliothèque d'animation du site", "Site animation library"),
     T("Adresse IP des visiteurs", "Visitors' IP addresses"), T("À chaque visite de la page d'accueil", "On every visit to the home page"), "sp-cdnjs"),
    (T("jsDelivr (CDN)", "jsDelivr (CDN)"), T("Icônes des logos d'outils dans l'application", "Tool logo icons in the application"),
     T("Adresse IP des utilisateurs", "Users' IP addresses"), T("Quand la liste des outils s'affiche", "When the tool list is displayed"), "sp-jsdelivr"),
    (T("frankfurter.dev", "frankfurter.dev"), T("Taux de change indicatifs", "Indicative exchange rates"),
     T("Aucune donnée personnelle", "No personal data"), T("Requête du serveur, mise en cache 12 h", "Server request, cached for 12 h"), "sp-fx"),
]

NOT_DONE = [
    _li("Aucun rapport SOC 2 (ni Type I, ni Type II) : aucun audit SOC 2 n'a été réalisé.",
        "No SOC 2 report (neither Type I nor Type II): no SOC 2 audit has been carried out.", "no-soc2"),
    _li("Aucune certification ISO/IEC 27001.",
        "No ISO/IEC 27001 certification.", "no-iso"),
    _li("Aucun test d'intrusion réalisé par un tiers indépendant, et aucun programme de récompense de vulnérabilités (bug bounty).",
        "No penetration test carried out by an independent third party, and no vulnerability reward (bug bounty) programme.", "no-pentest"),
    _li("Aucune attestation sectorielle (HIPAA, PCI DSS, HDS). Les cartes bancaires sont traitées par Stripe et non par nous ; ne saisissez pas de données de santé.",
        "No sector attestation (HIPAA, PCI DSS, HDS). Bank cards are handled by Stripe, not by us; do not enter health data.", "no-sector"),
    _li("Pas d'authentification à deux facteurs ni de SSO. Pas d'en-têtes HSTS/CSP. Pas de jeton anti-CSRF dédié.",
        "No two-factor authentication or SSO. No HSTS/CSP headers. No dedicated anti-CSRF token.", "no-mfa no-sec-headers no-csrf"),
    _li("Pas de chiffrement applicatif des missions, des profils et des comptes ; pas de HSM ; pas de rotation automatique de la clé maîtresse.",
        "No application-level encryption of missions, profiles and accounts; no HSM; no automatic rotation of the master key.", "plain-missions no-rotation"),
    _li("Pas de sauvegarde hors site automatisée par nos soins, ni de test de restauration documenté.",
        "No off-site backup automated by us, and no documented restore test.", "backup-limits no-restore-doc"),
    _li("Pas de surveillance externe indépendante, pas de SLA, pas de redondance.",
        "No independent external monitoring, no SLA, no redundancy.", "single-server"),
]

ROADMAP = [
    # (sujet, statut, détail, preuve)
    (T("Page de statut publique avec historique mesuré", "Public status page with measured history"), "done",
     T("La mesure démarre avec cette page ; aucun historique antérieur n'est reconstitué.", "Measurement starts with this page; no earlier history is reconstructed."), "status-page"),
    (T("Page sécurité et fichier security.txt", "Security page and security.txt file"), "done",
     T("Cette page ; le fichier est servi sur /.well-known/security.txt.", "This page; the file is served at /.well-known/security.txt."), "security-txt"),
    (T("Analyse d'écart SOC 2", "SOC 2 gap analysis"), "done",
     T("Document rédigé dans le dépôt ; aucun audit n'est engagé.", "Document written in the repository; no audit has been started."), "roadmap"),
    (T("Contrôle des adresses de webhook sortant (protection SSRF)", "Checks on outgoing-webhook addresses (SSRF protection)"), "todo",
     T("Identifié ; la protection existe déjà pour la connexion guidée des outils.", "Identified; the protection already exists for the guided connection of tools."), "ssrf-webhook-gap"),
    (T("En-têtes de sécurité HTTP (HSTS, CSP)", "HTTP security headers (HSTS, CSP)"), "todo", T("Identifié.", "Identified."), "no-sec-headers"),
    (T("Authentification à deux facteurs", "Two-factor authentication"), "todo", T("Identifié.", "Identified."), "no-mfa"),
    (T("Sauvegarde chiffrée hors serveur et test de restauration", "Encrypted off-server backup and restore test"), "todo", T("Identifié.", "Identified."), "backup-limits"),
    (T("Surveillance externe indépendante", "Independent external monitoring"), "todo", T("Identifié.", "Identified."), "status-page"),
    (T("Test d'intrusion par un tiers", "Penetration test by a third party"), "decide",
     T("Pas de prestataire choisi, pas de date.", "No provider chosen, no date."), "no-pentest"),
    (T("Audit SOC 2 (Type I puis Type II)", "SOC 2 audit (Type I then Type II)"), "decide",
     T("Dépend du budget et de la demande des clients ; voir l'analyse d'écart.", "Depends on budget and customer demand; see the gap analysis."), "no-soc2"),
]
STATUS_LABEL = {
    "done": (T("Fait", "Done"), "done"),
    "todo": (T("Identifié, non commencé", "Identified, not started"), "todo"),
    "decide": (T("À décider", "To be decided"), "decide"),
}


def _ul(items):
    out = "<ul>"
    for fr, claims in items:
        out += f'<li data-claim="{h(claims)}">{h(fr)}</li>' if claims else f"<li>{h(fr)}</li>"
    return out + "</ul>"


_SEC_CSS = """
.sec-lead{font-size:1.02rem}
.sum{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:14px;margin:18px 0 6px}
.sum>div{border:1px solid var(--card-border);border-radius:var(--radius-sm);padding:14px 16px}
.sum h3{margin:0 0 6px;font-size:.98rem}
.sum ul,.ctl ul{margin:6px 0 0;padding-left:18px;font-size:14px}
.sum li,.ctl li{margin:5px 0}
.sum .ok{border-top:3px solid #2f7d4f}.sum .no{border-top:3px solid #b4432c}.sum .nx{border-top:3px solid var(--gold)}
.ctl{border:1px solid var(--card-border);border-radius:var(--radius-sm);padding:14px 18px;margin:14px 0}
.ctl h3{margin:0 0 4px}
.ctl .cols{display:grid;grid-template-columns:1fr 1fr;gap:6px 22px}
.ctl h4{margin:10px 0 0;font-size:.82rem;text-transform:uppercase;letter-spacing:.05em;color:var(--ink-muted)}
.ctl .lim h4{color:#9a5a12}
@media(max-width:720px){.ctl .cols{grid-template-columns:1fr}}
.tbl{overflow-x:auto;margin:12px 0}
.tbl table{border-collapse:collapse;width:100%;font-size:13.5px;min-width:640px}
.tbl th,.tbl td{border-bottom:1px solid var(--card-border);padding:8px 10px;text-align:left;vertical-align:top}
.tbl th{font-size:.78rem;text-transform:uppercase;letter-spacing:.05em;color:var(--ink-muted)}
.pill{display:inline-block;border-radius:999px;padding:2px 10px;font-size:12px;font-weight:700;white-space:nowrap}
.pill.done{background:#e3f3e9;color:#1f5b39}.pill.todo{background:#fbe9e4;color:#8a3220}.pill.decide{background:#f4ecd8;color:#7a560f}
.note{color:var(--ink-muted);font-size:13px}
"""


def render_security_page():
    sums = (
        f'<div class="sum"><div class="ok"><h3>{h(T("En place", "In place"))}</h3>{_ul(SUMMARY_OK)}</div>'
        f'<div class="no"><h3>{h(T("Pas en place", "Not in place"))}</h3>{_ul(SUMMARY_NOT)}</div>'
        f'<div class="nx"><h3>{h(T("Identifié, non commencé", "Identified, not started"))}</h3>{_ul(SUMMARY_NEXT)}</div></div>'
    )
    ctl = ""
    for title_fr, _t, ok, lim in CONTROLS:
        ctl += (f'<div class="ctl"><h3>{h(title_fr)}</h3><div class="cols">'
                f'<div><h4>{h(T("En place", "In place"))}</h4>{_ul(ok)}</div>'
                f'<div class="lim"><h4>{h(T("Limites connues", "Known limits"))}</h4>{_ul(lim)}</div></div></div>')
    rows = "".join(
        f'<tr data-claim="{h(c)}"><td>{h(s)}</td><td>{h(r)}</td><td>{h(d)}</td><td>{h(w)}</td></tr>'
        for s, r, d, w, c in SUBPROCESSORS)
    sub = ('<div class="tbl"><table><thead><tr>'
           f'<th>{h(T("Service", "Service"))}</th><th>{h(T("Rôle", "Role"))}</th><th>{h(T("Données concernées", "Data concerned"))}</th><th>{h(T("Quand", "When"))}</th>'
           f"</tr></thead><tbody>{rows}</tbody></table></div>")
    road_rows = ""
    for subject, status, detail, claim in ROADMAP:
        label, cls = STATUS_LABEL[status]
        road_rows += (f'<tr data-claim="{h(claim)}"><td>{h(subject)}</td><td><span class="pill {cls}">{h(label)}</span></td><td>{h(detail)}</td></tr>')
    road = ('<div class="tbl"><table><thead><tr>'
            f'<th>{h(T("Sujet", "Topic"))}</th><th>{h(T("Statut", "Status"))}</th><th>{h(T("Détail", "Detail"))}</th>'
            f"</tr></thead><tbody>{road_rows}</tbody></table></div>")
    body = f"""
      <h1>{h(T("Sécurité et confiance", "Security and trust"))}</h1>
      <p class="u">{h(T("Ce qui est réellement en place, ce qui ne l'est pas, et où nous en sommes. Rien d'inventé.", "What is really in place, what is not, and where we stand. Nothing made up."))}</p>
      <style>{_SEC_CSS}</style>
      <p class="sec-lead">{h(T("Cette page décrit uniquement des mesures vérifiables dans le code et la configuration de BK-AI-WORKERS. Chaque ligne est reliée à un test du dépôt qui relit le code source : si le code change, la page doit être revue.", "This page only describes measures that can be checked in the code and configuration of BK-AI-WORKERS. Each line is tied to a repository test that re-reads the source code: if the code changes, the page must be reviewed."))}</p>
      <p class="note">{h(T("Dernière revue du code :", "Last code review:"))} <span data-no-i18n="1" class="rev-date" data-fr="{h(REVIEW_DATE_FR)}" data-en="{h(REVIEW_DATE_EN)}">{h(REVIEW_DATE_FR)}</span></p>
      <h2>{h(T("En bref", "In short"))}</h2>
      {sums}
      <h2>{h(T("Qui exploite le service, et où", "Who runs the service, and where"))}</h2>
      <ul>
        <li data-claim="solo-ops">{h(T("Éditeur : BK-ENTREPRISE, entreprise individuelle, Genève (Suisse). Une seule personne, le fondateur, exploite et administre le service.", "Publisher: BK-ENTREPRISE, a sole proprietorship in Geneva (Switzerland). One person, the founder, operates and administers the service."))}</li>
        <li data-claim="hosting">{h(T("Hébergement : OVHcloud (France), sur un serveur privé virtuel unique. Le dépôt ne précise pas la ville du centre de données.", "Hosting: OVHcloud (France), on a single virtual private server. The repository does not state the data-center city."))}</li>
        <li>{h(T("Contact sécurité :", "Security contact:"))} <a href="mailto:{CONTACT_EMAIL}">{CONTACT_EMAIL}</a></li>
      </ul>
      <h2>{h(T("Ce qui est en place, avec ses limites", "What is in place, with its limits"))}</h2>
      {ctl}
      <h2>{h(T("Sous-traitants et services tiers réellement appelés", "Sub-processors and third-party services actually called"))}</h2>
      <p>{h(T("Cette liste suit le code : un service n'y figure que si le code l'appelle. Les transferts à l'étranger sont décrits dans la", "This list follows the code: a service only appears if the code calls it. Transfers abroad are described in the"))} <a href="/confidentialite.html">{h(T("politique de confidentialité", "privacy policy"))}</a>.</p>
      {sub}
      <h2 id="non-fait">{h(T("Ce qui n'est pas fait", "What is not done"))}</h2>
      {_ul(NOT_DONE)}
      <h2>{h(T("Feuille de route, avec les statuts réels", "Roadmap, with real statuses"))}</h2>
      <p class="note">{h(T("Aucune date n'est promise : un sujet « identifié, non commencé » n'a pas encore été démarré.", "No date is promised: a topic marked “identified, not started” has not been started yet."))}</p>
      {road}
      <h2 id="signaler">{h(T("Signaler une vulnérabilité", "Report a vulnerability"))}</h2>
      <p data-claim="security-txt">{h(T("Écrivez à", "Write to"))} <a href="mailto:{CONTACT_EMAIL}?subject=S%C3%A9curit%C3%A9">{CONTACT_EMAIL}</a> {h(T("avec « Sécurité » en objet. Indiquez l'adresse concernée, les étapes pour reproduire et l'impact observé. Merci de ne pas accéder aux données d'autres clients, de ne pas dégrader le service et de nous laisser le temps de corriger avant toute publication. Nous n'avons pas de programme de récompense. Ces informations figurent aussi dans", "with “Security” as the subject. Give the affected address, the steps to reproduce and the observed impact. Please do not access other customers' data, do not degrade the service, and give us time to fix before any publication. We have no reward programme. This information is also in"))} <a href="/.well-known/security.txt">/.well-known/security.txt</a>.</p>
      <h2>{h(T("Vérifier par vous-même", "Check for yourself"))}</h2>
      <ul>
        <li><a href="/status.html">{h(T("Statut du service et disponibilité mesurée", "Service status and measured availability"))}</a></li>
        <li><a href="/confidentialite.html">{h(T("Politique de confidentialité", "Privacy policy"))}</a></li>
        <li><a href="/cgv.html">{h(T("Conditions générales de vente", "Terms of sale"))}</a></li>
      </ul>
      <p>{h(T("Vous avez un questionnaire de sécurité à remplir ? Écrivez-nous : nous répondons uniquement sur la base de cette page et de ce qui existe réellement.", "Do you have a security questionnaire to fill in? Write to us: we answer only on the basis of this page and of what really exists."))}</p>
      <script>
        (function () {{
          function sync() {{
            var en = window.BK_LANG && window.BK_LANG() === "en";
            var els = document.querySelectorAll(".rev-date");
            for (var i = 0; i < els.length; i++) els[i].textContent = els[i].getAttribute(en ? "data-en" : "data-fr");
          }}
          document.addEventListener("DOMContentLoaded", sync);
          document.addEventListener("bk:lang", sync);
        }})();
      </script>
    """
    return _compose(
        "Sécurité et confiance | BK-AI-WORKERS",
        "Ce qui est réellement en place en matière de sécurité chez BK-AI-WORKERS, ce qui ne l'est pas (aucun SOC 2, aucune ISO 27001), les sous-traitants appelés et la feuille de route.",
        "/securite.html", body,
        {"title": "Security and trust | BK-AI-WORKERS",
         "description": "What is really in place for security at BK-AI-WORKERS, what is not (no SOC 2, no ISO 27001), the sub-processors called and the roadmap."})


# --------------------------------------------------------------------------- contenu : statut
_STATUS_CSS = """
.st-banner{border-radius:var(--radius-sm);padding:16px 18px;font-weight:700;font-size:1.05rem;margin:4px 0 16px;border:1px solid var(--card-border)}
.st-banner.operational{background:#e3f3e9;color:#1f5b39}.st-banner.degraded{background:#fbf1d9;color:#7a560f}
.st-banner.outage{background:#fbe9e4;color:#8a3220}.st-banner.unknown{background:#eceef1;color:#454a55}
.st-comps{list-style:none;margin:0 0 18px;padding:0}
.st-comps li{display:flex;justify-content:space-between;gap:12px;border-bottom:1px solid var(--card-border);padding:9px 2px;font-size:14.5px}
.st-comps .v{font-weight:700;white-space:nowrap}.st-comps .v.ok{color:#1f5b39}.st-comps .v.down{color:#8a3220}.st-comps .v.unknown{color:#6b6f7b}
.st-up{font-size:1.5rem;font-weight:800;margin:6px 0 2px}
.st-days{display:flex;gap:3px;align-items:flex-end;height:46px;margin:12px 0 6px;overflow-x:auto;padding-bottom:2px}
.st-day{flex:0 0 9px;height:100%;border-radius:2px;background:#2f9e63}
.st-day.degraded{background:#d9a400}.st-day.minor{background:#e08a1e}.st-day.major{background:#d4572d}.st-day.outage{background:#b4281c}
.st-day.partial{opacity:.75}
.st-legend{display:flex;flex-wrap:wrap;gap:6px 16px;font-size:12.5px;color:var(--ink-muted);margin:4px 0 10px}
.st-legend i{display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:5px;vertical-align:-1px}
.st-inc{border:1px solid var(--card-border);border-radius:var(--radius-sm);padding:12px 16px;margin:10px 0}
.st-inc h3{margin:0 0 4px;font-size:1rem}.st-inc .meta{font-size:12.5px;color:var(--ink-muted)}
.st-inc ul{margin:8px 0 0;padding-left:18px;font-size:14px}
.st-empty{color:var(--ink-muted)}
details.st-det{margin:8px 0}details.st-det summary{cursor:pointer;font-weight:700;font-size:14px}
details.st-det table{border-collapse:collapse;font-size:13px;margin-top:8px}
details.st-det td,details.st-det th{padding:4px 12px 4px 0;text-align:left}
"""

_STATUS_JS = r"""
(function () {
  "use strict";
  var root = document.getElementById("status-root");
  var data = JSON.parse(document.getElementById("status-data").textContent);
  var failed = false;
  function en() { return !!(window.BK_LANG && window.BK_LANG() === "en"); }
  function L(fr, e) { return en() ? e : fr; }
  function num(n, d) { var s = Number(n).toFixed(d); return en() ? s : s.replace(".", ","); }
  function fmtDate(iso) {
    return new Date(iso).toLocaleDateString(en() ? "en-GB" : "fr-FR", { timeZone: "UTC", day: "numeric", month: "long", year: "numeric" });
  }
  function fmtTime(iso) {
    return new Date(iso).toLocaleTimeString(en() ? "en-GB" : "fr-FR", { timeZone: "UTC", hour: "2-digit", minute: "2-digit" }) + " UTC";
  }
  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined) e.textContent = text;
    return e;
  }
  var BANNER = {
    operational: ["Tous les systèmes fonctionnent", "All systems operational"],
    degraded: ["Service dégradé : le fournisseur d'IA est injoignable, le reste fonctionne", "Degraded service: the AI provider is unreachable, everything else works"],
    outage: ["Service indisponible ou fortement perturbé", "Service unavailable or severely disrupted"],
    unknown: ["Mesure indisponible pour le moment", "Measurement unavailable for the moment"]
  };
  var COMP = {
    app: ["Application (le serveur répond à une vraie requête)", "Application (the server answers a real request)"],
    data: ["Données (fichiers d'état lisibles et valides)", "Data (state files readable and valid)"],
    ai: ["Fournisseur d'IA (joignable par le réseau)", "AI provider (reachable over the network)"]
  };
  var STATE = {
    ok: ["En service", "Operational"], down: ["Indisponible", "Unavailable"], unknown: ["Inconnu", "Unknown"]
  };
  var INC_STATUS = {
    investigating: ["Investigation en cours", "Investigating"], identified: ["Cause identifiée", "Identified"],
    monitoring: ["Surveillance", "Monitoring"], resolved: ["Résolu", "Resolved"]
  };
  var IMPACT = { none: ["Sans impact", "No impact"], minor: ["Impact mineur", "Minor impact"], major: ["Impact majeur", "Major impact"],
    critical: ["Impact critique", "Critical impact"], maintenance: ["Maintenance", "Maintenance"] };

  function render() {
    root.textContent = "";
    // Si le navigateur ne peut pas joindre /api/status (hors ligne, copie en cache d'un service worker,
    // serveur arrete), l'etat embarque dans la page est PERIME : on n'affiche jamais un « tout va bien » perime.
    var shown = failed ? "unknown" : data.status;
    var b = el("div", "st-banner " + shown, L(BANNER[shown][0], BANNER[shown][1]));
    b.setAttribute("role", "status");
    root.appendChild(b);
    if (failed) root.appendChild(el("p", "st-empty", L("Impossible de joindre le serveur depuis votre navigateur : l'état actuel est inconnu. L'historique ci-dessous date de la dernière actualisation réussie.", "Cannot reach the server from your browser: the current state is unknown. The history below dates from the last successful refresh.")));

    var comps = el("ul", "st-comps");
    data.components.forEach(function (c) {
      var li = el("li");
      var label = COMP[c.id] || [c.id, c.id];
      var state = failed ? "unknown" : c.state;
      li.appendChild(el("span", "", L(label[0], label[1])));
      var st = state === "down" && c.id === "ai" ? L("Injoignable", "Unreachable") : L(STATE[state][0], STATE[state][1]);
      li.appendChild(el("span", "v " + state, st));
      comps.appendChild(li);
    });
    root.appendChild(comps);

    root.appendChild(el("h2", "", L("Disponibilité mesurée", "Measured availability")));
    if (data.measuredSinceUtc && data.uptime.percent !== null) {
      root.appendChild(el("div", "st-up", num(data.uptime.percent, 2) + " %"));
      root.appendChild(el("p", "u", L("mesure depuis le ", "measured since ") + fmtDate(data.measuredSinceUtc) +
        " (" + fmtTime(data.measuredSinceUtc) + ") — " + data.uptime.measuredMinutes + L(" minutes écoulées depuis le premier échantillon", " minutes elapsed since the first sample")));
      if (data.uptime.degradedMinutes > 0) root.appendChild(el("p", "u", data.uptime.degradedMinutes + L(" minutes comptées en service dégradé (fournisseur d'IA injoignable).", " minutes counted as degraded service (AI provider unreachable).")));
    } else if (data.measuredSinceUtc) {
      root.appendChild(el("p", "u", L("mesure depuis le ", "measured since ") + fmtDate(data.measuredSinceUtc) + L(" — pas encore une minute complète écoulée.", " — not one full minute elapsed yet.")));
    } else {
      root.appendChild(el("p", "st-empty", L("Aucune mesure enregistrée pour le moment : le pourcentage et l'historique apparaîtront dès le premier échantillon. Rien n'est affiché tant que rien n'a été mesuré.", "No measurement recorded yet: the percentage and history will appear from the first sample. Nothing is shown until something has been measured.")));
    }

    root.appendChild(el("h2", "", L("Disponibilité par jour (jours réellement mesurés)", "Availability per day (days actually measured)")));
    if (data.days.length) {
      var bars = el("div", "st-days");
      bars.setAttribute("role", "img");
      bars.setAttribute("aria-label", L("Disponibilité par jour", "Availability per day"));
      data.days.forEach(function (d) {
        var cls = "st-day " + (d.level === "ok" ? "" : d.level) + (d.partial ? " partial" : "");
        var bar = el("div", cls.trim());
        bar.title = d.date + " — " + num(d.uptimePercent, 2) + " %" + (d.partial ? L(" (journée partielle)", " (partial day)") : "");
        bars.appendChild(bar);
      });
      root.appendChild(bars);
      var legend = el("div", "st-legend");
      [["#2f9e63", "≥ 99,9 %", "≥ 99.9%"], ["#d9a400", "Dégradé", "Degraded"], ["#e08a1e", "≥ 99 %", "≥ 99%"], ["#d4572d", "≥ 95 %", "≥ 95%"], ["#b4281c", "< 95 %", "< 95%"]].forEach(function (x) {
        var s = el("span"); var i = el("i"); i.style.background = x[0]; s.appendChild(i); s.appendChild(document.createTextNode(L(x[1], x[2]))); legend.appendChild(s);
      });
      root.appendChild(legend);
      var det = el("details", "st-det"); det.appendChild(el("summary", "", L("Détail par jour", "Detail per day")));
      var tbl = el("table"); var head = el("tr");
      [L("Jour (UTC)", "Day (UTC)"), L("Disponibilité", "Availability"), L("Minutes indisponibles", "Unavailable minutes"), L("dont sans mesure", "of which unmeasured")].forEach(function (t) { head.appendChild(el("th", "", t)); });
      tbl.appendChild(head);
      data.days.slice().reverse().forEach(function (d) {
        var tr = el("tr");
        [d.date + (d.partial ? "*" : ""), num(d.uptimePercent, 2) + " %", String(d.unavailableMinutes), String(d.unmeasuredMinutes)].forEach(function (t) { tr.appendChild(el("td", "", t)); });
        tbl.appendChild(tr);
      });
      det.appendChild(tbl); det.appendChild(el("p", "u", L("* journée partielle : la mesure a commencé ou n'est pas terminée ce jour-là.", "* partial day: measurement started or is not finished that day.")));
      root.appendChild(det);
    } else {
      root.appendChild(el("p", "st-empty", L("Aucun jour enregistré pour le moment.", "No day recorded yet.")));
    }

    root.appendChild(el("h2", "", L("Incidents", "Incidents")));
    if (!data.incidents.length) {
      root.appendChild(el("p", "st-empty", L("Aucun incident enregistré dans les 90 derniers jours.", "No incident recorded in the last 90 days.")));
    }
    data.incidents.forEach(function (inc) {
      var box = el("div", "st-inc");
      box.appendChild(el("h3", "", inc.title));
      var s = INC_STATUS[inc.status], im = IMPACT[inc.impact];
      box.appendChild(el("div", "meta", L(s[0], s[1]) + " · " + L(im[0], im[1]) + " · " + fmtDate(inc.startedAtUtc) + " " + fmtTime(inc.startedAtUtc) +
        (inc.resolvedAtUtc ? " → " + fmtDate(inc.resolvedAtUtc) + " " + fmtTime(inc.resolvedAtUtc) : "")));
      if (inc.updates.length) {
        var ul = el("ul");
        inc.updates.forEach(function (u) { ul.appendChild(el("li", "", fmtDate(u.atUtc) + " " + fmtTime(u.atUtc) + " — " + u.text)); });
        box.appendChild(ul);
      }
      root.appendChild(box);
    });
    root.appendChild(el("p", "u", L("Dernière actualisation : ", "Last refresh: ") + fmtDate(data.generatedAtUtc) + " " + fmtTime(data.generatedAtUtc)));
  }

  function refresh() {
    fetch("/api/status", { cache: "no-store" }).then(function (r) { if (!r.ok) throw new Error("http"); return r.json(); })
      .then(function (j) { data = j; failed = false; render(); })
      .catch(function () { failed = true; render(); });
  }
  document.addEventListener("DOMContentLoaded", render);
  document.addEventListener("bk:lang", render);
  setInterval(refresh, 60000);
  render();
  refresh();      // tout de suite : une page restee en cache ne doit pas afficher son ancien etat comme s'il etait actuel
})();
"""


def render_status_page(payload):
    blob = json.dumps(payload, ensure_ascii=False).replace("<", "\\u003c")        # jamais de </script> injecte par un incident
    body = f"""
      <h1>{h(T("Statut du service", "Service status"))}</h1>
      <p class="u">{h(T("Mesures réelles, depuis le premier jour où la mesure a démarré. Aucun historique antérieur n'est reconstitué.", "Real measurements, since the first day measurement started. No earlier history is reconstructed."))}</p>
      <style>{_STATUS_CSS}</style>
      <script type="application/json" id="status-data">{blob}</script>
      <noscript><p>{h(T("Cette page a besoin de JavaScript. Les données brutes sont disponibles sur", "This page needs JavaScript. The raw data is available at"))} <a href="/api/status">/api/status</a>.</p></noscript>
      <div id="status-root" data-no-i18n="1"></div>
      <h2>{h(T("Comment c'est mesuré", "How it is measured"))}</h2>
      <p data-claim="status-page">{h(T("Toutes les 60 secondes, le serveur vérifie lui-même : (1) que l'application répond à une vraie requête ; (2) que ses fichiers de données sont lisibles et valides ; (3) que le fournisseur du modèle d'IA est joignable par le réseau (résolution DNS et connexion TCP, sans aucun appel facturé).", "Every 60 seconds, the server checks itself: (1) that the application answers a real request; (2) that its data files are readable and valid; (3) that the AI model provider is reachable over the network (DNS resolution and TCP connection, with no billed call)."))}</p>
      <p data-claim="status-page">{h(T("Le pourcentage est calculé uniquement sur la période écoulée depuis le premier échantillon. Une minute sans mesure est comptée comme indisponible : un serveur arrêté ne peut pas se mesurer lui-même. Les agrégats quotidiens sont conservés 90 jours.", "The percentage is calculated only over the period elapsed since the first sample. A minute without a measurement is counted as unavailable: a stopped server cannot measure itself. Daily aggregates are kept for 90 days."))}</p>
      <p data-claim="status-page">{h(T("Limite : cette page est servie par le serveur qu'elle mesure. Si elle ne s'affiche pas, le service est indisponible. Aucune surveillance externe indépendante n'est en place à ce jour.", "Limit: this page is served by the server it measures. If it does not display, the service is unavailable. No independent external monitoring is in place to date."))}</p>
      <p>{h(T("Le journal des incidents est tenu à la main par l'exploitant. Données brutes :", "The incident log is kept by hand by the operator. Raw data:"))} <a href="/api/status">/api/status</a> — <a href="/securite.html">{h(T("page Sécurité", "Security page"))}</a>.</p>
    """
    return _compose(
        "Statut du service | BK-AI-WORKERS",
        "État réel du service BK-AI-WORKERS : disponibilité mesurée toutes les minutes, jours effectivement enregistrés, journal d'incidents.",
        "/status.html", body,
        {"title": "Service status | BK-AI-WORKERS",
         "description": "Real status of the BK-AI-WORKERS service: availability measured every minute, days actually recorded, incident log."},
        script=_STATUS_JS)


def _compose(title, description, path, body, en_head, script=""):
    scripts = ('<script src="/i18n-en-trust.js"></script>'
               f"<script>window.BK_EN_HEAD={json.dumps(en_head, ensure_ascii=False)};</script>"
               + (f"<script>{script}</script>" if script else ""))
    return seo_pages._page(title, description, path, body, extra_scripts=scripts)


# --------------------------------------------------------------------------- security.txt
def render_security_txt(base_url, now=None):
    now = now if now is not None else time.time()
    expires = datetime.datetime.fromtimestamp(now + 300 * 86400, datetime.timezone.utc).strftime("%Y-%m-%dT00:00:00.000Z")
    base = base_url.rstrip("/")
    return (
        "# Politique de divulgation de vulnerabilites de BK-AI-WORKERS (RFC 9116).\n"
        "# Details : " + base + "/securite.html\n"
        "Contact: mailto:" + CONTACT_EMAIL + "\n"
        "Expires: " + expires + "\n"
        "Preferred-Languages: fr, en\n"
        "Canonical: " + base + "/.well-known/security.txt\n"
        "Policy: " + base + "/securite.html#signaler\n"
    )


# --------------------------------------------------------------------------- service (crochets de server.py)
class _HeadOnlyWriter:
    """Laisse passer les en-tetes HTTP (jusqu'a la ligne vide) et jette le corps : reponse a une requete HEAD."""

    def __init__(self, real):
        self.real, self._buf, self._done = real, b"", False

    def write(self, data):
        if self._done:
            return len(data)
        self._buf += bytes(data)
        end = self._buf.find(b"\r\n\r\n")
        if end >= 0:
            self.real.write(self._buf[:end + 4])
            self._buf, self._done = b"", True
        return len(data)

    def flush(self):
        pass


class TrustService:
    def __init__(self, root, public_base_url, data_dir=None):
        self.root = root
        self.base_url = public_base_url
        self.dir = data_dir or os.environ.get("BK_STATUS_DIR") or os.path.join(root, "memory", "runtime", "status")
        try:
            self.interval = min(300, max(1, int(os.environ.get("BK_STATUS_INTERVAL_SECONDS", "60"))))
        except ValueError:
            self.interval = 60
        self.recorder = status_monitor.StatusRecorder(self.dir)
        self.incidents = status_monitor.IncidentLog(os.path.join(self.dir, "incidents.json"))
        self.sampler = None

    # -- mesure
    def start(self, port, listen_host="127.0.0.1"):
        if os.environ.get("BK_STATUS_DISABLE") == "1" or self.sampler is not None:
            return None
        host = "127.0.0.1" if listen_host in ("", "0.0.0.0", "::") else listen_host
        probes = {
            "app": lambda: status_monitor.check_app(port, host=host),
            "data": status_monitor.DataChecker(self.root),
            "ai": status_monitor.check_ai_reachable,
        }
        self.sampler = status_monitor.Sampler(self.recorder, probes, interval=self.interval)
        self.sampler.start()
        return self.sampler

    def payload(self):
        return status_monitor.public_payload(self.recorder, self.incidents, interval=self.interval)

    # -- reponses
    @staticmethod
    def _json(h_, payload, status=200):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        h_.send_response(status)
        h_.send_header("Content-Type", "application/json; charset=utf-8")
        h_.send_header("Content-Length", str(len(body)))
        h_.send_header("Cache-Control", "no-store")
        h_.end_headers()
        h_.wfile.write(body)

    def handle_get(self, h_, path):
        """True si la route est a nous (la reponse est alors deja envoyee)."""
        if path == "/api/health":
            self._json(h_, {"ok": True})
        elif path == "/api/status":
            self._json(h_, self.payload())
        elif path in ("/securite.html", "/securite"):
            h_._send_html(render_security_page())
        elif path in ("/status.html", "/status"):
            h_._send_html(render_status_page(self.payload()))
        elif path == "/.well-known/security.txt":
            body = render_security_txt(self.base_url).encode("utf-8")
            h_.send_response(200)
            h_.send_header("Content-Type", "text/plain; charset=utf-8")
            h_.send_header("Content-Length", str(len(body)))
            h_.send_header("Cache-Control", "public, max-age=3600")
            h_.end_headers()
            h_.wfile.write(body)
        elif path == "/i18n-en-trust.js":
            h_._send_file(os.path.join(HERE, "i18n-en-trust.js"), "application/javascript; charset=utf-8")
        elif path == "/api/admin/status/incidents":
            if not h_._gate_authenticated():
                h_._send_gate_required()
            else:
                self._json(h_, {"incidents": self.incidents.list_all(), "fileInvalid": self.incidents.invalid})
        else:
            return False
        return True

    HEAD_PATHS = ("/api/health", "/api/status", "/status.html", "/status", "/securite.html", "/securite", "/.well-known/security.txt")

    def handle_head(self, h_, path):
        """HEAD (sondes de surveillance externes, ex. UptimeRobot) : memes en-tetes que GET, sans corps.
        Limite aux routes de ce module ; toute autre route garde le comportement habituel (501)."""
        if path not in self.HEAD_PATHS:
            return False
        real = h_.wfile
        h_.wfile = _HeadOnlyWriter(real)
        try:
            return self.handle_get(h_, path)
        finally:
            h_.wfile = real

    def handle_post(self, h_, path):
        if path != "/api/admin/status/incident":
            return False
        if not h_._gate_authenticated():
            h_._send_gate_required()
            return True
        try:
            length = min(int(h_.headers.get("Content-Length", 0) or 0), 10000)
            body = json.loads(h_.rfile.read(length).decode("utf-8")) if length else {}
        except Exception:
            body = {}
        body = body if isinstance(body, dict) else {}
        action = body.get("action")
        try:
            if action == "add":
                result = self.incidents.add(body.get("title"), status=body.get("status") or "investigating",
                                            impact=body.get("impact") or "minor", text=body.get("text") or "")
            elif action == "update":
                result = self.incidents.update(str(body.get("id") or ""), status=body.get("status"), text=body.get("text"),
                                               impact=body.get("impact"))
            elif action == "resolve":
                result = self.incidents.resolve(str(body.get("id") or ""), body.get("text") or "")
            elif action == "delete":
                self.incidents.delete(str(body.get("id") or ""))
                result = {"deleted": True}
            else:
                self._json(h_, {"error": "UNKNOWN_ACTION"}, 400)
                return True
        except KeyError:
            self._json(h_, {"error": "INCIDENT_NOT_FOUND"}, 404)
            return True
        except ValueError as e:
            self._json(h_, {"error": str(e)}, 400)
            return True
        self._json(h_, {"ok": True, "incident": result})
        return True


if __name__ == "__main__":
    if "--write-i18n" in sys.argv:
        render_security_page()          # remplit le registre de traductions
        render_status_page({"status": "unknown", "components": [], "days": [], "incidents": [], "uptime": {}, "measuredSinceUtc": None})
        out = os.path.join(HERE, "i18n-en-trust.js")
        with open(out, "w", encoding="utf-8", newline="\n") as f:
            f.write(build_i18n_js())
        print("ecrit :", out, f"({len(_EN)} textes)")
    else:
        print("usage : python dashboard/trust_pages.py --write-i18n")
