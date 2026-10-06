"""Connexion guidee des outils pour les clients (2026-10-06).

Demande de Kader : "les clients doivent connecter tous leurs outils sans probleme et
le plus facilement possible, ces restrictions n'ont pas leur place". Avant, seul le
proprietaire pouvait coller un secret ; les ~21 outils sans "Se connecter avec ..."
affichaient donc "Connexion en un clic bientot" et aucun bouton.

Ici : un formulaire PAR OUTIL (champs nommes, etapes en francais, lien direct vers la page
du fournisseur), le serveur assemble lui-meme le secret au format attendu par
core/integrations/Generic-REST-Adapter.ps1, le valide, puis il est chiffre
(Client-Credential-Store.ps1) et verifie par un appel de lecture inoffensif.

Securite :
  - le secret n'est jamais renvoye au navigateur, ni journalise ;
  - toute adresse saisie (site WordPress, boutique...) est reduite a un nom d'hote PUBLIC
    verifie (pas d'IP, pas de reseau interne) : le serveur fera des requetes vers cet
    hote, c'est le risque SSRF classique ;
  - les "sous-domaines" (zendesk, shopify, bamboohr) sont rattaches a un domaine fixe du
    fournisseur, jamais une URL libre.
"""
import ipaddress
import json
import os
import re
import socket

_GUIDES = {}
_GUIDES_PATH = None


def load_guides(path):
    global _GUIDES, _GUIDES_PATH
    _GUIDES_PATH = path
    try:
        with open(path, encoding="utf-8-sig") as f:
            data = json.load(f)
        _GUIDES = {k: v for k, v in data.items() if not k.startswith("_") and isinstance(v, dict)}
    except (OSError, ValueError):
        _GUIDES = {}
    return _GUIDES


def guide_for(provider):
    return _GUIDES.get(provider)


def public_guide(provider):
    """Ce que voit le navigateur : jamais la logique de test ni de composition."""
    g = _GUIDES.get(provider)
    if not g:
        return None
    return {
        "label": g.get("label", provider),
        "helpUrl": g.get("helpUrl"),
        "helpLabel": g.get("helpLabel"),
        "steps": g.get("steps", []),
        "fields": [{k: f.get(k) for k in ("key", "label", "kind", "placeholder")} for f in g.get("fields", [])],
        "testNote": "Un message de test sera posté dans le canal choisi." if (g.get("test") or {}).get("special") == "slack_webhook" else None,
    }


# ----------------------------------------------------------------- validation
class FieldError(Exception):
    def __init__(self, key, message):
        super().__init__(message)
        self.key, self.message = key, message


_HOST_RE = re.compile(r"^(?=.{4,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$")
_SUB_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")
_EMAIL_RE = re.compile(r"^[^@\s<>\",;]+@[^@\s<>\",;]+\.[^@\s<>\",;]{2,}$")
_PATH_RE = re.compile(r"^(/[A-Za-z0-9._~-]{1,40}){0,3}$")
_BLOCKED_SUFFIXES = (".local", ".localhost", ".internal", ".lan", ".home", ".corp", ".intranet", ".arpa", ".test", ".invalid", ".example")
_CTRL_RE = re.compile(r"[\x00-\x1f\x7f]")


def default_resolver(host):
    return [ai[4][0] for ai in socket.getaddrinfo(host, 443, proto=socket.IPPROTO_TCP)]


def _is_public_ip(ip):
    try:
        a = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return a.is_global and not (a.is_multicast or a.is_reserved or a.is_loopback or a.is_link_local or a.is_private)


def normalize_host(raw, key, allow_path=False, resolver=default_resolver):
    """'https://www.MonSite.com/blog/?x=1' -> 'www.monsite.com' (ou 'www.monsite.com/blog')."""
    s = _CTRL_RE.sub("", str(raw or "")).strip().lower()
    s = re.sub(r"^[a-z][a-z0-9+.-]*://", "", s)
    s = s.split("?", 1)[0].split("#", 1)[0]
    if "@" in s:
        raise FieldError(key, "Saisissez seulement l'adresse du site (sans identifiant).")
    host, _, rest = s.partition("/")
    # Un client colle souvent l'adresse d'une page d'administration (monsite.com/wp-admin/index.php) :
    # on ne garde que le chemin d'installation eventuel (monsite.com/blog), jamais ce qui suit.
    segs = []
    for seg in [x for x in rest.split("/") if x]:
        if seg in ("wp-admin", "wp-login.php", "wp-json", "wp-content", "index.php", "index.html"):
            break
        segs.append(seg)
    path = ("/" + "/".join(segs)) if segs else ""
    if ":" in host:
        raise FieldError(key, "Saisissez l'adresse sans numéro de port.")
    host = host.rstrip(".")
    if not _HOST_RE.match(host) or host.endswith(_BLOCKED_SUFFIXES):
        raise FieldError(key, "Adresse de site invalide (exemple : monsite.com).")
    if path and not (allow_path and _PATH_RE.match(path)):
        path = ""                                           # on garde l'hote, on ignore le chemin d'une page quelconque
    try:
        ips = resolver(host)
    except OSError:
        raise FieldError(key, "Impossible de trouver ce site. Vérifiez l'adresse.")
    if not ips or not all(_is_public_ip(ip) for ip in ips):
        raise FieldError(key, "Cette adresse n'est pas accessible publiquement.")
    return host + path


def normalize_subdomain(raw, key, suffix):
    s = _CTRL_RE.sub("", str(raw or "")).strip().lower()
    s = re.sub(r"^[a-z][a-z0-9+.-]*://", "", s).split("/", 1)[0].split("?", 1)[0]
    if "." in s:
        label, _, tail = s.partition(".")
        if not suffix or tail != suffix:
            raise FieldError(key, f"Saisissez le nom de votre compte (exemple : monentreprise ou monentreprise.{suffix or 'exemple.com'}).")
        s = label
    if not _SUB_RE.match(s):
        raise FieldError(key, "Nom de compte invalide : lettres, chiffres et tirets uniquement.")
    return s


def normalize_phone(raw, key):
    s = re.sub(r"[\s().-]", "", str(raw or ""))
    if s.startswith("00"):
        s = "+" + s[2:]
    if not re.match(r"^\+[1-9]\d{6,14}$", s):
        raise FieldError(key, "Numéro invalide : format international attendu (exemple : +41791234567).")
    return s


def normalize_value(field, raw, resolver=default_resolver):
    key, kind = field["key"], field.get("kind", "text")
    if kind == "host":
        return normalize_host(raw, key, allow_path=bool(field.get("allowPath", True)), resolver=resolver)
    if kind == "subdomain":
        return normalize_subdomain(raw, key, field.get("suffix", ""))
    if kind == "phone":
        return normalize_phone(raw, key)
    s = str(raw if raw is not None else "")
    if _CTRL_RE.search(s):
        raise FieldError(key, "Caractères non valides dans ce champ.")
    s = s.strip().strip("\"'").strip()
    if not s:
        raise FieldError(key, "Ce champ est obligatoire.")
    if len(s) > 2000:
        raise FieldError(key, "Valeur trop longue.")
    if kind == "email" and not _EMAIL_RE.match(s):
        raise FieldError(key, "Adresse email invalide.")
    if kind in ("secret", "text") and field.get("pattern") and not re.match(field["pattern"], s):
        raise FieldError(key, "Le format de cette valeur ne correspond pas à celui attendu.")
    return s


def build_secret(provider, fields, resolver=default_resolver):
    """-> (secret_str, None) ou (None, {"field": clef, "message": texte})."""
    g = _GUIDES.get(provider)
    if not g:
        return None, {"field": None, "message": "Cet outil n'a pas encore de connexion guidée."}
    if not isinstance(fields, dict):
        return None, {"field": None, "message": "Formulaire invalide."}
    clean = {}
    try:
        for f in g.get("fields", []):
            clean[f["key"]] = normalize_value(f, fields.get(f["key"]), resolver)
    except FieldError as e:
        return None, {"field": e.key, "message": e.message}

    mode = g.get("compose", "json")
    if mode == "raw":
        return clean[g["rawField"]], None
    if mode == "zendesk":
        return json.dumps({"subdomain": clean["subdomain"], "user": clean["email"] + "/token", "pass": clean["token"]}), None
    if mode == "bamboohr":
        return json.dumps({"user": clean["apiKey"], "pass": "x", "companyDomain": clean["companyDomain"]}), None
    out = dict(clean)
    out.update(g.get("constants") or {})
    return json.dumps(out), None


# ------------------------------------------------------------ resultat du test
def classify_test_error(label, detail):
    """-> (kind, message_pour_le_client). kind : auth | notfound | permission | transient | other.
    'auth' et 'notfound' = identifiants/adresse faux : le serveur supprime ce qui vient d'etre
    enregistre (sinon l'outil s'afficherait "Connecte" alors qu'il ne marchera jamais)."""
    d = (detail or "").lower()
    if any(x in d for x in ("401", "unauthorized", "invalid_auth", "bad credentials", "invalid token", "authentication")):
        return "auth", f"{label} a refusé ces identifiants. Vérifiez que vous avez bien copié la clé ou le jeton en entier."
    if any(x in d for x in ("403", "forbidden", "permission", "scope")):
        return "permission", f"{label} reconnaît vos identifiants, mais les autorisations sont insuffisantes. Reprenez l'étape des permissions côté {label}."
    if any(x in d for x in ("404", "not found", "no such host", "name or service", "could not be resolved", "nodename", "name resolution")):
        return "notfound", f"{label} ne répond pas à cette adresse. Vérifiez le nom de votre compte ou de votre site."
    if any(x in d for x in ("timed out", "timeout", "time out", "a task was canceled")):
        return "transient", f"{label} n'a pas répondu à temps. Vos identifiants sont enregistrés ; réessayez la vérification dans un instant."
    if "429" in d or "too many" in d or "rate limit" in d:
        return "transient", f"{label} limite temporairement les requêtes. Vos identifiants sont enregistrés ; réessayez dans une minute."
    return "other", f"La vérification auprès de {label} n'a pas abouti. Vos identifiants sont enregistrés ; vous pouvez réessayer ou les corriger."
