# -*- coding: utf-8 -*-
"""Politique reseau des moteurs IA (2026-10-25) : qui a le droit d'etre appele par le serveur.

Deux usages, UNE seule definition des adresses :
  - safe_fetch.py (outil web_fetch du moteur local) : seules les adresses PUBLIQUES, jamais le reseau interne ;
  - provider_router.py / adaptateur OpenAI-compatible : l'adresse du moteur choisi par le proprietaire (Ollama sur son PC, hote suisse) ou,
    pour la cle d'un client (BYOK), un hote public d'une liste blanche.

Classes d'adresse (ip_class, sur l'adresse RESOLUE, jamais sur le texte de l'URL : « http://2130706433/ » ou « http://0x7f.1/ » sont des
ecritures de 127.0.0.1 que le systeme resout) :
  loopback  127.0.0.0/8, ::1
  private   10/8, 172.16/12, 192.168/16, fc00::/7 (dont le reseau prive Tailscale en IPv6)
  cgnat     100.64.0.0/10 (reseau prive Tailscale en IPv4)
  public    adresse globale routable
  blocked   tout le reste : lien local (169.254.0.0/16 = metadonnees des clouds, fe80::/10), non specifiee, multicast, reservee,
            documentation, 6to4 / NAT64 / Teredo.
Les memes vecteurs de test (tests/providers/endpoint-cases.json) valident cette fonction ET son pendant PowerShell (Engine-Common.ps1).
"""
import ipaddress
import socket
import urllib.parse

_CGNAT = ipaddress.ip_network("100.64.0.0/10")
_PRIVATE_V4 = [ipaddress.ip_network(n) for n in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")]
_ULA = ipaddress.ip_network("fc00::/7")
_BLOCKED_V6 = [ipaddress.ip_network(n) for n in ("64:ff9b::/96", "64:ff9b:1::/48", "2002::/16", "2001::/32", "100::/64")]

PRIVATE_OK = ("loopback", "private", "cgnat")      # classes d'un reseau que le proprietaire controle (http simple tolere)


def ip_class(addr):
    """'loopback' | 'private' | 'cgnat' | 'public' | 'blocked' pour une adresse IP (texte). Texte invalide = 'blocked'."""
    try:
        text = str(addr).strip().strip("[]").split("%", 1)[0]
        ip = ipaddress.ip_address(text)
    except ValueError:
        return "blocked"
    if isinstance(ip, ipaddress.IPv6Address):
        if ip.ipv4_mapped is not None:
            ip = ip.ipv4_mapped
        elif any(ip in net for net in _BLOCKED_V6):
            return "blocked"
    if ip.is_loopback:
        return "loopback"
    if ip.is_unspecified or ip.is_multicast or ip.is_link_local:
        return "blocked"
    if isinstance(ip, ipaddress.IPv4Address):
        if ip in _CGNAT:
            return "cgnat"
        if any(ip in net for net in _PRIVATE_V4):
            return "private"
    else:
        if ip in _ULA:
            return "private"
    if ip.is_reserved or ip.is_private or not ip.is_global:
        return "blocked"
    return "public"


def resolve_all(host, port=443, resolver=None):
    """Toutes les adresses auxquelles `host` se resout (liste de textes, sans doublon, ordre conserve). Leve OSError si la resolution echoue.
    `resolver(host, port)` -> liste d'adresses, injectable pour les tests ; par defaut le resolveur du systeme."""
    if resolver is not None:
        found = list(resolver(host, port))
    else:
        found = [info[4][0] for info in socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)]
    out = []
    for a in found:
        a = str(a).split("%", 1)[0]
        if a not in out:
            out.append(a)
    return out


def split_url(url):
    """{scheme, host, port, userinfo, path} d'une URL, ou None si elle est illisible / sans schema. host vaut '' quand il n'y en a pas (file:///...)."""
    try:
        p = urllib.parse.urlsplit(str(url).strip())
        host = p.hostname
        port = p.port
    except ValueError:
        return None
    if not p.scheme:
        return None
    return {"scheme": p.scheme.lower(), "host": (host or "").lower(), "port": port, "userinfo": bool(p.username or p.password),
            "path": (p.path or "/") + (("?" + p.query) if p.query else "")}


def check_endpoint(url, kind="owner", has_token=False, resolver=None, allowed_hosts=None):
    """Verifie l'adresse d'un moteur IA. Renvoie (ok, code, message_francais, info).

    kind = 'owner' : adresse posee par le PROPRIETAIRE (Ollama sur son PC, hote suisse, serveur vLLM) :
        - http simple : seulement vers une adresse de loopback, privee ou CGNAT (Tailscale 100.64.0.0/10) ; jamais vers Internet ;
        - https : tout hote public ou prive, mais un jeton (Bearer) est OBLIGATOIRE ;
        - jamais d'identifiants dans l'URL, jamais d'adresse de lien local (metadonnees des clouds), non specifiee, multicast ou reservee.
    kind = 'byok' : adresse saisie par un CLIENT pour SA cle : https obligatoire, adresse publique seulement, hote dans `allowed_hosts`
        (liste blanche du proprietaire : un client ne doit jamais pouvoir faire appeler au serveur une adresse de son choix).
    """
    parts = split_url(url)
    if not parts:
        return False, "BAD_URL", "Adresse illisible.", {}
    if parts["scheme"] not in ("http", "https"):
        return False, "BAD_SCHEME", "Seules les adresses http et https sont acceptées.", {}
    if parts["userinfo"]:
        return False, "CREDENTIALS_IN_URL", "L'adresse ne doit contenir ni identifiant ni mot de passe.", {}
    if not parts["host"]:
        return False, "BAD_URL", "Adresse sans nom de serveur.", {}
    host, scheme = parts["host"], parts["scheme"]
    port = parts["port"] or (443 if scheme == "https" else 80)
    info = {"scheme": scheme, "host": host, "port": port}
    if kind == "byok":
        if scheme != "https":
            return False, "HTTPS_REQUIRED", "L'adresse de votre fournisseur doit commencer par https://.", info
        hosts = {str(h).lower() for h in (allowed_hosts or [])}
        if host not in hosts:
            return False, "HOST_NOT_ALLOWED", "Ce fournisseur n'est pas dans la liste des hôtes acceptés.", info
    try:
        addrs = resolve_all(host, port, resolver)
    except OSError:
        return False, "DNS_FAILED", "Le nom de ce serveur ne se résout pas.", info
    if not addrs:
        return False, "DNS_FAILED", "Le nom de ce serveur ne se résout pas.", info
    classes = [ip_class(a) for a in addrs]
    info["classes"] = classes
    if "blocked" in classes:
        return False, "BLOCKED_ADDRESS", "Cette adresse pointe vers une zone interdite (lien local, réservée ou métadonnées).", info
    if kind == "byok":
        if any(c != "public" for c in classes):
            return False, "NOT_PUBLIC", "L'adresse de votre fournisseur doit être publique.", info
        if not has_token:
            return False, "TOKEN_REQUIRED", "Une clé est obligatoire.", info
        return True, "OK", "", info
    if scheme == "http":
        if any(c not in PRIVATE_OK for c in classes):
            return False, "PLAIN_HTTP_PUBLIC", ("Une adresse http:// simple n'est acceptée que vers votre propre machine ou votre réseau privé "
                                                 "(127.x, 10.x, 172.16-31.x, 192.168.x, 100.64-127.x pour Tailscale). Vers Internet, utilisez https:// avec un jeton."), info
        return True, "OK", "", info
    if not has_token:
        return False, "TOKEN_REQUIRED", "Une adresse https:// exige un jeton (Bearer).", info
    return True, "OK", "", info
