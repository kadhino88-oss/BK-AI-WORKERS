# -*- coding: utf-8 -*-
"""Programme pilote (2026-10-07) : recruter de VRAIS premiers clients.

Pourquoi : la seule source legitime de preuve sociale future (temoignages, logos, chiffres) est un
client reel et consentant. Cette page recueille des candidatures, rien d'autre.

Regles de Kader (a ne pas relacher) :
  - AUCUNE condition commerciale inventee (remise, duree, nombre de places, delai de reponse) : le
    proprietaire n'en a decide aucune ; la page le dit et ne cite que ce qui est deja vrai dans le produit ;
  - aucun faux temoignage, logo, compteur.

Securite (point d'entree PUBLIC : tout texte recu est une DONNEE, jamais une instruction) :
  - POST /api/pilot/apply : JSON uniquement (pas de CSRF par formulaire croise), corps plafonne,
    validation stricte champ par champ (types, longueurs, caracteres invisibles/bidirectionnels refuses,
    liste blanche d'outils tiree du vrai catalogue de connecteurs), champ piege, plafonds par IP, par
    email et global ; rien n'est jamais interprete (le site web n'est JAMAIS visite : pas de SSRF) ;
  - tout ce qui est affiche est echappe : email au proprietaire (html.escape), vue operateur
    (pilot-admin.js : uniquement textContent) ;
  - lecture et suppression des candidatures reservees a l'operateur (meme porte que /api/admin/*) :
    un non-operateur recoit 403, avant meme de lire le corps de la requete ;
  - stockage : un fichier JSON dans core/accounts/data/ (dossier "data/" exclu de la synchronisation de
    deploy/entrypoint.sh : il survit aux deploiements), ecriture atomique sous le verrou d'etat du
    serveur ; un fichier illisible est mis de cote, jamais ecrase.

Le module ne depend de server.py que par trois crochets (PilotService.handle_get / handle_post et
l'injection du verrou, de l'ecriture atomique et de la notification, voir server.py).
"""
import datetime
import hashlib
import html
import ipaddress
import json
import os
import re
import secrets
import threading
import time
import unicodedata
from urllib.parse import urlsplit

import seo_pages

HERE = os.path.dirname(os.path.abspath(__file__))
CONTACT_EMAIL = "contact@bk-entreprise.com"        # deja publie : mentions legales, pied de page
PAGE_PATH = "/pilote.html"
SITEMAP_PATHS = [PAGE_PATH]
CONSENT_VERSION = "pilot-alex-2026-11-21"          # version du texte de consentement affiche
HONEYPOT_FIELD = "contact_me_by_fax_only"          # nom attractif pour un robot, ignore par l'autocompletion
STORE_REL = ("core", "accounts", "data", "pilot-applications.json")   # "data/" : survit aux deploiements
CATALOG_REL = ("core", "runtime", "controlled-connectors", "CONTROLLED-CONNECTOR-CATALOG.json")
PHONE_CONFIG_REL = ("dashboard", "phone-agent", "CLI-DASHBOARD.json")  # source de l'email du proprietaire

# --------------------------------------------------------------------------- plafonds
MAX_BODY_BYTES = 16 * 1024          # un formulaire honnete fait ~3 Ko ; au-dela : refus avant lecture
MAX_ADMIN_BODY_BYTES = 2 * 1024
BODY_READ_TIMEOUT_SECONDS = 10
DRAIN_LIMIT_BYTES = 256 * 1024      # corps refuse : on en vide un peu pour que le client lise bien la reponse
ATTEMPTS_PER_IP_PER_HOUR = 30       # toute requete POST (valide ou non) : empeche le matraquage
SUBMISSIONS_PER_IP_PER_HOUR = 5     # candidatures acceptees
SUBMISSIONS_PER_EMAIL_PER_DAY = 2   # lues dans le fichier : survit aux redemarrages
SUBMISSIONS_GLOBAL_PER_DAY = 100
MAX_STORED_APPLICATIONS = 5000      # jamais d'effacement silencieux des plus anciennes : au-dela, refus + journal
MAX_NOTIFICATIONS_PER_DAY = 40      # emails au proprietaire ; la candidature reste stockee au-dela
MAX_LISTED = 500
MAX_TOOLS = 60

NAME_MIN, NAME_MAX = 2, 100
COMPANY_MIN, COMPANY_MAX = 2, 120
EMAIL_MAX = 254
WEBSITE_MAX = 200
OTHER_TOOLS_MAX = 200
USE_CASE_MIN, USE_CASE_MAX = 10, 1000

_ID_RE = re.compile(r"^PIL-[0-9A-F]{8}$")
_TOOL_ID_RE = re.compile(r"^[a-z0-9_]{1,40}$")
_EMAIL_RE = re.compile(
    r"[A-Za-z0-9](?:[A-Za-z0-9._+-]{0,62}[A-Za-z0-9])?@"
    r"(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+(?:[A-Za-z]{2,24}|xn--[A-Za-z0-9-]{2,59})")
_HOST_RE = re.compile(
    r"(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+(?:[a-z]{2,24}|xn--[a-z0-9-]{2,59})")
_URL_REST_RE = re.compile(r"[A-Za-z0-9._~%/+=&?#:,;@!-]*")

_LAST_LOG = {}


def _log(msg):
    print("[pilot] " + msg, flush=True)


def _log_refusal(reason):
    """Une ligne par motif et par 10 s : un robot ne doit pas inonder le journal."""
    now = time.time()
    if now - _LAST_LOG.get(reason, 0) > 10:
        _LAST_LOG[reason] = now
        _log("refuse reason=" + reason)


# --------------------------------------------------------------------------- traductions FR -> EN
_EN = {}


def _norm(s):
    return re.sub(r"\s+", " ", s).strip()


def T(fr, en):
    """Declare un texte francais ET sa traduction ; renvoie le texte francais.
    Cle = texte normalise tel que i18n.js le lit dans un noeud texte (voir /i18n-en-pilot.js)."""
    key = _norm(fr)
    if _EN.get(key, en) != en:
        raise ValueError("traduction en conflit : " + key)
    _EN[key] = en
    return fr


def build_i18n_js():
    lines = [
        "/* Dictionnaire FR -> EN : programme pilote. GENERE par dashboard/pilot_program.py (route /i18n-en-pilot.js),",
        "   ne pas modifier a la main. Traduction de courtoisie : la version francaise fait foi. */",
        "window.BK_EN = Object.assign(window.BK_EN || {}, {",
    ]
    items = sorted(_EN.items())
    for i, (fr, en) in enumerate(items):
        lines.append("  " + json.dumps(fr, ensure_ascii=False) + ": " + json.dumps(en, ensure_ascii=False)
                     + ("," if i < len(items) - 1 else ""))
    lines.append("});")
    return "\n".join(lines) + "\n"


def h(s):
    return html.escape(str(s), quote=True)


# --------------------------------------------------------------------------- outils (vrai catalogue)
CATEGORY_LABELS = {      # memes libelles FR que l'application (CONNECTOR_CATEGORY_LABELS dans app.js)
    "EMAIL": ("Email", "Email"), "CALENDAR": ("Agenda", "Calendar"), "CRM": ("CRM", "CRM"),
    "SOCIAL_MEDIA": ("Réseaux sociaux", "Social media"), "CMS": ("Sites web (CMS)", "Websites (CMS)"),
    "ECOMMERCE": ("E-commerce", "E-commerce"), "PAYMENT": ("Paiement", "Payment"),
    "ACCOUNTING": ("Comptabilité", "Accounting"), "COMMUNICATION": ("Messagerie", "Messaging"),
    "STORAGE": ("Stockage de fichiers", "File storage"), "WEB_ANALYTICS": ("Analyse web", "Web analytics"),
    "ADVERTISING": ("Publicité", "Advertising"), "PROJECT_MANAGEMENT": ("Gestion de projet", "Project management"),
    "SUPPORT": ("Support client", "Customer support"), "DESIGN": ("Design", "Design"),
    "MONITORING": ("Surveillance", "Monitoring"), "HR": ("Ressources humaines", "Human resources"),
    "TELEPHONY": ("Téléphonie", "Telephony"),
}
for _fr, _en in CATEGORY_LABELS.values():
    T(_fr, _en)
OTHER_CATEGORY = T("Autres", "Other")

# Noms commerciaux (memes que BRAND_LOGOS dans app.js ; "monitoring" et "calendar_hr" sont les vrais
# fournisseurs derriere ces connecteurs, voir le catalogue). Un connecteur absent de cette table recoit
# un nom derive de son identifiant : jamais de case manquante.
TOOL_NAMES = {
    "gmail": "Gmail", "outlook_mail": "Outlook", "calendar": "Google Agenda", "outlook_calendar": "Outlook Calendar",
    "salesforce": "Salesforce", "hubspot": "HubSpot", "pipedrive": "Pipedrive", "linkedin": "LinkedIn",
    "instagram": "Instagram", "facebook": "Facebook", "tiktok": "TikTok", "x_twitter": "X",
    "wordpress": "WordPress", "webflow": "Webflow", "shopify": "Shopify", "woocommerce": "WooCommerce",
    "stripe": "Stripe", "paypal": "PayPal", "quickbooks": "QuickBooks", "xero": "Xero",
    "slack": "Slack", "teams": "Microsoft Teams", "whatsapp_business": "WhatsApp Business",
    "google_drive": "Google Drive", "dropbox": "Dropbox", "onedrive": "OneDrive",
    "google_search_console": "Google Search Console", "google_ads": "Google Ads", "meta_ads": "Meta Ads",
    "asana": "Asana", "trello": "Trello", "monday": "monday.com", "zendesk": "Zendesk", "intercom": "Intercom",
    "figma": "Figma", "monitoring": "UptimeRobot", "calendar_hr": "BambooHR", "twilio": "Twilio",
}


def load_tools(catalog_path):
    """Outils proposables = connecteurs du catalogue qui ont un VRAI adaptateur (les categories generiques
    sans produit derriere : crm, social_media, design, web_analytics, canva, ne sont pas proposees)."""
    try:
        with open(catalog_path, encoding="utf-8-sig") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return []
    tools, seen = [], set()
    for c in (data.get("connectors") if isinstance(data, dict) else None) or []:
        if not isinstance(c, dict) or not c.get("realAdapter"):
            continue
        base = str(c.get("connectorId") or "")
        base = base[:-len(".controlled")] if base.endswith(".controlled") else base
        if not _TOOL_ID_RE.match(base) or base in seen:
            continue
        seen.add(base)
        name = TOOL_NAMES.get(base) or str(c.get("provider") or base).replace("_", " ").title()
        tools.append({"id": base, "name": name, "category": str(c.get("category") or "")})
    return tools


# --------------------------------------------------------------------------- validation (fonction pure)
_BAD_CATEGORIES = {"Cc", "Cf", "Cs", "Co", "Cn"}    # controle, format (bidi, invisibles), surrogates, usage prive, non assigne
_ALLOWED_FORMAT = {"‌", "‍"}              # ZWNJ / ZWJ : necessaires a certaines ecritures et aux emojis composes


def clean_text(value, multiline=False):
    """Texte propre ou None. Refuse : non-chaine, caracteres de controle, caracteres invisibles ou de
    direction (usurpation d'affichage), surrogates isoles. Normalise en NFC et compacte les espaces."""
    if not isinstance(value, str):
        return None
    s = unicodedata.normalize("NFC", value).strip()
    for c in s:
        cat = unicodedata.category(c)
        if cat == "Cc":
            if multiline and c in "\n\r\t":
                continue
            return None
        if cat in _BAD_CATEGORIES and c not in _ALLOWED_FORMAT:
            return None
    if not multiline:
        return " ".join(s.split())
    lines, blank = [], 0
    for line in s.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        line = " ".join(line.split())
        if line:
            blank = 0
            lines.append(line)
        else:
            blank += 1
            if blank == 1:
                lines.append("")
    return "\n".join(lines).strip()


def email_key(email):
    """Cle de comparaison : minuscules, sans '+alias', points ignores chez Gmail. Evite de contourner la
    limite par email avec a+1@x.com, a+2@x.com..."""
    local, _, domain = email.lower().partition("@")
    local = local.split("+", 1)[0]
    if domain in ("gmail.com", "googlemail.com"):
        local, domain = local.replace(".", ""), "gmail.com"
    return local + "@" + domain


def clean_email(value):
    s = clean_text(value)
    if not s or len(s) > EMAIL_MAX or not _EMAIL_RE.fullmatch(s):
        return None
    local, _, domain = s.partition("@")
    if ".." in s or len(local) > 64:
        return None
    return local + "@" + domain.lower()


def clean_website(value):
    """'' si vide ; sinon une URL http(s) normalisee, ou None. Jamais visitee par le serveur."""
    s = clean_text(value)
    if s is None:
        return None
    if not s:
        return ""
    if len(s) > WEBSITE_MAX:
        return None
    candidate = s if "://" in s else "https://" + s
    try:
        parts = urlsplit(candidate)
        port = parts.port
    except ValueError:
        return None
    host = (parts.hostname or "")
    if (parts.scheme.lower() not in ("http", "https") or port is not None or "@" in parts.netloc
            or not _HOST_RE.fullmatch(host) or len(host) > 253):
        return None
    rest = candidate[len(parts.scheme) + 3 + len(parts.netloc):]
    if not _URL_REST_RE.fullmatch(rest):
        return None
    return parts.scheme.lower() + "://" + host + rest


def _blank(v):
    return v is None or (isinstance(v, str) and not v.strip()) or v is False or v == []


def validate(body, allowed_tool_ids):
    """(donnees propres, None) ou (None, (code, champ)). Premier defaut, dans l'ordre du formulaire.
    Les champs inconnus sont ignores et JAMAIS stockes."""
    if not isinstance(body, dict):
        return None, ("BODY_INVALID", "body")

    name = clean_text(body.get("name"))
    if not name:
        return None, ("NAME_REQUIRED" if _blank(body.get("name")) else "NAME_INVALID", "name")
    if not NAME_MIN <= len(name) <= NAME_MAX:
        return None, ("NAME_INVALID", "name")

    raw_email = body.get("email")
    if _blank(raw_email):
        return None, ("EMAIL_REQUIRED", "email")
    email = clean_email(raw_email)
    if not email:
        return None, ("EMAIL_INVALID", "email")

    company = clean_text(body.get("company"))
    if not company:
        return None, ("COMPANY_REQUIRED" if _blank(body.get("company")) else "COMPANY_INVALID", "company")
    if not COMPANY_MIN <= len(company) <= COMPANY_MAX:
        return None, ("COMPANY_INVALID", "company")

    website = clean_website(body.get("website")) if body.get("website") not in (None, "") else ""
    if website is None:
        return None, ("WEBSITE_INVALID", "website")

    tools = []
    raw_tools = body.get("tools", [])
    if raw_tools is None:
        raw_tools = []
    if not isinstance(raw_tools, list) or len(raw_tools) > MAX_TOOLS:
        return None, ("TOOLS_INVALID", "tools")
    for t in raw_tools:
        if not isinstance(t, str) or t not in allowed_tool_ids:
            return None, ("TOOLS_INVALID", "tools")
        if t not in tools:
            tools.append(t)

    other = ""
    if body.get("otherTools") not in (None, ""):
        other = clean_text(body.get("otherTools"))
        if other is None or len(other) > OTHER_TOOLS_MAX:
            return None, ("OTHER_TOOLS_INVALID", "otherTools")

    use_case = clean_text(body.get("useCase"), multiline=True)
    if not use_case:
        return None, ("USE_CASE_REQUIRED" if _blank(body.get("useCase")) else "USE_CASE_INVALID", "useCase")
    if not USE_CASE_MIN <= len(use_case) <= USE_CASE_MAX:
        return None, ("USE_CASE_INVALID", "useCase")

    if body.get("consent") is not True:                  # ni "true", ni 1, ni "on" : un vrai booleen
        return None, ("CONSENT_REQUIRED", "consent")

    lang = body.get("lang", "fr")
    if lang is None:
        lang = "fr"
    if lang not in ("fr", "en"):
        return None, ("LANG_INVALID", "lang")

    return {"name": name, "email": email, "company": company, "website": website, "tools": tools,
            "otherTools": other, "useCase": use_case, "lang": lang}, None


def is_honeypot_filled(body):
    v = body.get(HONEYPOT_FIELD) if isinstance(body, dict) else None
    if isinstance(v, str):
        return bool(v.strip())
    return bool(v)


# --------------------------------------------------------------------------- plafonds en memoire
def ip_key(raw, fallback=""):
    """Cle de plafond pour une adresse IP : un client IPv6 possede tout un /64, on le compte comme un seul."""
    for candidate in (raw, fallback):
        try:
            ip = ipaddress.ip_address(str(candidate or "").strip()[:64])
        except ValueError:
            continue
        if ip.version == 6:
            if ip.ipv4_mapped:
                return str(ip.ipv4_mapped)
            return str(ipaddress.ip_network((ip, 64), strict=False))
        return str(ip)
    return "unknown"


class SlidingWindow:
    """Plafond glissant par cle, en memoire (se vide au redemarrage), taille bornee."""

    def __init__(self, max_keys=20000):
        self._d = {}
        self._lock = threading.Lock()
        self.max_keys = max_keys

    def allow(self, key, limit, window, now):
        with self._lock:
            q = [t for t in self._d.get(key, ()) if now - t < window]
            if len(q) >= limit:
                self._d[key] = q
                return False
            q.append(now)
            self._d[key] = q
            if len(self._d) > self.max_keys:
                for k in [k for k, v in self._d.items() if not v or now - v[-1] >= window]:
                    self._d.pop(k, None)
                if len(self._d) > self.max_keys:                 # toujours trop : on oublie les plus anciennes
                    for k, _ in sorted(self._d.items(), key=lambda kv: kv[1][-1] if kv[1] else 0)[:self.max_keys // 10 or 1]:
                        self._d.pop(k, None)
            return True


# --------------------------------------------------------------------------- stockage
def atomic_write_json(path, data, **dump_kwargs):
    """Meme algorithme que _write_json_atomic de server.py (utilise en production : injecte par server.py)."""
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    tmp = os.path.join(d, ".tmp-" + os.path.basename(path) + "-" + secrets.token_hex(6))
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, **dump_kwargs)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            try:
                os.remove(tmp)
            except OSError:
                pass


class StoreError(Exception):
    pass


class PilotStore:
    """Toujours appele sous le verrou d'etat du serveur : lecture -> modification -> ecriture atomique."""

    def __init__(self, path, write_json=atomic_write_json):
        self.path = path
        self.write_json = write_json

    def load(self):
        try:
            with open(self.path, encoding="utf-8") as f:
                text = f.read()
        except FileNotFoundError:
            return []
        except OSError as e:
            raise StoreError("READ_" + type(e).__name__)
        try:
            data = json.loads(text)
        except ValueError:
            # Fichier illisible (disque, edition manuelle ratee) : on le CONSERVE a cote et on repart d'un
            # fichier neuf. Ne jamais l'ecraser en le prenant pour "vide" (incident du 2026-09-28).
            aside = self.path + ".corrupt-" + str(int(time.time()))
            try:
                os.replace(self.path, aside)
                _log("fichier illisible conserve dans " + os.path.basename(aside))
            except OSError as e:
                raise StoreError("CORRUPT_" + type(e).__name__)
            return []
        rows = data.get("applications") if isinstance(data, dict) else data
        return [r for r in (rows if isinstance(rows, list) else []) if isinstance(r, dict)]

    def save(self, rows):
        try:
            self.write_json(self.path, {"version": 1, "applications": rows}, ensure_ascii=False, indent=1)
            try:
                os.chmod(self.path, 0o600)       # donnees personnelles : lecture reservee au compte du serveur
            except OSError:
                pass
        except (OSError, ValueError, TypeError) as e:
            raise StoreError("WRITE_" + type(e).__name__)


# --------------------------------------------------------------------------- email au proprietaire
def owner_notify_address(root):
    env = (os.environ.get("BK_PILOT_NOTIFY_EMAIL") or "").strip()
    if env and _EMAIL_RE.fullmatch(env):
        return env
    try:
        with open(os.path.join(root, *PHONE_CONFIG_REL), encoding="utf-8-sig") as f:
            addr = str((json.load(f) or {}).get("notifyEmail") or "").strip()
    except (OSError, ValueError, AttributeError):
        return ""
    return addr if _EMAIL_RE.fullmatch(addr) else ""


def build_owner_email(rec, tool_names):
    """(sujet, html, texte). Chaque valeur issue du formulaire passe par html.escape."""
    when = datetime.datetime.fromtimestamp(rec.get("at") or 0, datetime.timezone.utc).strftime("%d.%m.%Y %H:%M UTC")
    rows = [
        ("Référence", rec["id"]), ("Nom", rec["name"]), ("Email", rec["email"]), ("Entreprise", rec["company"]),
        ("Site web", rec.get("website") or "—"), ("Outils", ", ".join(tool_names) or "—"),
        ("Autres outils", rec.get("otherTools") or "—"), ("Langue du formulaire", (rec.get("lang") or "fr").upper()),
        ("Reçue le", when),
    ]
    subject = "Candidature pilote Alex : " + rec["name"] + " (" + rec["company"] + ")"
    subject = subject[:150]
    use_case_html = h(rec["useCase"]).replace("\n", "<br>")
    body = ("<div style=\"font-family:Arial,sans-serif;font-size:15px;color:#16171c\">"
            f"<p><strong>Nouvelle candidature au pilote Alex</strong> (réf. {h(rec['id'])}).</p>"
            "<table cellpadding=\"6\" style=\"border-collapse:collapse\">"
            + "".join(f"<tr><td style=\"color:#6b6f7b;vertical-align:top\">{h(k)}</td><td><strong>{h(v)}</strong></td></tr>"
                      for k, v in rows)
            + f"<tr><td style=\"color:#6b6f7b;vertical-align:top\">Cas d'usage</td><td>{use_case_html}</td></tr>"
            "</table><p style=\"color:#6b6f7b;font-size:13px\">Pour répondre, écrivez à l'adresse ci-dessus. "
            "Toutes les candidatures : tableau de bord administrateur, section « Candidatures pilote Alex ». "
            "Ces informations sont des données saisies par un visiteur : ne cliquez sur aucun lien sans vérifier.</p></div>")
    text = "\n".join(f"{k} : {v}" for k, v in rows) + "\nCas d'usage :\n" + rec["useCase"]
    return subject, body, text


# --------------------------------------------------------------------------- contenu de la page
PAGE_TITLE = "Pilote Alex — Qualification de demandes B2B | BK-AI-WORKERS"
PAGE_DESC = ("Testez Alex sur jusqu'à cinq demandes entrantes B2B en sept jours. Pour les entreprises de maintenance technique du Grand Genève et de Haute-Savoie. "
             "49 CHF ou 49 €, une seule fois, sans renouvellement automatique.")
EN_HEAD = {
    "title": "Alex pilot — B2B enquiry qualification | BK-AI-WORKERS",
    "description": "Test Alex on up to five incoming B2B enquiries over seven days. For technical maintenance businesses in Greater Geneva and Haute-Savoie. "
                   "CHF 49 or €49 once, with no automatic renewal.",
}

# Libelles repris aussi par index.html et le pied de page des pages statiques (voir i18n-en-pilot.js).
FOOTER_LINK = T("Pilote Alex", "Alex pilot")
HOME_CTA_LINK = T("Candidater au pilote Alex", "Apply for the Alex pilot")

# Messages d'erreur (affiches par pilot-form.js : cles = codes renvoyes par /api/pilot/apply).
ERROR_MESSAGES = [
    (("NAME_REQUIRED", "NAME_INVALID"),
     T("Vérifiez votre nom (2 à 100 caractères).", "Please check your name (2 to 100 characters).")),
    (("EMAIL_REQUIRED", "EMAIL_INVALID"),
     T("Vérifiez votre adresse email (par exemple vous@entreprise.com).", "Please check your email address (for example you@company.com).")),
    (("COMPANY_REQUIRED", "COMPANY_INVALID"),
     T("Vérifiez le nom de votre entreprise (2 à 120 caractères).", "Please check your company name (2 to 120 characters).")),
    (("WEBSITE_INVALID",),
     T("Vérifiez l'adresse du site web (par exemple exemple.com), ou laissez ce champ vide.",
       "Please check the website address (for example example.com), or leave the field empty.")),
    (("TOOLS_INVALID",),
     T("Un des outils choisis n'est pas reconnu. Rechargez la page et réessayez.",
       "One of the selected tools is not recognised. Reload the page and try again.")),
    (("OTHER_TOOLS_INVALID",),
     T("Vérifiez le champ « Autres outils » (200 caractères au maximum).", "Please check the \"Other tools\" field (200 characters at most).")),
    (("USE_CASE_REQUIRED", "USE_CASE_INVALID"),
     T("Décrivez votre cas d'usage en quelques phrases (10 à 1000 caractères).",
       "Describe your use case in a few sentences (10 to 1000 characters).")),
    (("CONSENT_REQUIRED",),
     T("Cochez la case pour accepter d'être contacté par email au sujet de votre candidature.",
       "Tick the box to agree to be contacted by email about your application.")),
    (("RATE_LIMITED",),
     T("Trop de candidatures en peu de temps depuis cette connexion. Réessayez un peu plus tard.",
       "Too many applications in a short time from this connection. Please try again a little later.")),
    (("STORAGE_ERROR", "STORAGE_FULL", "UNAVAILABLE"),
     T("Le service est momentanément indisponible. Réessayez dans quelques minutes.",
       "The service is temporarily unavailable. Please try again in a few minutes.")),
    (("NETWORK",),
     T("Connexion impossible pour le moment. Vérifiez votre réseau et réessayez.",
       "Unable to connect right now. Check your network and try again.")),
    (("GENERIC",),
     T("Votre candidature n'a pas pu être envoyée. Rechargez la page et réessayez.",
       "Your application could not be sent. Reload the page and try again.")),
]
ERROR_CODES = {c for codes, _ in ERROR_MESSAGES for c in codes}

_PAGE_CSS = """
.pilot-note{background:#fbf6ea;border:1px solid rgba(165,118,31,.35);border-radius:var(--radius-sm);padding:12px 16px;margin:14px 0}
.pilot-list{padding-left:20px;margin:8px 0}.pilot-list li{margin:7px 0}
[hidden]{display:none!important}
#pilot-form{margin-top:10px}
#pilot-form .f-label,#pilot-form legend{display:block;font-weight:700;font-size:14px;margin:18px 0 4px;padding:0}
#pilot-form .f-help{color:var(--ink-muted);font-size:13px;margin:0 0 6px}
#pilot-form .req{color:#8a1c1c}
#pilot-form input[type=text],#pilot-form input[type=email],#pilot-form textarea{width:100%;box-sizing:border-box;padding:11px 12px;
border:1px solid rgba(20,20,25,.3);border-radius:var(--radius-sm);font:16px/1.45 -apple-system,Segoe UI,Roboto,Arial,sans-serif;background:#fff;color:var(--ink)}
#pilot-form textarea{min-height:120px;resize:vertical}
#pilot-form [aria-invalid=true]{border-color:#8a1c1c;box-shadow:0 0 0 2px rgba(138,28,28,.15)}
#pilot-form fieldset{border:0;padding:0;margin:0;min-width:0}
.pilot-group h4{margin:14px 0 4px;font-size:13px;color:var(--ink-muted);text-transform:uppercase;letter-spacing:.04em}
.pilot-tools{display:grid;grid-template-columns:repeat(auto-fill,minmax(180px,1fr));gap:2px 14px}
.pilot-tools label{display:flex;align-items:center;gap:8px;font-size:14px;padding:5px 0;cursor:pointer}
.pilot-tools input,.pilot-consent input{width:18px;height:18px;flex:none;accent-color:var(--gold)}
.pilot-consent{display:flex;gap:10px;align-items:flex-start;margin:20px 0 6px;font-size:14px;cursor:pointer}
.pilot-hp{position:absolute;left:-9999px;top:auto;width:1px;height:1px;overflow:hidden}
.pilot-err{color:#8a1c1c;background:#fdecea;border:1px solid #f3c1bc;border-radius:var(--radius-sm);padding:10px 14px;margin:16px 0}
.pilot-err p{margin:0}.pilot-err p+p{margin-top:6px}
.pilot-done{background:#eef7ef;border:1px solid #bfdcc4;border-radius:var(--radius-sm);padding:16px 18px;margin:16px 0}
.pilot-done h3{margin-top:0}
#pilot-submit{border:0;cursor:pointer;font-family:inherit;margin-top:12px}
#pilot-submit:disabled{opacity:.6;cursor:progress;transform:none}
@media (max-width:600px){.pilot-tools{grid-template-columns:1fr 1fr}}
"""


def _tools_html(tools):
    groups = {}
    for t in tools:
        groups.setdefault(t["category"], []).append(t)
    out = []
    for cat, items in groups.items():
        label = CATEGORY_LABELS.get(cat, (OTHER_CATEGORY,))[0]
        boxes = "".join(
            f'<label><input type="checkbox" name="tools" value="{h(t["id"])}"><span>{h(t["name"])}</span></label>'
            for t in items)
        out.append(f'<div class="pilot-group"><h4>{h(label)}</h4><div class="pilot-tools">{boxes}</div></div>')
    return "".join(out)


def _errors_html():
    rows = []
    for codes, msg in ERROR_MESSAGES:
        for c in codes:
            rows.append(f'<p data-code="{h(c)}" hidden>{h(msg)}</p>')
    mail = (T("Vous pouvez aussi nous écrire directement à", "You can also write to us directly at")
            + f' <a href="mailto:{CONTACT_EMAIL}">{CONTACT_EMAIL}</a>.')
    return ('<div id="pilot-errors" class="pilot-err" role="alert" aria-live="assertive" hidden>'
            + "".join(rows) + f"<p>{mail}</p></div>")


def render_page(tools):
    """Page /pilote.html : offre de test Alex, sans faux avis ni faux clients."""
    req = '<span class="req" aria-hidden="true"> *</span>'
    body = f"""
      <h1>{T("Pilote Alex : qualification de demandes B2B", "Alex pilot: B2B enquiry qualification")}</h1>
      <p class="u">{T("Pour les entreprises de maintenance technique et CVC du Grand Genève et de Haute-Savoie qui reçoivent des demandes de devis.",
                      "For technical maintenance and HVAC businesses in Greater Geneva and Haute-Savoie that receive quote enquiries.")}</p>
      <div class="cta-row"><a class="btn btn-gold" href="#candidater">{T("Candidater au pilote Alex", "Apply for the Alex pilot")}</a></div>

      <h2>{T("Le problème que le pilote examine", "The problem this pilot examines")}</h2>
      <p>{T("Une demande arrive entre deux interventions. Il faut vérifier l'entreprise, comparer son besoin à vos critères et décider quoi lui répondre. Le pilote permet de voir si Alex rend cette vérification plus claire pour votre activité.",
            "An enquiry arrives between jobs. You need to check the company, compare its need with your criteria and decide how to reply. The pilot shows whether Alex makes this review clearer for your business.")}</p>

      <h2>{T("Ce qui est compris", "What is included")}</h2>
      <ul class="pilot-list">
        <li>{T("Jusqu'à cinq demandes entrantes de votre entreprise, traitées pendant sept jours.",
               "Up to five incoming enquiries from your business, reviewed over seven days.")}</li>
        <li>{T("Pour chaque demande : recherche d'informations publiques sur l'entreprise, éléments trouvés avec leurs liens, adéquation à vos critères et questions encore ouvertes.",
               "For each enquiry: research into public company information, findings with links, fit against your criteria and questions that remain open.")}</li>
        <li>{T("Un brouillon de réponse à relire. Alex ne l'envoie pas à votre place.",
               "A draft reply for you to review. Alex does not send it on your behalf.")}</li>
        <li>{T("Un échange de cadrage et un retour franc sur ce qui a fonctionné ou non pendant le test.",
               "A setup conversation and direct feedback on what did and did not work during the trial.")}</li>
      </ul>

      <h2>{T("Prix et conditions", "Price and terms")}</h2>
      <div class="pilot-note">
        <p style="margin:0 0 8px"><strong>{T("49 CHF en Suisse · 49 € en France — paiement unique, sans renouvellement automatique.",
                                               "CHF 49 in Switzerland · €49 in France — one-time payment, no automatic renewal.")}</strong></p>
        <p style="margin:0 0 8px">{T("La candidature ne déclenche aucun paiement. Nous vérifions d'abord que le cas d'usage et la recherche web sont compatibles, puis nous confirmons par email le démarrage et le mode de règlement.",
                                     "Applying does not trigger a payment. We first check that your use case and web research needs are supported, then confirm the start and payment method by email.")}</p>
        <p style="margin:0">{T("Le pilote ne promet ni rendez-vous ni vente. Il teste la qualité et l'utilité de la qualification d'Alex sur vos demandes.",
                               "The pilot does not promise a meeting or a sale. It tests the quality and usefulness of Alex's qualification on your enquiries.")}</p>
      </div>

      <h2>{T("Avant de candidater", "Before you apply")}</h2>
      <p>{T("Nous commençons avec les entreprises de maintenance technique et CVC du Grand Genève et de Haute-Savoie. Dans le formulaire, décrivez votre activité, votre zone et le nombre approximatif de demandes reçues. N'y collez pas d'email client, de nom de prospect ni d'autre donnée personnelle.",
            "We are starting with technical maintenance and HVAC businesses in Greater Geneva and Haute-Savoie. In the form, describe your activity, service area and approximate number of enquiries. Do not paste customer emails, prospect names or other personal data into it.")}</p>

      <h2 id="candidater">{T("Candidater", "Apply")}</h2>
      <noscript><p class="pilot-note">Ce formulaire demande JavaScript. / This form needs JavaScript. —
        <a href="mailto:{CONTACT_EMAIL}">{CONTACT_EMAIL}</a></p></noscript>

      <form id="pilot-form" autocomplete="on" hidden>
        <p class="u">{T("Les champs marqués d'une étoile sont obligatoires.", "Fields marked with an asterisk are required.")}</p>

        <label class="f-label" for="pilot-name">{T("Votre nom", "Your name")}{req}</label>
        <input type="text" id="pilot-name" name="name" required minlength="{NAME_MIN}" maxlength="{NAME_MAX}" autocomplete="name"
               placeholder="{h(T("Ex : Marie Dupont", "E.g. Marie Dupont"))}">

        <label class="f-label" for="pilot-email">{T("Email professionnel", "Work email")}{req}</label>
        <input type="email" id="pilot-email" name="email" required maxlength="{EMAIL_MAX}" autocomplete="email" inputmode="email"
               placeholder="{h(T("vous@entreprise.com", "you@company.com"))}">

        <label class="f-label" for="pilot-company">{T("Entreprise", "Company")}{req}</label>
        <input type="text" id="pilot-company" name="company" required minlength="{COMPANY_MIN}" maxlength="{COMPANY_MAX}" autocomplete="organization"
               placeholder="{h(T("Ex : Atelier Dupont SA", "E.g. Atelier Dupont Ltd"))}">

        <label class="f-label" for="pilot-website">{T("Site web (facultatif)", "Website (optional)")}</label>
        <input type="text" id="pilot-website" name="website" maxlength="{WEBSITE_MAX}" autocomplete="url" inputmode="url"
               placeholder="{h(T("exemple.com", "example.com"))}">

        <label class="f-label" for="pilot-usecase">{T("Vos demandes entrantes et votre activité", "Your incoming enquiries and business")}{req}</label>
        <p class="f-help">{T("Indiquez votre activité, votre région, le volume approximatif de demandes par mois et ce qui prend le plus de temps. N'incluez aucune donnée personnelle de client.",
                             "Describe your activity, region, approximate monthly enquiry volume and what takes the most time. Do not include customer personal data.")}</p>
        <textarea id="pilot-usecase" name="useCase" required minlength="{USE_CASE_MIN}" maxlength="{USE_CASE_MAX}" rows="5"
                  placeholder="{h(T("Ex. : entreprise de maintenance CVC à Annemasse ; environ 8 demandes B2B par mois ; vérifier l'adéquation avant de préparer un devis.",
                                    "E.g. HVAC maintenance business in Annemasse; around 8 B2B enquiries per month; check fit before preparing a quote."))}"></textarea>

        <label class="pilot-consent"><input type="checkbox" id="pilot-consent" name="consent" required>
          <span>{T("J'accepte que BK-AI-WORKERS (BK-ENTREPRISE) me contacte par email pour répondre à ma candidature au pilote Alex.",
                   "I agree that BK-AI-WORKERS (BK-ENTREPRISE) may email me to respond to my Alex pilot application.")}{req}</span></label>

        <div class="pilot-hp" aria-hidden="true"><label>{T("Ne pas remplir ce champ", "Do not fill in this field")}
          <input type="text" name="{HONEYPOT_FIELD}" tabindex="-1" autocomplete="off"></label></div>

        {_errors_html()}

        <button type="submit" id="pilot-submit" class="btn btn-gold"><span class="lbl">{T("Envoyer ma candidature", "Send my application")}</span><span class="busy" hidden>{T("Envoi en cours…", "Sending…")}</span></button>

        <h3>{T("Vos données", "Your data")}</h3>
        <p class="f-help">{T("Les informations servent uniquement à étudier votre candidature au pilote Alex et à vous répondre. Elles ne valent ni commande ni consentement à des emails marketing.",
                             "This information is used only to review your Alex pilot application and reply to you. It is not an order or consent to marketing emails.")}</p>
        <p class="f-help">{T("Pour les faire supprimer, écrivez à", "To have it deleted, write to")} <a href="mailto:{CONTACT_EMAIL}">{CONTACT_EMAIL}</a>.
          <a href="/confidentialite.html">{T("Confidentialité", "Privacy")}</a></p>
      </form>

      <div id="pilot-done" class="pilot-done" tabindex="-1" role="status" hidden>
        <h3>{T("Merci, votre candidature au pilote Alex est enregistrée.", "Thank you, your Alex pilot application has been recorded.")}</h3>
        <p>{T("Nous vérifions si le cas convient au pilote et revenons vers vous par email avec les prochaines étapes. Aucun paiement n'a été déclenché.", "We will check whether your use case fits the pilot and email you with the next steps. No payment has been triggered.")}</p>
        <p>{T("Référence :", "Reference:")} <strong id="pilot-ref"></strong></p>
        <p>{T("Votre référence permet de retrouver la demande si vous nous écrivez.", "Your reference helps us find your application if you contact us.")}</p>
      </div>
    """
    page = seo_pages._page(PAGE_TITLE, PAGE_DESC, PAGE_PATH, body)
    page = page.replace("</head><body>", f"<style>{_PAGE_CSS}</style></head><body>", 1)
    page = page.replace('<script src="/i18n.js"></script>',
                        '<script src="/i18n-en-pilot.js"></script><script src="/i18n.js"></script>'
                        '<script src="/pilot-form.js"></script>', 1)
    return page


PAGE_CSP = ("default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; "
            "font-src https://fonts.gstatic.com; img-src 'self' data:; connect-src 'self'; form-action 'self'; "
            "frame-ancestors 'none'; base-uri 'none'; object-src 'none'")


def build_form_js():
    """pilot-form.js precede de l'en-tete anglais (titre/description) tire des constantes de ce module."""
    with open(os.path.join(HERE, "pilot-form.js"), encoding="utf-8") as f:
        code = f.read()
    return "window.BK_EN_HEAD = " + json.dumps(EN_HEAD, ensure_ascii=False) + ";\n" + code


# --------------------------------------------------------------------------- service HTTP
def _send(h_, status, body, ctype, headers=None):
    h_.send_response(status)
    h_.send_header("Content-Type", ctype)
    h_.send_header("Content-Length", str(len(body)))
    h_.send_header("X-Content-Type-Options", "nosniff")
    for k, v in (headers or {}).items():
        h_.send_header(k, v)
    h_.end_headers()
    h_.wfile.write(body)


def _json(h_, payload, status=200):
    _send(h_, status, json.dumps(payload, ensure_ascii=False).encode("utf-8"), "application/json; charset=utf-8",
          {"Cache-Control": "no-store"})


class PilotService:
    def __init__(self, root, public_base_url="", lock=None, write_json=None, notify=None, now=time.time,
                 log=None, notify_to=None, catalog_path=None):
        self.root = root
        self.public_base_url = public_base_url
        self.lock = lock or threading.RLock()
        self.store = PilotStore(os.path.join(root, *STORE_REL), write_json or atomic_write_json)
        self.notify = notify                     # notify(to, subject, html, text) ; se charge lui-meme de journaliser
        self.now = now
        self.log = log or _log
        self.notify_to = notify_to               # None : variable BK_PILOT_NOTIFY_EMAIL puis fiche du standard telephonique
        self.catalog_path = catalog_path or os.path.join(root, *CATALOG_REL)
        self.attempts = SlidingWindow()
        self.accepted = SlidingWindow()
        self._notified = (None, 0)
        self._notify_lock = threading.Lock()
        self._tools_cache = (None, [])

    # ----------------------------------------------------------------- outils
    def tools(self):
        try:
            stamp = os.stat(self.catalog_path).st_mtime_ns
        except OSError:
            stamp = None
        if self._tools_cache[0] != stamp or stamp is None:
            self._tools_cache = (stamp, load_tools(self.catalog_path))
        return self._tools_cache[1]

    # ----------------------------------------------------------------- candidature
    def submit(self, clean, ip):
        """Stocke une candidature validee. Retourne (statut HTTP, charge utile)."""
        now = int(self.now())
        tools_by_id = {t["id"]: t["name"] for t in self.tools()}
        with self.lock:
            try:
                rows = self.store.load()
            except StoreError as e:
                self.log("stockage ECHEC (" + str(e) + ")")
                return 503, {"error": "STORAGE_ERROR"}
            key = email_key(clean["email"])
            since = now - 86400
            if sum(1 for r in rows if r.get("emailKey") == key and (r.get("at") or 0) >= since) >= SUBMISSIONS_PER_EMAIL_PER_DAY:
                _log_refusal("RATE_LIMITED_EMAIL")
                return 429, {"error": "RATE_LIMITED"}
            if sum(1 for r in rows if (r.get("at") or 0) >= since) >= SUBMISSIONS_GLOBAL_PER_DAY:
                _log_refusal("RATE_LIMITED_GLOBAL")
                return 429, {"error": "RATE_LIMITED"}
            if len(rows) >= MAX_STORED_APPLICATIONS:
                self.log("stockage PLEIN (" + str(len(rows)) + " candidatures) : nouvelle candidature refusee")
                return 503, {"error": "STORAGE_FULL"}
            if not self.accepted.allow(ip, SUBMISSIONS_PER_IP_PER_HOUR, 3600, now):
                _log_refusal("RATE_LIMITED_IP")
                return 429, {"error": "RATE_LIMITED"}
            used = {r.get("id") for r in rows}
            rid = "PIL-" + secrets.token_hex(4).upper()
            while rid in used:
                rid = "PIL-" + secrets.token_hex(4).upper()
            rec = {"id": rid, "at": now, "atUtc": datetime.datetime.fromtimestamp(now, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                   **clean, "emailKey": key, "consent": True, "consentVersion": CONSENT_VERSION, "status": "new"}
            rows.append(rec)
            try:
                self.store.save(rows)
            except StoreError as e:
                self.log("stockage ECHEC (" + str(e) + ")")
                return 503, {"error": "STORAGE_ERROR"}
        self.log(f"candidature enregistree id={rid} outils={len(clean['tools'])} lang={clean['lang']}")
        self._notify_owner(rec, [tools_by_id.get(t, t) for t in clean["tools"]])
        return 200, {"ok": True, "id": rid}

    def _notify_owner(self, rec, tool_names):
        to = self.notify_to if self.notify_to is not None else owner_notify_address(self.root)
        if not self.notify or not to:
            self.log("email au proprietaire : AUCUN destinataire configure (BK_PILOT_NOTIFY_EMAIL) ; la candidature reste dans le tableau de bord")
            return
        today = datetime.date.fromtimestamp(self.now()).isoformat()
        with self._notify_lock:
            day, n = self._notified
            if day != today:
                day, n = today, 0
            if n >= MAX_NOTIFICATIONS_PER_DAY:
                self.log("email au proprietaire : plafond journalier atteint ; la candidature reste dans le tableau de bord")
                return
            self._notified = (day, n + 1)
        subject, body, text = build_owner_email(rec, tool_names)

        def run():
            try:
                self.notify(to, subject, body, text)
            except Exception as e:                  # jamais de candidature perdue a cause d'un email
                self.log("email au proprietaire : ECHEC (" + type(e).__name__ + ")")

        threading.Thread(target=run, daemon=True).start()

    # ----------------------------------------------------------------- vue operateur
    def list_applications(self):
        names = {t["id"]: t["name"] for t in self.tools()}
        with self.lock:
            rows = self.store.load()
        out = []
        for r in reversed(rows[-MAX_LISTED:]):
            out.append({
                "id": r.get("id"), "atUtc": r.get("atUtc"), "name": r.get("name"), "email": r.get("email"),
                "company": r.get("company"), "website": r.get("website") or "",
                "tools": [{"id": t, "name": names.get(t, t)} for t in (r.get("tools") or []) if isinstance(t, str)],
                "otherTools": r.get("otherTools") or "", "useCase": r.get("useCase"), "lang": r.get("lang") or "fr",
                "status": r.get("status") or "new",
            })
        return {"applications": out, "count": len(rows)}

    def delete_application(self, rid):
        with self.lock:
            rows = self.store.load()
            kept = [r for r in rows if r.get("id") != rid]
            if len(kept) == len(rows):
                return False
            self.store.save(kept)
        self.log("candidature supprimee id=" + rid)
        return True

    # ----------------------------------------------------------------- HTTP
    def _client_ip(self, h_):
        peer = ""
        try:
            peer = h_.client_address[0]
        except (AttributeError, IndexError, TypeError):
            pass
        try:
            raw = h_._client_ip()
        except Exception:
            raw = peer
        return ip_key(raw, peer)

    def _read_json_body(self, h_, limit):
        """(corps decode, None) ou (None, (statut, code)). Le corps n'est lu qu'apres les controles d'en-tete."""
        if h_.headers.get("Transfer-Encoding"):
            return None, (411, "LENGTH_REQUIRED")
        raw_len = h_.headers.get("Content-Length")
        if raw_len is None:
            return None, (411, "LENGTH_REQUIRED")
        if not re.fullmatch(r"[0-9]{1,9}", raw_len.strip()):
            return None, (400, "BODY_INVALID")
        n = int(raw_len)
        ctype = (h_.headers.get("Content-Type") or "").split(";")[0].strip().lower()
        if ctype != "application/json":
            self._drain(h_, n)
            return None, (415, "UNSUPPORTED_MEDIA_TYPE")
        if n > limit:
            self._drain(h_, n)
            return None, (413, "PAYLOAD_TOO_LARGE")
        try:
            h_.connection.settimeout(BODY_READ_TIMEOUT_SECONDS)
        except (AttributeError, OSError):
            pass
        try:
            data = h_.rfile.read(n)
        except OSError:
            return None, (400, "BODY_INVALID")
        if len(data) != n:
            return None, (400, "BODY_INVALID")
        try:
            return json.loads(data.decode("utf-8")), None
        except (ValueError, RecursionError):
            return None, (400, "BODY_INVALID")

    @staticmethod
    def _declared_length(h_):
        raw = str(h_.headers.get("Content-Length") or "").strip()
        return int(raw) if re.fullmatch(r"[0-9]{1,9}", raw) else 0

    @staticmethod
    def _drain(h_, n):
        try:
            h_.connection.settimeout(2)
            h_.rfile.read(min(n, DRAIN_LIMIT_BYTES))
        except (AttributeError, OSError):
            pass
        h_.close_connection = True

    def handle_get(self, h_, path):
        if path in (PAGE_PATH, "/pilote"):
            _send(h_, 200, render_page(self.tools()).encode("utf-8"), "text/html; charset=utf-8",
                  {"Cache-Control": "no-cache, must-revalidate", "Content-Security-Policy": PAGE_CSP,
                   "Referrer-Policy": "strict-origin-when-cross-origin", "X-Frame-Options": "DENY"})
            return True
        if path == "/i18n-en-pilot.js":
            _send(h_, 200, build_i18n_js().encode("utf-8"), "application/javascript; charset=utf-8",
                  {"Cache-Control": "no-cache, must-revalidate"})
            return True
        if path == "/pilot-form.js":
            _send(h_, 200, build_form_js().encode("utf-8"), "application/javascript; charset=utf-8",
                  {"Cache-Control": "no-cache, must-revalidate"})
            return True
        if path == "/pilot-admin.js":
            with open(os.path.join(HERE, "pilot-admin.js"), "rb") as f:
                _send(h_, 200, f.read(), "application/javascript; charset=utf-8", {"Cache-Control": "no-cache, must-revalidate"})
            return True
        if path == "/api/pilot/applications":
            if not h_._gate_authenticated():
                _json(h_, {"error": "FORBIDDEN"}, 403)
                return True
            try:
                _json(h_, self.list_applications())
            except StoreError as e:
                self.log("lecture ECHEC (" + str(e) + ")")
                _json(h_, {"error": "STORAGE_ERROR"}, 503)
            return True
        return False

    def handle_post(self, h_, path):
        if path == "/api/pilot/apply":
            self._apply(h_)
            return True
        if path == "/api/pilot/applications/delete":
            if not h_._gate_authenticated():               # operateur seulement, avant toute lecture du corps
                _json(h_, {"error": "FORBIDDEN"}, 403)
                return True
            body, err = self._read_json_body(h_, MAX_ADMIN_BODY_BYTES)
            if err:
                _json(h_, {"error": err[1]}, err[0])
                return True
            rid = body.get("id") if isinstance(body, dict) else None
            if not isinstance(rid, str) or not _ID_RE.match(rid):
                _json(h_, {"error": "ID_INVALID"}, 400)
                return True
            try:
                ok = self.delete_application(rid)
            except StoreError as e:
                self.log("suppression ECHEC (" + str(e) + ")")
                _json(h_, {"error": "STORAGE_ERROR"}, 503)
                return True
            _json(h_, {"ok": True} if ok else {"error": "NOT_FOUND"}, 200 if ok else 404)
            return True
        return False

    def _apply(self, h_):
        try:
            ip = self._client_ip(h_)
            if not self.attempts.allow(ip, ATTEMPTS_PER_IP_PER_HOUR, 3600, self.now()):
                _log_refusal("RATE_LIMITED_ATTEMPTS")
                self._drain(h_, self._declared_length(h_))
                _json(h_, {"error": "RATE_LIMITED"}, 429)
                return
            body, err = self._read_json_body(h_, MAX_BODY_BYTES)
            if err:
                _log_refusal(err[1])
                _json(h_, {"error": err[1]}, err[0])
                return
            if is_honeypot_filled(body):                   # robot : on fait semblant, rien n'est stocke ni envoye
                _log_refusal("HONEYPOT")
                _json(h_, {"ok": True})
                return
            clean, bad = validate(body, {t["id"] for t in self.tools()})
            if bad:
                _json(h_, {"error": bad[0], "field": bad[1]}, 400)
                return
            status, payload = self.submit(clean, ip)
            _json(h_, payload, status)
        except Exception as e:                            # jamais de trace Python vers l'exterieur
            self.log("erreur interne (" + type(e).__name__ + ")")
            try:
                _json(h_, {"error": "UNAVAILABLE"}, 500)
            except OSError:
                pass


# Enregistre TOUTES les traductions de la page des l'import : /i18n-en-pilot.js ne depend pas de l'ordre des requetes.
render_page([])
