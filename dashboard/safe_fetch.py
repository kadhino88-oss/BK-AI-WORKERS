# -*- coding: utf-8 -*-
"""Lecture d'une page web pour les moteurs IA sans recherche integree (Ollama, hote suisse, cle du client) : outil web_fetch cote serveur.

Pourquoi un fichier a part : Claude lit le web de son cote (outil serveur d'Anthropic) ; un modele local n'a rien de tel. Ce module le
remplace, et il est ecrit pour qu'un texte hostile (page piegee, redirection, DNS manipule) ne puisse JAMAIS atteindre le reseau interne :
  - https seulement (file://, gopher://, ftp://, http:// refuses), port 443 ou 8443, aucun identifiant dans l'URL ;
  - le nom est resolu UNE fois, TOUTES les adresses doivent etre publiques (net_policy.ip_class), puis on se connecte a l'adresse VALIDEE
    (pas au nom : un DNS qui change entre la verification et la connexion ne sert a rien) avec SNI et certificat verifies sur le nom ;
  - chaque redirection est suivie a la main (3 au plus) et revalidee de zero, adresse comprise ;
  - delai total, taille maximale de la reponse (la lecture s'arrete), pas de compression acceptee (pas de bombe de decompression) ;
  - seuls les contenus texte (HTML, texte, JSON, XML) sont lus ; le HTML est reduit a du texte (scripts, styles, cadres, objets supprimes) ;
  - le resultat est une DONNEE : l'appelant (adaptateur PowerShell) l'encadre et le presente au modele comme du contenu externe, jamais
    comme une instruction.
Utilisation en ligne de commande (adaptateur PowerShell) : python safe_fetch.py <entree.json> <sortie.json> ;
entree {"url", "maxBytes"?, "timeoutSec"?, "maxChars"?} ; sortie = le dictionnaire renvoye par fetch().
"""
import html.parser
import http.client
import json
import os
import re
import socket
import ssl
import sys
import time
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import net_policy  # noqa: E402

MAX_BYTES = 600_000
MAX_CHARS = 20_000
TIMEOUT_SEC = 20
MAX_REDIRECTS = 3
ALLOWED_PORTS = (443, 8443)
TEXT_TYPES = ("text/", "application/json", "application/xml", "application/xhtml+xml", "application/rss+xml", "application/atom+xml")
USER_AGENT = "BK-AI-WORKERS-reader/1.0 (+https://bk-ai-workers.com)"
_DROP_TAGS = {"script", "style", "noscript", "iframe", "object", "embed", "template", "svg", "canvas"}
_BLOCK_TAGS = {"p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "section", "article", "ul", "ol", "table", "blockquote", "pre"}


def _error(code, message, **extra):
    out = {"ok": False, "error": code, "message": message}
    out.update(extra)
    return out


class _TextExtractor(html.parser.HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts, self.title, self._skip, self._in_title = [], "", 0, False

    def handle_starttag(self, tag, attrs):
        if tag in _DROP_TAGS:
            self._skip += 1
        elif tag == "title":
            self._in_title = True
        elif tag in _BLOCK_TAGS:
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in _DROP_TAGS:
            self._skip = max(0, self._skip - 1)
        elif tag == "title":
            self._in_title = False
        elif tag in _BLOCK_TAGS:
            self.parts.append("\n")

    def handle_data(self, data):
        if self._in_title:
            self.title += data
        elif not self._skip:
            self.parts.append(data)


def html_to_text(raw):
    p = _TextExtractor()
    try:
        p.feed(raw)
        p.close()
    except Exception:  # noqa: BLE001 - un HTML casse ne doit rien faire planter : on garde ce qui a ete lu
        pass
    text = "".join(p.parts)
    text = re.sub(r"[ \t\r\f\v]+", " ", text)
    text = re.sub(r" *\n *", "\n", text)
    text = re.sub(r"\n{3,}", "\n\n", text).strip()
    return re.sub(r"\s+", " ", p.title).strip()[:300], text


def _default_connect(ip, port, timeout):
    return socket.create_connection((ip, port), timeout=timeout)


def _default_tls(sock, host):
    ctx = ssl.create_default_context()
    return ctx.wrap_socket(sock, server_hostname=host)


def _read_body(resp, sock, max_bytes, deadline):
    chunks, size, truncated = [], 0, False
    while True:
        if time.monotonic() > deadline:
            return b"".join(chunks), True, True
        try:
            sock.settimeout(max(0.2, deadline - time.monotonic()))     # chaque lecture est bornee par le temps restant
        except OSError:
            pass
        chunk = resp.read1(min(16384, max_bytes + 1 - size))
        if not chunk:
            break
        chunks.append(chunk)
        size += len(chunk)
        if size > max_bytes:
            truncated = True
            break
    data = b"".join(chunks)
    return data[:max_bytes], truncated, False


def fetch(url, max_bytes=MAX_BYTES, timeout=TIMEOUT_SEC, max_chars=MAX_CHARS, max_redirects=MAX_REDIRECTS,
          resolver=None, connect=None, tls_wrap=None):
    """Lit une page publique. Renvoie {"ok": True, "url", "status", "contentType", "title", "text", "truncated", "redirects", "bytes"} ou
    {"ok": False, "error": CODE, "message": ...}. `resolver`, `connect` et `tls_wrap` sont des points d'injection pour les tests : la
    validation des adresses a lieu AVANT eux, comme en production."""
    connect = connect or _default_connect
    tls_wrap = tls_wrap or _default_tls
    deadline = time.monotonic() + max(1, min(float(timeout), 60))
    current = str(url or "").strip()
    redirects = 0
    while True:
        parts = net_policy.split_url(current)
        if not parts:
            return _error("BAD_URL", "Adresse illisible.")
        if parts["scheme"] != "https":
            return _error("HTTPS_ONLY", "Seules les adresses https:// sont lues (pas de file://, gopher://, ftp:// ni http://).")
        if parts["userinfo"]:
            return _error("CREDENTIALS_IN_URL", "L'adresse ne doit contenir ni identifiant ni mot de passe.")
        if not parts["host"]:
            return _error("BAD_URL", "Adresse sans nom de serveur.")
        host, port = parts["host"], parts["port"] or 443
        if port not in ALLOWED_PORTS:
            return _error("PORT_NOT_ALLOWED", "Port non autorise.")
        try:
            addrs = net_policy.resolve_all(host, port, resolver)
        except OSError:
            return _error("DNS_FAILED", "Le nom de ce serveur ne se resout pas.")
        if not addrs or any(net_policy.ip_class(a) != "public" for a in addrs):
            return _error("BLOCKED_ADDRESS", "Cette adresse n'est pas une adresse publique : lecture refusee.")
        ip = addrs[0]
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return _error("TIMEOUT", "Delai depasse.")
        sock = None
        try:
            sock = connect(ip, port, min(remaining, 10))
            sock = tls_wrap(sock, host)
            sock.settimeout(max(1.0, deadline - time.monotonic()))
            conn = http.client.HTTPConnection(host, port)
            conn.sock = sock           # connexion deja etablie vers l'adresse validee : http.client n'ouvre rien de lui-meme
            hostport = host if port == 443 else f"{host}:{port}"
            conn.request("GET", parts["path"], headers={"Host": hostport, "User-Agent": USER_AGENT, "Accept": "text/html,text/plain,application/json;q=0.9,*/*;q=0.1",
                                                        "Accept-Encoding": "identity", "Connection": "close"})
            resp = conn.getresponse()
            status = resp.status
            if status in (301, 302, 303, 307, 308):
                location = resp.getheader("Location")
                if not location:
                    return _error("BAD_REDIRECT", "Redirection sans destination.")
                if redirects >= max_redirects:
                    return _error("TOO_MANY_REDIRECTS", "Trop de redirections.")
                redirects += 1
                current = urllib.parse.urljoin(current, location.strip())
                continue
            if status < 200 or status >= 300:
                return _error("HTTP_STATUS", f"Le serveur a repondu {status}.", status=status)
            encoding = (resp.getheader("Content-Encoding") or "identity").lower()
            if encoding not in ("identity", ""):
                return _error("ENCODED_CONTENT", "Contenu compresse non accepte.")
            ctype_full = resp.getheader("Content-Type") or "text/plain"
            ctype = ctype_full.split(";")[0].strip().lower()
            if not any(ctype.startswith(t) for t in TEXT_TYPES):
                return _error("UNSUPPORTED_CONTENT", f"Type de contenu non pris en charge ({ctype[:60]}) : seules les pages texte sont lues.")
            body, truncated, timed_out = _read_body(resp, sock, max_bytes, deadline)
            charset = "utf-8"
            m = re.search(r"charset=([A-Za-z0-9_\-]+)", ctype_full, re.I)
            if m:
                charset = m.group(1)
            try:
                raw = body.decode(charset, errors="replace")
            except LookupError:
                raw = body.decode("utf-8", errors="replace")
            if "html" in ctype or "xml" in ctype:
                title, text = html_to_text(raw)
            else:
                title, text = "", re.sub(r"\n{3,}", "\n\n", raw).strip()
            if len(text) > max_chars:
                text, truncated = text[:max_chars], True
            return {"ok": True, "url": current, "status": status, "contentType": ctype, "title": title, "text": text,
                    "truncated": bool(truncated), "timedOut": bool(timed_out), "redirects": redirects, "bytes": len(body)}
        except (OSError, ssl.SSLError, http.client.HTTPException) as e:
            return _error("FETCH_FAILED", "Lecture impossible : " + type(e).__name__)
        finally:
            try:
                if sock is not None:
                    sock.close()
            except OSError:
                pass


def main(argv):
    if len(argv) != 3:
        return 2
    try:
        with open(argv[1], encoding="utf-8-sig") as f:
            req = json.load(f)
        result = fetch(req.get("url"), max_bytes=min(int(req.get("maxBytes") or MAX_BYTES), MAX_BYTES),
                       timeout=min(int(req.get("timeoutSec") or TIMEOUT_SEC), 60), max_chars=min(int(req.get("maxChars") or MAX_CHARS), MAX_CHARS))
    except Exception as e:  # noqa: BLE001
        result = _error("FETCH_FAILED", "Lecture impossible : " + type(e).__name__)
    with open(argv[2], "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
