# -*- coding: utf-8 -*-
"""Aperçu privé d'un site de projet (docs/AUTONOMY-ENGINE.md, section 8.5).

L'aperçu sert `workspace/site/dist/` à son client sous un CONTEXTE DE SÉCURITÉ SÉPARÉ de celui du tableau de bord : le HTML est écrit par un
modèle (qui lit des pages web et des fichiers d'inconnus, donc exposé à l'injection) ; il ne doit jamais s'exécuter avec les droits de
l'origine du tableau de bord (cookies de session, routes qui approuvent des envois réels).

- URL à jeton : /preview/<jeton>/<chemin>, jeton = secrets.token_urlsafe(24) (192 bits), enregistré dans runtime/projects/_previews/<jeton>.json
  {projectId, clientId, createdUtc, expiresUtc, revoked}. 72 h par défaut, 14 jours au plus, prolongeable, révocable, un jeton par projet.
- En-têtes sur CHAQUE réponse (y compris 404) : CSP « sandbox » SANS allow-same-origin (origine opaque : ni cookies ni stockage du tableau de
  bord, requêtes vers /api/* non authentifiées), connect-src 'none', form-action 'none', frame-ancestors 'self', nosniff, noindex, no-referrer,
  no-store, COOP same-origin. Aucun cookie lu ni posé, aucun en-tête CORS.
- Chemins stricts : décodage UNE fois, refus de « .. », « \\ », NUL, segments cachés ou vides, double encodage, chemin absolu ; extension dans une
  liste fermée, type MIME fixé par table ; realpath confiné à dist/ sans composant lien symbolique ; pas de liste de dossier ; 404 identique
  pour jeton inconnu, expiré, révoqué ou chemin invalide (rien à énumérer).
- Plafonds : fichier <= 5 Mo, dist/ <= 25 Mo, <= 60 pages, 60 requêtes par minute et par jeton.
- Bandeau « Aperçu privé BK-AI-WORKERS — non publié » inséré après <body> (BK_PREVIEW_BANNER=1, défaut).

Crochet : PREMIÈRES lignes de do_GET dans server.py, avant la porte : `if SITE_PREVIEW is not None and SITE_PREVIEW.handle_get(self, path): return`.
Quand les projets sont désactivés (BK_PROJECTS=0), handle_get renvoie False : aucune réponse existante ne change.
"""
import datetime
import json
import os
import re
import secrets
import threading
import time
from urllib.parse import unquote, urlsplit

import project_paths as pp

TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{32}\Z")
PROJECT_ID_RE = re.compile(r"^PRJ-[0-9A-F]{32}\Z")
CLIENT_ID_RE = re.compile(r"^(CLI-CUST-[A-F0-9]{8}|CLI-DASHBOARD)\Z")          # même règle que projects_store.py
SEG_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}\Z")
PREFIX = "/preview/"
DEFAULT_HOURS = 72
MAX_HOURS = 14 * 24
MAX_FILE_BYTES = 5 * 1024 * 1024
MAX_DIST_BYTES = 25 * 1024 * 1024
MAX_PAGES = 60
RATE_PER_MIN = 60
MIME = {
    "html": "text/html; charset=utf-8", "css": "text/css; charset=utf-8", "js": "text/javascript; charset=utf-8",
    "svg": "image/svg+xml", "png": "image/png", "jpg": "image/jpeg", "webp": "image/webp", "gif": "image/gif",
    "ico": "image/x-icon", "woff2": "font/woff2", "xml": "application/xml; charset=utf-8", "txt": "text/plain; charset=utf-8",
    "json": "application/json; charset=utf-8", "webmanifest": "application/manifest+json; charset=utf-8",
}
CSP = ("sandbox allow-scripts allow-popups allow-popups-to-escape-sandbox; default-src 'none'; img-src 'self' data:; "
       "style-src 'self' 'unsafe-inline'; font-src 'self' data:; script-src 'self'; media-src 'self'; connect-src 'none'; frame-src 'none'; "
       "object-src 'none'; form-action 'none'; base-uri 'none'; frame-ancestors 'self'")
HEADERS = (
    ("Content-Security-Policy", CSP),
    ("X-Content-Type-Options", "nosniff"),
    ("X-Robots-Tag", "noindex, nofollow, noarchive"),
    ("Referrer-Policy", "no-referrer"),
    ("Cache-Control", "private, no-store"),
    ("Cross-Origin-Opener-Policy", "same-origin"),
)
IFRAME_SANDBOX = "allow-scripts allow-popups allow-popups-to-escape-sandbox"
NOT_FOUND_BODY = b"<!doctype html><title>404</title><p>Introuvable.</p>\n"
BANNER = ('<div role="note" style="position:sticky;top:0;z-index:2147483647;margin:0;padding:6px 12px;background:#111827;color:#ffffff;'
          'font:600 13px/1.4 system-ui,-apple-system,Segoe UI,Roboto,sans-serif;text-align:center;letter-spacing:0">'
          'Aperçu privé BK-AI-WORKERS — non publié</div>')


def _iso(ts):
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse_iso(text):
    try:
        return datetime.datetime.strptime(str(text), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()
    except (TypeError, ValueError):
        return None


def _truthy(v):
    return str(v or "").strip().lower() in ("1", "true", "yes", "on")


class SitePreview:
    def __init__(self, root, *, enabled=None, now=time.time, banner=None, base_url=None):
        self.root = root
        self.dir = os.path.join(root, "runtime", "projects", "_previews")
        self._enabled = enabled if callable(enabled) else (lambda: _truthy(os.environ.get("BK_PROJECTS")))
        self.now = now
        self.banner = (os.environ.get("BK_PREVIEW_BANNER", "1") != "0") if banner is None else bool(banner)
        base = base_url if base_url is not None else os.environ.get("BK_PREVIEW_BASE_URL", "")
        self.base_url = base.rstrip("/") if isinstance(base, str) and re.match(r"^https://[A-Za-z0-9.-]+(?::\d+)?\Z", base.rstrip("/")) else ""
        self.lock = threading.RLock()
        self._hits = {}
        self._dist_cache = {}

    # ------------------------------------------------------------------ registre des jetons
    def _path(self, token):
        return os.path.join(self.dir, token + ".json")

    def _load(self, token):
        if not TOKEN_RE.match(token or ""):
            return None
        try:
            with open(self._path(token), encoding="utf-8") as f:
                rec = json.load(f)
        except (OSError, ValueError):
            return None
        return rec if isinstance(rec, dict) else None

    def _save(self, token, rec):
        os.makedirs(self.dir, exist_ok=True)
        pp.atomic_write_bytes(self._path(token), json.dumps(rec, ensure_ascii=False, sort_keys=True).encode("utf-8"))

    def _tokens_of(self, pid):
        out = []
        try:
            names = sorted(os.listdir(self.dir))
        except OSError:
            return out
        for n in names:
            if n.endswith(".json") and TOKEN_RE.match(n[:-5]):
                rec = self._load(n[:-5])
                if rec and rec.get("projectId") == pid:
                    out.append((n[:-5], rec))
        return out

    def project_dir(self, client_id, pid):
        if not CLIENT_ID_RE.match(client_id or "") or not PROJECT_ID_RE.match(pid or ""):
            return None
        return os.path.join(self.root, "runtime", "projects", client_id, pid)

    def dist_dir(self, client_id, pid):
        d = self.project_dir(client_id, pid)
        return os.path.join(d, "workspace", "site", "dist") if d else None

    def url_for(self, token):
        return f"{self.base_url}{PREFIX}{token}/"

    def create(self, client_id, pid, hours=None):
        """Crée (ou remplace) LE jeton du projet. L'ancien jeton est révoqué : un seul lien vivant par projet."""
        hours = DEFAULT_HOURS if not isinstance(hours, (int, float)) or isinstance(hours, bool) else max(1, min(MAX_HOURS, int(hours)))
        if not self.project_dir(client_id, pid):
            raise ValueError("identifiants invalides")
        with self.lock:
            for tok, rec in self._tokens_of(pid):
                if not rec.get("revoked"):
                    rec["revoked"] = True
                    self._save(tok, rec)
            token = secrets.token_urlsafe(24)
            t = self.now()
            rec = {"projectId": pid, "clientId": client_id, "createdUtc": _iso(t), "expiresUtc": _iso(t + hours * 3600), "revoked": False}
            self._save(token, rec)
        return {"token": token, "url": self.url_for(token), "expiresUtc": rec["expiresUtc"], "sandbox": IFRAME_SANDBOX}

    def active(self, client_id, pid):
        """(jeton, enregistrement) du lien vivant du projet, ou (None, None)."""
        t = self.now()
        for tok, rec in self._tokens_of(pid):
            if rec.get("clientId") == client_id and not rec.get("revoked") and (_parse_iso(rec.get("expiresUtc")) or 0) > t:
                return tok, rec
        return None, None

    def info(self, client_id, pid):
        tok, rec = self.active(client_id, pid)
        if not tok:
            return {"active": False}
        return {"active": True, "url": self.url_for(tok), "expiresUtc": rec["expiresUtc"], "sandbox": IFRAME_SANDBOX}

    def revoke(self, client_id, pid):
        n = 0
        with self.lock:
            for tok, rec in self._tokens_of(pid):
                if rec.get("clientId") == client_id and not rec.get("revoked"):
                    rec["revoked"] = True
                    self._save(tok, rec)
                    n += 1
        return n

    def refresh(self, pid, hours=DEFAULT_HOURS):
        """Après une construction : prolonge le lien vivant du projet (jamais au-delà de 14 jours après sa création). Aucun jeton n'est créé."""
        t = self.now()
        with self.lock:
            for tok, rec in self._tokens_of(pid):
                if rec.get("revoked"):
                    continue
                exp = _parse_iso(rec.get("expiresUtc")) or 0
                if exp <= t:
                    continue
                created = _parse_iso(rec.get("createdUtc")) or t
                new_exp = min(created + MAX_HOURS * 3600, max(exp, t + hours * 3600))
                if new_exp > exp:
                    rec["expiresUtc"] = _iso(new_exp)
                    self._save(tok, rec)
                return rec["expiresUtc"]
        return None

    def purge_client(self, client_id):
        """Suppression d'un compte : tous ses jetons disparaissent."""
        n = 0
        try:
            names = os.listdir(self.dir)
        except OSError:
            return 0
        for name in names:
            if name.endswith(".json") and TOKEN_RE.match(name[:-5]):
                rec = self._load(name[:-5])
                if rec and rec.get("clientId") == client_id:
                    try:
                        os.remove(self._path(name[:-5]))
                        n += 1
                    except OSError:
                        pass
        return n

    def purge_project(self, pid):
        """Suppression d'un projet : tous ses jetons d'apercu disparaissent."""
        n = 0
        with self.lock:
            for tok, _rec in self._tokens_of(pid):
                try:
                    os.remove(self._path(tok))
                    n += 1
                except OSError:
                    pass
        return n

    def sweep(self, grace_days=1):
        """Entretien : supprime les jetons revoques ou expires depuis plus de `grace_days` jours (le dossier ne grossit plus sans limite)."""
        limit = self.now() - grace_days * 86400
        n = 0
        try:
            names = os.listdir(self.dir)
        except OSError:
            return 0
        with self.lock:
            for name in names:
                if not (name.endswith(".json") and TOKEN_RE.match(name[:-5])):
                    continue
                rec = self._load(name[:-5])
                if rec is None:
                    continue
                exp = _parse_iso(rec.get("expiresUtc")) or 0
                if exp < limit:
                    try:
                        os.remove(self._path(name[:-5]))
                        n += 1
                    except OSError:
                        pass
        return n

    # ------------------------------------------------------------------ service HTTP
    def handle_get(self, handler, path):
        """True si la requête est un aperçu (réponse envoyée), False sinon (la route continue normalement)."""
        if not isinstance(path, str) or not path.startswith(PREFIX[:-1]):
            return False
        if path != PREFIX[:-1] and not path.startswith(PREFIX):
            return False
        if not self._enabled():
            return False
        try:
            self._serve(handler)
        except (BrokenPipeError, ConnectionError):
            pass
        except Exception:  # noqa: BLE001 - jamais de trace brute, et toujours la même réponse
            try:
                self._send(handler, 404, NOT_FOUND_BODY, "text/html; charset=utf-8")
            except Exception:  # noqa: BLE001
                pass
        return True

    def _send(self, handler, status, body, ctype, extra=None):
        handler.send_response(status)
        for k, v in HEADERS:
            handler.send_header(k, v)
        handler.send_header("Content-Type", ctype)
        handler.send_header("Content-Length", str(len(body)))
        for k, v in (extra or ()):
            handler.send_header(k, v)
        handler.end_headers()
        handler.wfile.write(body)

    def _not_found(self, handler):
        self._send(handler, 404, NOT_FOUND_BODY, "text/html; charset=utf-8")

    def _rate_ok(self, token):
        t = self.now()
        with self.lock:
            rows = [x for x in self._hits.get(token, []) if t - x < 60]
            if len(rows) >= RATE_PER_MIN:
                self._hits[token] = rows
                return False
            rows.append(t)
            self._hits[token] = rows
            if len(self._hits) > 2000:
                for k in [k for k, v in self._hits.items() if not v or t - v[-1] > 120]:
                    self._hits.pop(k, None)
        return True

    def resolve_request(self, raw_path):
        """(jeton, liste de segments) d'un chemin BRUT (encodé) /preview/<jeton>/<chemin>, ou None. Pur : testable sans serveur."""
        raw = urlsplit(raw_path or "").path
        if not raw.startswith(PREFIX[:-1]):
            return None
        if raw == PREFIX[:-1]:
            return None
        rest = raw[len(PREFIX):]
        token, sep, sub = rest.partition("/")
        if not TOKEN_RE.match(token):
            return None
        if not sep:
            return (token, None)                       # « /preview/<jeton> » : redirection vers « /preview/<jeton>/ »
        if len(sub) > 400:
            return None
        once = unquote(sub, errors="strict") if "%" in sub else sub
        if "%" in once and re.search(r"%[0-9A-Fa-f]{2}", once):
            return None                                 # double encodage (%252e…) : refusé
        if "\x00" in once or "\\" in once or once.startswith("/") or "//" in once:
            return None
        if re.match(r"^[A-Za-z]:", once):
            return None
        if once == "" or once.endswith("/"):
            once += "index.html"
        segs = once.split("/")
        if len(segs) > 8:
            return None
        for s in segs:
            if s in (".", "..") or not SEG_RE.match(s):
                return None
        ext = segs[-1].rsplit(".", 1)[-1].lower() if "." in segs[-1] else ""
        if ext not in MIME:
            return None
        return (token, segs)

    def _dist_ok(self, dist):
        """dist/ dans les plafonds (<= 25 Mo, <= 60 pages) ; résultat gardé tant que build.json ne change pas."""
        bj = os.path.join(os.path.dirname(dist), "build.json")
        try:
            key = os.path.getmtime(bj)
        except OSError:
            key = None
        hit = self._dist_cache.get(dist)
        if hit and hit[0] == key and key is not None:
            return hit[1]
        total, pages = 0, 0
        for dirpath, dirnames, filenames in os.walk(dist, followlinks=False):
            dirnames[:] = [d for d in dirnames if not pp._is_link_or_reparse(os.path.join(dirpath, d))]
            for fn in filenames:
                fp = os.path.join(dirpath, fn)
                try:
                    total += os.path.getsize(fp)
                except OSError:
                    continue
                if fn.endswith((".html", ".htm")):
                    pages += 1
        ok = total <= MAX_DIST_BYTES and pages <= MAX_PAGES + 1          # + 404.html
        with self.lock:
            if len(self._dist_cache) > 500:
                self._dist_cache.clear()
            self._dist_cache[dist] = (key, ok)
        return ok

    def _serve(self, handler):
        req = self.resolve_request(handler.path)
        if req is None:
            return self._not_found(handler)
        token, segs = req
        rec = self._load(token)
        if not rec or rec.get("revoked") or (_parse_iso(rec.get("expiresUtc")) or 0) <= self.now():
            return self._not_found(handler)
        if not self._rate_ok(token):
            self._send(handler, 429, b"Trop de demandes.\n", "text/plain; charset=utf-8", (("Retry-After", "60"),))
            return None
        if segs is None:
            self._send(handler, 302, b"", "text/plain; charset=utf-8", (("Location", f"{PREFIX}{token}/"),))
            return None
        dist = self.dist_dir(str(rec.get("clientId") or ""), str(rec.get("projectId") or ""))
        if not dist or not os.path.isdir(dist) or pp._is_link_or_reparse(dist):
            return self._not_found(handler)
        real_dist = os.path.realpath(dist)
        cur = real_dist
        for s in segs:                                 # aucun composant n'est un lien symbolique ni une jonction
            cur = os.path.join(cur, s)
            if pp._is_link_or_reparse(cur):
                return self._not_found(handler)
        full = os.path.realpath(cur)
        if not full.startswith(real_dist + os.sep) or not os.path.isfile(full):
            return self._not_found(handler)
        size = os.path.getsize(full)
        if size > MAX_FILE_BYTES or not self._dist_ok(real_dist):
            return self._not_found(handler)
        with open(full, "rb") as f:
            body = f.read(MAX_FILE_BYTES + 1)
        ext = segs[-1].rsplit(".", 1)[-1].lower()
        if ext == "html" and self.banner:
            body = re.sub(rb"(<body\b[^>]*>)", lambda m: m.group(1) + BANNER.encode("utf-8"), body, count=1, flags=re.IGNORECASE)
        self._send(handler, 200, body, MIME[ext])
        return None
